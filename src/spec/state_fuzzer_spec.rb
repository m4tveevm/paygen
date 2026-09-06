# frozen_string_literal: true

require 'spec_helper'
require 'paygen/runtime/state_fuzzer'
require 'paygen/runtime/reference_provider'

RSpec.describe Paygen::Runtime::StateFuzzer do
  before(:context) do
    Dir.mktmpdir do |directory|
      project = Paygen::Project.init(File.expand_path('../../fixtures/novapay/openapi.yaml', __dir__),
                                    output: File.join(directory, 'project'))
      files = Paygen::Generator.new(project).render
      config = JSON.parse(files.fetch('config.json'))
      @service = Paygen::Runtime::ReferenceProvider.load_service(source: files.fetch('novapay_service.rb'),
                                                               class_name: config.fetch('class_name'))
    end
  end

  let(:adapter) { @service.new }
  let(:fuzzer) { described_class.new(adapter: adapter, seed: 42) }

  def trace(mode, actions)
    { 'version' => 1, 'seed' => 42, 'case' => 0, 'mode' => mode,
      'profile_sha256' => Digest::SHA256.hexdigest(JSON.generate(Paygen.canonical(adapter.paygen_config))),
      'steps' => actions.map { |action| { 'action' => action } } }
  end

  it 'runs deterministic generated-adapter sequences with separate invariant and fault coverage' do
    first = fuzzer.run(cases: 12, steps: 15)
    expect(first['success']).to be(true), JSON.pretty_generate(first)
    expect(first).to eq(fuzzer.run(cases: 12, steps: 15))
    expect(first['cases']).to eq(12)
    expect(first.dig('coverage', 'actions').keys).to include(*described_class::ACTIONS)
    expect(first.dig('coverage', 'faults').keys).to include('numeric_provider_id', 'stale_polling', 'invalid_success_body')
    expect(first.dig('coverage', 'invariants').keys).to include('at_most_one_commit', 'provider_identity_preserved',
      'terminal_never_pending', 'callback_outcome_applied_once', 'invalid_response_rejected')
  end

  it 'detects, shrinks and replays a real repeated-post defect after provider commit' do
    configuration = Marshal.load(Marshal.dump(adapter.paygen_config))
    configuration['idempotency'] = {}
    adapter.define_singleton_method(:paygen_config) { configuration }
    adapter.define_singleton_method(:reserve_create_request) { |_request, _operation, _role| nil }
    # The empty policy is intentionally not evidence that an arbitrary provider
    # understands Idempotency-Key. Its transport commits both actual calls.
    report = fuzzer.run(cases: 6, steps: 20)
    expect(report['success']).to be(false)
    expect(report.dig('failure', 'invariant')).to eq('duplicate_payout')
    expect(report['shrunk_trace']['steps'].length).to be < report['trace']['steps'].length
    replay = fuzzer.replay(JSON.parse(JSON.generate(report)))
    expect(replay['success']).to be(false)
    expect(replay.dig('failure', 'invariant')).to eq('duplicate_payout')
    expect(replay.dig('failure', 'committed_ids').length).to eq(2)
    lost = fuzzer.replay(trace('lost_response', %w[create retry]))
    expect(lost.dig('failure', 'invariant')).to eq('duplicate_payout')
  end

  it 'independently expires provider keys and catches an adapter forgetting the retained expiry evidence' do
    configuration = Marshal.load(Marshal.dump(adapter.paygen_config))
    configuration['idempotency'] = { 'strategy' => 'provider_key', 'header' => 'Idempotency-Key', 'ttl_seconds' => 30 }
    adapter.define_singleton_method(:paygen_config) { configuration }
    original = trace('expired_key', %w[create advance retry])
    expect(fuzzer.replay(original)['success']).to be(true)
    expect(fuzzer.replay(trace('lost_response', %w[create retry]))['success']).to be(true)
    adapter.define_singleton_method(:reserve_create_request) do |request, operation, role|
      @paygen_store.synchronize do |state|
        state.each_value do |entry|
          next unless entry.is_a?(Hash) && entry['first_attempt_at']

          # Deliberately broken persistence refreshes the entire retention
          # window. The real adapter must retain both age and expiry evidence.
          entry['first_attempt_at'] = @paygen_clock.call.to_f
          entry['expires_at'] = @paygen_clock.call.to_f + paygen_config.dig('idempotency', 'ttl_seconds')
          entry['expired'] = false
        end
      end
      super(request, operation, role)
    end
    report = fuzzer.replay(original)
    expect(report.dig('failure', 'invariant')).to eq('duplicate_payout')
    expect(report.dig('failure', 'committed_ids').length).to eq(2)
    expect(report.dig('coverage', 'faults', 'provider_key_expired')).to eq(1)
    generated = fuzzer.run(cases: 3, steps: 20)
    expect(generated.dig('failure', 'invariant')).to eq('duplicate_payout')
    expect(generated.dig('shrunk_trace', 'steps').length).to be < generated.dig('trace', 'steps').length
    replayed = fuzzer.replay(JSON.parse(JSON.generate(generated)))
    expect(replayed.dig('failure', 'invariant')).to eq('duplicate_payout')
    expect(replayed.dig('failure', 'committed_ids').length).to eq(2)
  end

  it 'detects source-schema validation being skipped for otherwise plausible successful responses' do
    # Isolate this deliberately disabled schema guard. Explicit correlation is
    # an independent second defense and has its own negative controls; leaving
    # it enabled would correctly reject this same missing-amount mutation.
    configuration = Marshal.load(Marshal.dump(adapter.paygen_config))
    configuration.delete('response_bindings')
    adapter.define_singleton_method(:paygen_config) { configuration }
    adapter.define_singleton_method(:response_contract_failure) { |_response, _role, _status, _payload| nil }
    report = fuzzer.replay(trace('invalid_response', %w[create]))
    expect(report.dig('failure', 'invariant')).to eq('invalid_response_accepted')
    expect(report.dig('failure', 'result', 'success')).to be(true)
  end

  it 'catches numeric IDs altered by result-wide redaction' do
    adapter.define_singleton_method(:create_request) do |operation, role = 'create'|
      Paygen::Runtime::Security.redact(super(operation, role))
    end
    report = fuzzer.replay(trace('numeric_id', %w[create cancel]))
    expect(report['success']).to be(false)
    expect(report.dig('failure', 'invariant')).to eq('provider_identity_changed')
    expect(report.dig('failure', 'committed_ids')).to eq(['sim_06ed5551082250661cad'])
  end

  it 'catches polling bypassing the shared lifecycle reducer after a completed callback' do
    adapter.define_singleton_method(:reduce_lifecycle) { |result| result }
    report = fuzzer.replay(trace('callback_order', %w[create callback poll]))
    expect(report['success']).to be(false)
    expect(report.dig('failure', 'invariant')).to eq('terminal_rollback')
    expect(report.dig('failure', 'action')).to eq('poll')
  end

  it 'catches logical duplicate callbacks causing a second terminal backend-hook application' do
    adapter.define_singleton_method(:process_callback) do |payload, **verification|
      @paygen_store = Paygen::Runtime::MemoryStateStore.new
      super(payload, **verification)
    end
    report = fuzzer.replay(trace('callback_order', %w[create callback duplicate]))
    expect(report['success']).to be(false)
    expect(report.dig('failure', 'invariant')).to eq('duplicate_callback_application')
  end

  it 'rejects corrupted, unbounded and different-profile traces before calling adapter methods' do
    original = trace('normal', %w[create retry])
    expect(adapter).not_to receive(:configure_paygen)
    expect(adapter).not_to receive(:create_request)
    [original.merge('profile_sha256' => 'another-project'), original.merge('mode' => 'remote'),
     original.merge('version' => 99), original.merge('seed' => -1), original.merge('steps' => []),
     original.merge('steps' => [{ 'action' => 'create', 'url' => 'https://example.com' }]),
     original.merge('steps' => Array.new(101) { { 'action' => 'create' } })].each do |invalid|
      expect { fuzzer.replay(invalid) }.to raise_error(ArgumentError)
    end
  end

  it 'bounds the workload and refuses fractional inputs' do
    [{ cases: 0 }, { cases: 1_001 }, { steps: 101 }, { cases: 200, steps: 100 }, { cases: 1.5 }].each do |settings|
      expect { fuzzer.run(**settings) }.to raise_error(ArgumentError)
    end
    expect { described_class.new(adapter: adapter, seed: -1) }.to raise_error(ArgumentError)
  end

  it 'preserves original adapter configuration and never uses its supplied external transport' do
    transport = double('external transport')
    expect(transport).not_to receive(:request)
    adapter.configure_paygen(transport: transport, credentials: { api_key: 'real-key-not-for-fuzzing' })
    result = fuzzer.replay(trace('normal', %w[create retry]))
    expect(result['success']).to be(true), JSON.pretty_generate(result)
    expect(adapter.instance_variable_get(:@paygen_transport)).to equal(transport)
    expect(JSON.generate(result)).not_to include('real-key-not-for-fuzzing')
  end
end
