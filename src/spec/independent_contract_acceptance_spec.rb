# frozen_string_literal: true
require 'spec_helper'
require_relative '../examples/host_bridge'

RSpec.describe 'Independent contract acceptance counterexamples' do
  around do |example|
    Dir.mktmpdir do |root|
      @project = Paygen::Project.init(File.expand_path('../../fixtures/novapay/openapi.yaml', __dir__), output: File.join(root, 'project'))
      example.run
    end
  end

  it 'prevents a callback role from hiding unsupported authentication of the same outgoing operation' do
    document = @project.ir.document
    profile = @project.profile
    document['components']['securitySchemes']['OnlyBasic'] = { 'type' => 'http', 'scheme' => 'basic' }
    document['paths']['/payouts']['post']['security'] = [{ 'OnlyBasic' => [] }]
    profile['operations']['callback'] = profile['operations']['create']
    ir = Paygen::Core::IR.new(document, profile: profile)
    expect(ir.diagnostics).to include(hash_including('code' => 'OPERATION_DIRECTION_CONFLICT', 'severity' => 'blocker', 'path' => 'operations.callback'))
    expect(Paygen::Core::Onboarding.new(ir).report['ready']).to be(false)
    # Ordinary path callbacks remain supported when they have only an inbound role.
    profile['operations']['callback'] = 'payoutWebhook'
    document['paths']['/payouts']['post'].delete('security')
    expect(Paygen::Core::IR.new(document, profile: profile).diagnostics).to be_empty
  end

  def service(base_service: PaygenHostExample::BaseService)
    return @service if @service
    profile = @project.profile
    profile['action_mapping'] = { 'sbp' => 'create', 'check' => 'status' }
    @project.write('integration.yml', YAML.dump(profile))
    source = Paygen::Generator.new(@project).render.fetch('novapay_service.rb')
    klass = Paygen::Runtime::ReferenceProvider.load_service(source: source, class_name: 'NovaPayService', base_service: base_service)
    klass.prepend(PaygenHostExample::CallbackBridge)
    @backend = PaygenHostExample::Backend.new
    @transport = PaygenHostExample::ContractTransport.new
    @service = klass.new(backend: @backend, transport: @transport, credentials: { api_key: 'synthetic-host-key', callback_secret: 'synthetic-host-secret' })
  end

  it 'shares reservation across canonical and aliased actions and refuses changed identity even after success' do
    adapter = service
    operation = PaygenHostExample.operation('independent-create')
    first = adapter.create_request(operation, :sbp)
    expect(first['success']).to be(true)
    expect(adapter.create_request(operation, 'create')).to include('duplicate' => true, 'provider_id' => first['provider_id'])
    operation.amount = '2000.00'
    expect(adapter.create_request(operation, 'sbp').dig('error', 'code')).to eq('idempotency_conflict')
    operation.amount = '0.01'
    expect(adapter.create_request(operation, 'create').dig('error', 'code')).to eq('validation_error')
    expect(@transport.requests.size).to eq(1)
  end

  it 'preserves host refusal for status aliases and balance before transport' do
    base = Class.new(PaygenHostExample::BaseService) do
      def check_conditions(operation, action)
        if %w[check status balance].include?(action)
          backend.prechecks << [operation.respond_to?(:id) ? operation.id : nil, action]
          return { 'success' => false, 'error' => { 'code' => 'host_read_refused' } }
        end
        super
      end
    end
    adapter = service(base_service: base)
    operation = PaygenHostExample.operation('independent-host-refusal')
    operation.provider_operation_id = adapter.create_request(operation, 'sbp').fetch('provider_id')
    expect(adapter.create_request(operation, 'check').dig('error', 'code')).to eq('host_read_refused')
    expect(@backend.prechecks.last.last).to eq('check')
    expect(adapter.fetch_status(operation).dig('error', 'code')).to eq('host_read_refused')
    expect(adapter.balance.dig('error', 'code')).to eq('host_read_refused')
    count = @backend.prechecks.size
    expect(adapter.create_request(operation, 'unknown').dig('error', 'code')).to eq('operation_not_supported')
    expect(@backend.prechecks.size).to eq(count)
    expect(@transport.requests.size).to eq(1)
  end

  it 'shares in-flight reservation across canonical and aliased create calls' do
    adapter = service
    entered, release = Queue.new, Queue.new
    underlying = @transport
    wrapper = Object.new
    wrapper.define_singleton_method(:request) do |**request|
      entered << true
      release.pop
      underlying.request(**request)
    end
    adapter.configure_paygen(transport: wrapper, credentials: { api_key: 'synthetic-host-key', callback_secret: 'synthetic-host-secret' })
    operation = PaygenHostExample.operation('independent-inflight')
    first = Thread.new { adapter.create_request(operation, 'sbp') }
    begin
      Timeout.timeout(5) { entered.pop }
      second = adapter.create_request(operation, 'create')
      expect(second.dig('error', 'code')).to eq('reconciliation_required')
      expect(@transport.requests).to be_empty
    ensure
      release << true
      Timeout.timeout(5) { first.join }
    end
    expect(first.value['success']).to be(true)
    expect(@transport.requests.size).to eq(1)
  end

  it 'authenticates exact callback bytes, refuses conflicting parsed input, and retains retry after backend refusal' do
    adapter = service
    operation = PaygenHostExample.operation('independent-callback')
    created = adapter.create_request(operation, 'sbp')
    id = created.fetch('provider_id')
    @backend.operations[id] = operation
    payload = { 'payout_id' => id, 'external_id' => operation.id, 'event' => 'payout.completed', 'status' => 'completed' }
    raw = JSON.pretty_generate(payload) + "\n"
    compact_signature = OpenSSL::HMAC.hexdigest('SHA256', 'synthetic-host-secret', JSON.generate(payload))
    expect(adapter.process_callback(payload, raw_body: raw, headers: { 'X-NovaPay-Signature' => compact_signature }).dig('error', 'code')).to eq('invalid_signature')
    headers = { 'X-NovaPay-Signature' => OpenSSL::HMAC.hexdigest('SHA256', 'synthetic-host-secret', raw) }
    expect(adapter.process_callback(payload.merge('external_id' => 'other'), raw_body: raw, headers: headers).dig('error', 'code')).to eq('payload_mismatch')
    expect(@backend.effects).to be_empty
    @backend.fail_next = true
    expect(adapter.process_callback(payload, raw_body: raw, headers: headers).dig('error', 'code')).to eq('backend_busy')
    expect(@backend.effects).to be_empty
    expect(adapter.process_callback(payload, raw_body: raw, headers: headers)).to include('backend_applied' => true)
    # Semantic duplicate has different original wire bytes and its own valid HMAC.
    reordered = JSON.generate(payload.to_a.reverse.to_h)
    headers['X-NovaPay-Signature'] = OpenSSL::HMAC.hexdigest('SHA256', 'synthetic-host-secret', reordered)
    expect(adapter.process_callback(payload, raw_body: reordered, headers: headers)).to include('ignored' => 'duplicate')
    expect(@backend.effects).to eq([[id, 'approved']])
  end
end
