# frozen_string_literal: true

require 'spec_helper'
require 'paygen/runtime/adapter'
require_relative 'support/provider_harness'

RSpec.describe 'Payment guarantees against an independent provider' do
  let(:clock_time) { [Time.at(1_800_000_000)] }
  let(:store) { Paygen::Runtime::MemoryStateStore.new }
  let(:requests) { [] }
  let(:operation) { { 'id' => 'merchant-operation', 'amount' => '12.34', 'currency' => 'RUB' } }
  let(:config) do
    {
      'provider' => 'independent-contract', 'mode' => 'sandbox',
      'servers' => ['https://payments.example.test'],
      'amount' => { 'scale' => 100, 'currencies' => ['RUB'] },
      'idempotency' => {},
      'request_mapping' => {
        'reference' => { 'from' => 'id' }, 'amount' => { 'from' => 'amount', 'transform' => 'minor_units' },
        'currency' => { 'from' => 'currency' }
      },
      'response' => { 'id' => 'id', 'status' => 'status' },
      'status_mapping' => { 'pending' => 'in_progress', 'completed' => 'approved',
                            'rejected' => 'rejected', 'reversed' => 'rejected' },
      # Ordering alone does not authorize a conflicting terminal outcome.
      'status_order' => %w[pending completed rejected reversed],
      'callback' => {
        'id' => 'id', 'status' => 'status', 'event_id' => 'event_id',
        'signature' => { 'algorithm' => 'hmac-sha256', 'header' => 'X-Signature', 'credential' => 'callback_secret' }
      },
      'endpoints' => {
        'create' => { 'method' => 'post', 'path' => '/payouts' },
        'status' => { 'method' => 'get', 'path' => '/payouts/{payout_id}' },
        'cancel' => { 'method' => 'post', 'path' => '/payouts/{payout_id}/cancel' },
        'callback' => { 'method' => 'post', 'path' => '/callbacks' }
      }
    }
  end
  let(:adapter_class) do
    Class.new(Provider::BaseService) do
      include Paygen::Runtime::Adapter
    end.tap { |klass| klass.const_set(:PAYGEN_CONFIG, config) }
  end

  def independent_transport(&behavior)
    recorded = requests
    Object.new.tap do |transport|
      transport.define_singleton_method(:request) do |**request|
        recorded << request
        behavior.call(request)
      end
    end
  end

  def build_adapter(transport)
    adapter_class.new(transport: transport, state_store: store,
                      credentials: { callback_secret: 'test-callback-secret' }, clock: -> { clock_time.first })
  end

  def payout_response(status: 'pending', id: 'p-1', extra: {}, http_status: 200)
    { status: http_status, headers: { 'Content-Type' => 'application/json' },
      body: JSON.generate({ 'id' => id, 'status' => status, 'amount' => 1234, 'currency' => 'RUB' }.merge(extra)) }
  end

  def signed_callback(adapter, payload, raw: JSON.generate(payload))
    signature = OpenSSL::HMAC.hexdigest('SHA256', 'test-callback-secret', raw)
    adapter.process_callback(payload, raw_body: raw, headers: { 'X-Signature' => signature })
  end

  def provider_key_policy
    config['idempotency'] = { 'strategy' => 'provider_key', 'header' => 'X-Payout-Key', 'ttl_seconds' => 60 }
  end

  it 'does not invent provider idempotency support or repeat a committed payout after a lost response' do
    committed = []
    transport = independent_transport do |_request|
      # This provider ignores all unrecognized headers and commits every POST.
      committed << "p-#{committed.length + 1}"
      raise Timeout::Error
    end
    adapter = build_adapter(transport)

    expect(adapter.create_request(operation).dig('error', 'ambiguous')).to be(true)
    expect(build_adapter(transport).create_request(operation).dig('error'))
      .to include('code' => 'reconciliation_required', 'retryable' => false)
    expect(committed).to eq(['p-1'])
    expect(requests.first[:headers].keys.map(&:downcase)).not_to include('idempotency-key')
  end

  it 'keeps a successful create cached after the provider key expires and across adapter instances' do
    provider_key_policy
    transport = independent_transport { |_request| payout_response(http_status: 201) }
    adapter = build_adapter(transport)
    original = adapter.create_request(operation)
    expect(original).to include('success' => true, 'provider_id' => 'p-1')
    original['provider_id'] = 'caller-modified'

    clock_time[0] += 120
    expect(build_adapter(transport).create_request(operation))
      .to include('success' => true, 'provider_id' => 'p-1', 'duplicate' => true)
    expect(requests.length).to eq(1)
  end

  it 'permits an explicitly supported provider key retry within its lifetime using the same key' do
    provider_key_policy
    committed_by_key = {}
    transport = independent_transport do |request|
      key = request[:headers].fetch('X-Payout-Key')
      committed_by_key[key] ||= "p-#{committed_by_key.length + 1}"
      raise Timeout::Error if requests.length == 1

      payout_response(id: committed_by_key.fetch(key), http_status: 201)
    end
    adapter = build_adapter(transport)
    expect(adapter.create_request(operation).dig('error', 'ambiguous')).to be(true)
    clock_time[0] += 30
    expect(adapter.create_request(operation)).to include('success' => true, 'provider_id' => 'p-1')
    expect(requests.map { |request| request[:headers]['X-Payout-Key'] }.uniq.length).to eq(1)
    expect(requests.length).to eq(2)
    expect(committed_by_key.values).to eq(['p-1'])
  end

  it 'does not retry an ambiguous create when the documented provider key lifetime has elapsed' do
    provider_key_policy
    committed = []
    transport = independent_transport do |_request|
      committed << "p-#{committed.length + 1}"
      raise Timeout::Error
    end
    adapter = build_adapter(transport)
    expect(adapter.create_request(operation).dig('error', 'ambiguous')).to be(true)
    clock_time[0] += 61
    expect(build_adapter(transport).create_request(operation).dig('error'))
      .to include('code' => 'reconciliation_required', 'retryable' => false, 'ambiguous' => true)
    expect(committed).to eq(['p-1'])
  end

  it 'does not refresh provider retention after another lost retry response' do
    provider_key_policy
    transport = independent_transport { |_request| raise Timeout::Error }
    adapter = build_adapter(transport)
    expect(adapter.create_request(operation).dig('error', 'ambiguous')).to be(true)
    clock_time[0] += 30
    expect(adapter.create_request(operation).dig('error', 'ambiguous')).to be(true)
    clock_time[0] += 31
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('reconciliation_required')
    expect(requests.length).to eq(2)
  end

  it 'does not infer a retry guarantee from a configured body key that was never sent' do
    config['idempotency'] = { 'strategy' => 'provider_key', 'body' => 'missing_reference', 'ttl_seconds' => 60 }
    transport = independent_transport { |_request| raise Timeout::Error }
    adapter = build_adapter(transport)
    expect(adapter.create_request(operation).dig('error', 'ambiguous')).to be(true)
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('reconciliation_required')
    expect(requests.length).to eq(1)
  end

  it 'does not extend an existing reservation by changing the configured key lifetime' do
    provider_key_policy
    transport = independent_transport { |_request| raise Timeout::Error }
    adapter = build_adapter(transport)
    expect(adapter.create_request(operation).dig('error', 'ambiguous')).to be(true)
    clock_time[0] += 61
    config['idempotency']['ttl_seconds'] = 3600
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('reconciliation_required')
    expect(requests.length).to eq(1)
  end

  it 'rejects a request hook rotating the actual wire key after an ambiguous commit' do
    provider_key_policy
    transport = independent_transport { |_request| raise Timeout::Error }
    adapter = build_adapter(transport)
    expect(adapter.create_request(operation).dig('error', 'ambiguous')).to be(true)
    adapter.define_singleton_method(:paygen_request) do |request, _role, _operation|
      request.merge(headers: request.fetch(:headers).merge('X-Payout-Key' => 'changed-by-hook'))
    end
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('idempotency_conflict')
    expect(requests.length).to eq(1)
  end

  it 'blocks overlapping creates even when a provider key explicitly supports retries' do
    provider_key_policy
    overlapping_result = nil
    transport = nil
    transport = independent_transport do |_request|
      if requests.length == 1
        overlapping_result = build_adapter(transport).create_request(operation)
      end
      payout_response(http_status: 201)
    end

    expect(build_adapter(transport).create_request(operation)['success']).to be(true)
    expect(overlapping_result.dig('error')).to include('retryable' => false, 'ambiguous' => true)
    expect(requests.length).to eq(1)
  end

  it 'does not let a changed explicit provider key resubmit the same ambiguous merchant operation' do
    provider_key_policy
    committed = []
    transport = independent_transport do |request|
      committed << request[:headers].fetch('X-Payout-Key')
      raise Timeout::Error
    end
    adapter = build_adapter(transport)
    first = operation.merge('idempotency_key' => 'merchant-key-original')
    changed = operation.merge('idempotency_key' => 'merchant-key-replacement')

    expect(adapter.create_request(first).dig('error', 'ambiguous')).to be(true)
    clock_time[0] += 10
    expect(build_adapter(transport).create_request(changed).dig('error', 'code')).to eq('idempotency_conflict')
    expect(committed).to eq(['merchant-key-original'])
    expect(requests.length).to eq(1)
  end

  it 'rejects one explicit provider key being shared by distinct merchant operations' do
    provider_key_policy
    # Some providers omit the merchant identity in their request bodies. Key
    # ownership must still distinguish operations whose wire payloads match.
    config['request_mapping'].delete('reference')
    transport = independent_transport { |_request| payout_response(http_status: 201) }
    first = operation.merge('idempotency_key' => 'shared-provider-key')
    second = first.merge('id' => 'another-merchant-operation')
    adapter = build_adapter(transport)

    expect(adapter.create_request(first)['success']).to be(true)
    expect(build_adapter(transport).create_request(second).dig('error', 'code')).to eq('idempotency_conflict')
    expect(requests.length).to eq(1)
  end

  ['sim_06ed5551082250661cad', *(13..19).map { |length| '1' * length }].each do |provider_id|
    it "preserves operational ID #{provider_id.inspect} through create, status and cancellation" do
      transport = independent_transport do |_request|
        payout_response(id: provider_id, extra: { 'card' => '4111111111111111', 'note' => 'test-callback-secret' })
      end
      adapter = build_adapter(transport)
      created = adapter.create_request(operation)
      expect(created['provider_id']).to eq(provider_id)
      expect(created.dig('data', 'card')).to eq('[REDACTED]')
      expect(created.dig('data', 'note')).to eq('[REDACTED]')
      expect(created.dig('data', 'id')).not_to eq(provider_id)

      bound_operation = operation.merge('provider_id' => created.fetch('provider_id'))
      expect(adapter.fetch_status(bound_operation)['provider_id']).to eq(provider_id)
      expect(adapter.cancel(bound_operation)['provider_id']).to eq(provider_id)
      expect(requests.map { |request| request[:url] }).to eq([
        'https://payments.example.test/payouts',
        "https://payments.example.test/payouts/#{provider_id}",
        "https://payments.example.test/payouts/#{provider_id}/cancel"
      ])
    end
  end

  it 'keeps a verified terminal callback authoritative over a later stale polling response' do
    transport = independent_transport { |_request| payout_response }
    callback_adapter = build_adapter(transport)
    expect(signed_callback(callback_adapter, { 'id' => 'p-1', 'status' => 'completed', 'event_id' => 'paid' }))
      .to include('success' => true, 'status' => 'approved')

    result = build_adapter(transport).fetch_status(operation.merge('provider_id' => 'p-1'))
    expect(result).to include('success' => true, 'status' => 'approved', 'provider_status' => 'completed')
    expect(result['ignored']).not_to be_nil
  end

  it 'prevents an undocumented terminal conflict across polling and callback sources' do
    transport = independent_transport { |_request| payout_response(status: 'completed') }
    adapter = build_adapter(transport)
    expect(adapter.fetch_status(operation.merge('provider_id' => 'p-1'))['status']).to eq('approved')

    result = signed_callback(build_adapter(transport), { 'id' => 'p-1', 'status' => 'rejected', 'event_id' => 'conflict' })
    expect(result).to include('success' => true, 'status' => 'approved', 'provider_status' => 'completed')
    expect(result['ignored']).not_to be_nil
  end

  it 'permits an explicitly documented reversal of a previously approved payout' do
    config['status_transitions'] = { 'completed' => ['reversed'] }
    transport = independent_transport { |_request| payout_response(status: 'completed') }
    adapter = build_adapter(transport)
    expect(adapter.fetch_status(operation.merge('provider_id' => 'p-1'))['status']).to eq('approved')

    result = signed_callback(adapter, { 'id' => 'p-1', 'status' => 'reversed', 'event_id' => 'reversal' })
    expect(result).to include('success' => true, 'status' => 'rejected', 'provider_status' => 'reversed')
    expect(result['ignored']).to be_nil
  end

  it 'applies a logical callback without an event ID once despite valid JSON reserialization' do
    config['callback'].delete('event_id')
    transport = independent_transport { |_request| raise 'Callbacks must not send provider requests' }
    applied = []
    adapter = build_adapter(transport)
    adapter.define_singleton_method(:approve_operation) { |id| applied << id; { 'success' => true } }
    adapter.define_singleton_method(:paygen_callback_result) do |result, payload|
      paygen_backend_callback_result(result, payload)
    end
    payload = { 'id' => 'p-1', 'status' => 'completed', 'metadata' => { 'b' => 2, 'a' => 1 } }
    reserialized = "{\n  \"metadata\": {\"a\":1,\"b\":2}, \"status\":\"completed\", \"id\":\"p-1\"\n}"

    expect(signed_callback(adapter, payload)['backend_applied']).to be(true)
    expect(signed_callback(adapter, payload, raw: reserialized)).to include('status' => 'approved', 'ignored' => 'duplicate')
    expect(applied).to eq(['p-1'])
    expect(requests).to be_empty
  end

  it 'rejects a successful HTTP response missing required contract fields and blocks redispatch' do
    config['endpoints']['create']['responses'] = {
      '201' => { 'description' => 'Created payout', 'content' => {
        'application/json' => { 'schema' => {
          'type' => 'object', 'required' => %w[id status amount currency],
          'properties' => { 'id' => { 'type' => 'string' }, 'status' => { 'type' => 'string' },
                            'amount' => { 'type' => 'integer' }, 'currency' => { 'type' => 'string' } }
        } }
      } }
    }
    transport = independent_transport do |_request|
      { status: 201, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate('id' => 'p-1', 'status' => 'completed') }
    end
    adapter = build_adapter(transport)

    result = adapter.create_request(operation)
    expect(result['success']).to be(false)
    expect(result.dig('error', 'ambiguous')).to be(true)
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('reconciliation_required')
    expect(requests.length).to eq(1)
  end

  it 'keeps semantically incomplete successful creates ambiguous even without a declared response schema' do
    transport = independent_transport do |_request|
      { status: 201, headers: { 'Content-Type' => 'application/json' }, body: '{"id":"p-1"}' }
    end
    adapter = build_adapter(transport)
    expect(adapter.create_request(operation).dig('error'))
      .to include('ambiguous' => true, 'retryable' => false, 'action' => 'reconcile_before_retry')
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('reconciliation_required')
    expect(requests.length).to eq(1)
  end
end
