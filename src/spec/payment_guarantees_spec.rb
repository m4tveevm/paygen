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
                      state_namespace: 'independent-merchant',
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

  def correlation_policy
    config['response_bindings'] = {
      'merchant_reference' => { 'response_path' => 'external_id', 'operation_path' => 'id',
                                'roles' => %w[create status cancel], 'required' => true },
      'amount' => { 'response_path' => 'amount', 'operation_path' => 'amount',
                    'roles' => %w[create status cancel], 'required' => true, 'response_unit' => 'minor' },
      'currency' => { 'response_path' => 'currency', 'operation_path' => 'currency',
                      'roles' => %w[create status cancel], 'required' => true }
    }
    schema = { 'type' => 'object', 'required' => %w[id status amount currency], 'properties' => {
      'id' => { 'type' => 'string' }, 'status' => { 'type' => 'string' },
      'external_id' => { 'type' => 'string' }, 'amount' => { 'type' => 'number' }, 'currency' => { 'type' => 'string' }
    } }
    %w[create status cancel].each do |role|
      config['endpoints'][role]['responses'] = { '200' => { 'content' => { 'application/json' => { 'schema' => schema } } } }
    end
    schema
  end

  { 'merchant_reference' => { 'external_id' => 'unrelated-operation' },
    'amount' => { 'amount' => 1235 }, 'currency' => { 'currency' => 'USD' } }.each do |binding, mismatch|
    it "rejects schema-valid foreign #{binding} on create and requires reconciliation instead of caching approval" do
      schema = correlation_policy
      payload = { 'id' => 'p-1', 'status' => 'completed', 'external_id' => 'merchant-operation',
                  'amount' => 1234, 'currency' => 'RUB' }.merge(mismatch)
      expect(JSONSchemer.schema(schema).valid?(payload)).to be(true)
      adapter = build_adapter(independent_transport { |_request| { status: 200, headers: {}, body: JSON.generate(payload) } })
      expect(adapter.create_request(operation).dig('error'))
        .to include('code' => 'response_binding_mismatch', 'binding' => binding, 'ambiguous' => true, 'retryable' => false)
      expect(adapter.create_request(operation).dig('error', 'code')).to eq('reconciliation_required')
      expect(requests.length).to eq(1)
    end

    %w[status cancel].each do |role|
      it "does not poison lifecycle or the successful create cache with #{role} #{binding} mismatch" do
        correlation_policy
        transport = independent_transport do |_request|
          extras = { 'external_id' => 'merchant-operation' }
          extras.merge!(mismatch) if requests.length == 2
          payout_response(status: requests.length == 1 ? 'pending' : 'completed', extra: extras)
        end
        adapter = build_adapter(transport)
        expect(adapter.create_request(operation)['status']).to eq('in_progress')
        bound = operation.merge('provider_id' => 'p-1')
        result = role == 'status' ? adapter.fetch_status(bound) : adapter.cancel(bound)
        expect(result.dig('error')).to include('code' => 'response_binding_mismatch', 'binding' => binding)
        expect(adapter.create_request(operation)).to include('status' => 'in_progress', 'duplicate' => true)
        expect(adapter.fetch_status(bound)['status']).to eq('approved')
        expect(requests.length).to eq(3)
      end
    end
  end

  it 'checks an explicit provider identity binding independently of the normal routing ID' do
    correlation_policy
    config['response_bindings']['provider_id'] = {
      'response_path' => 'details.payout_id', 'operation_path' => 'provider_id',
      'roles' => ['status'], 'required' => true
    }
    transport = independent_transport do |_request|
      payout_response(status: 'completed', extra: { 'external_id' => 'merchant-operation',
                                                   'details' => { 'payout_id' => 'some-other-payout' } })
    end
    result = build_adapter(transport).fetch_status(operation.merge('provider_id' => 'p-1'))
    expect(result.dig('error')).to include('code' => 'response_binding_mismatch', 'binding' => 'provider_id')
  end

  it 'rejects missing required evidence even when the response schema makes that field optional' do
    schema = correlation_policy
    response = payout_response(status: 'completed')
    expect(JSONSchemer.schema(schema).valid?(JSON.parse(response.fetch(:body)))).to be(true)
    result = build_adapter(independent_transport { |_request| response }).create_request(operation)
    expect(result.dig('error')).to include('code' => 'missing_response_evidence', 'binding' => 'merchant_reference', 'ambiguous' => true)
  end

  it 'treats optional evidence as skippable only when absent, not when a wrong value is present' do
    correlation_policy
    config['response_bindings']['merchant_reference']['required'] = false
    adapter = build_adapter(independent_transport do |_request|
      payout_response(status: 'completed', extra: requests.length == 1 ? {} : { 'external_id' => 'wrong-operation' })
    end)
    expect(adapter.create_request(operation)['status']).to eq('approved')
    expect(adapter.create_request(operation.merge('id' => 'another-operation')).dig('error'))
      .to include('code' => 'response_binding_mismatch', 'binding' => 'merchant_reference')
    expect(requests.length).to eq(2)
  end

  it 'requires the expected operation fields before HTTP for required applicable bindings only' do
    correlation_policy
    adapter = build_adapter(independent_transport { |_request| raise 'Missing operation evidence must be rejected before HTTP' })
    expect(adapter.fetch_status('provider_id' => 'p-1').dig('error'))
      .to include('code' => 'response_binding_input_missing', 'binding' => 'merchant_reference', 'ambiguous' => false)
    expect(requests).to be_empty
    config['response_bindings'].each_value { |rule| rule['roles'] = ['create'] }
    valid = build_adapter(independent_transport { |_request| payout_response(status: 'completed') })
    expect(valid.fetch_status('provider_id' => 'p-1')['status']).to eq('approved')
  end

  it 'compares declared major-unit evidence exactly beyond the Float integer precision range' do
    correlation_policy
    config['response_bindings']['amount']['response_unit'] = 'major'
    transport = independent_transport do |_request|
      { status: 200, headers: {}, body: '{"id":"p-1","status":"completed","external_id":"merchant-operation","amount":90071992547409.93,"currency":"RUB"}' }
    end
    adapter = build_adapter(transport)
    exact = operation.merge('amount' => '90071992547409.93')
    expect(adapter.create_request(exact)['status']).to eq('approved')
    expect(adapter.create_request(exact).dig('data', 'amount')).to eq(BigDecimal('90071992547409.93'))
    expect(requests.length).to eq(1)
  end

  it 'does not round excessive precision or accept Float evidence from an already parsed transport body' do
    correlation_policy
    config['response_bindings']['amount']['response_unit'] = 'major'
    [BigDecimal('12.3401'), 12.34].each do |amount|
      payload = { 'id' => 'p-1', 'status' => 'completed', 'external_id' => 'merchant-operation', 'amount' => amount, 'currency' => 'RUB' }
      adapter = adapter_class.new(transport: independent_transport { |_request| { status: 200, headers: {}, body: payload } })
      expect(adapter.create_request(operation).dig('error'))
        .to include('code' => 'response_binding_mismatch', 'binding' => 'amount')
    end
  end

  it 'converts declared major response units against operations already expressed in minor units' do
    correlation_policy
    config['amount']['input_unit'] = 'minor'
    config['response_bindings']['amount']['response_unit'] = 'major'
    result = build_adapter(independent_transport do |_request|
      { status: 200, headers: {}, body: '{"id":"p-1","status":"completed","external_id":"merchant-operation","amount":12.34,"currency":"RUB"}' }
    end).create_request(operation.merge('amount' => 1234))
    expect(result['status']).to eq('approved')
  end

  it 'uses exact currency comparison and makes no undeclared case normalization' do
    correlation_policy
    result = build_adapter(independent_transport do |_request|
      payout_response(status: 'completed', extra: { 'external_id' => 'merchant-operation', 'currency' => 'rub' })
    end).create_request(operation)
    expect(result.dig('error')).to include('code' => 'response_binding_mismatch', 'binding' => 'currency')
  end

  it 'does not infer response bindings in a profile that has not opted in' do
    expect(config).not_to have_key('response_bindings')
    result = build_adapter(independent_transport do |_request|
      payout_response(status: 'completed', extra: { 'external_id' => 'unbound-reference', 'amount' => 1, 'currency' => 'USD' })
    end).create_request(operation)
    expect(result['status']).to eq('approved')
  end

  it 'rejects every unscoped external-store user before transport, store access or callback effects' do
    expect(store).not_to receive(:synchronize)
    effects = []
    transport = independent_transport { |_request| raise 'Unscoped requests must not be sent' }
    ['merchant-a-secret', 'merchant-b-secret'].each do |secret|
      adapter = adapter_class.new(transport: transport, state_store: store,
                                  credentials: { api_key: secret, callback_secret: 'test-callback-secret' })
      adapter.define_singleton_method(:paygen_callback_result) { |result, _payload| effects << result; result }
      expect(adapter.create_request(operation).dig('error', 'code')).to eq('state_namespace_required')
      expect(adapter.fetch_status(operation.merge('provider_id' => 'p-1')).dig('error', 'code')).to eq('state_namespace_required')
      expect(signed_callback(adapter, { 'id' => 'p-1', 'status' => 'completed' }).dig('error', 'code'))
        .to eq('state_namespace_required')
    end
    expect(requests).to be_empty
    expect(effects).to be_empty
  end

  it 'isolates the same merchant and provider IDs for two accounts sharing a namespace and store' do
    provider_key_policy
    config['auth'] = { 'type' => 'apiKey', 'name' => 'X-API-Key', 'credential' => 'api_key' }
    transport = independent_transport do |request|
      payout_response(extra: { 'owner' => request[:headers].fetch('X-API-Key').delete_suffix('-secret') })
    end
    first, second = %w[merchant-a merchant-b].map do |account|
      adapter_class.new(transport: transport, state_store: store, state_namespace: 'shared-installation', account: account,
                        credentials: { api_key: "#{account}-secret", callback_secret: 'test-callback-secret' })
    end
    expect(first.create_request(operation).dig('data', 'owner')).to eq('merchant-a')
    expect(second.create_request(operation).dig('data', 'owner')).to eq('merchant-b')
    expect(requests.map { |request| request[:headers].fetch('X-Payout-Key') }.uniq.length).to eq(2)
    expect(signed_callback(first, { 'id' => 'p-1', 'status' => 'completed', 'event_id' => 'same-event' })['status'])
      .to eq('approved')
    expect(signed_callback(second, { 'id' => 'p-1', 'status' => 'pending', 'event_id' => 'same-event' })['status'])
      .to eq('in_progress')
    expect(first.create_request(operation)).to include('status' => 'approved', 'duplicate' => true)
    expect(second.create_request(operation)).to include('status' => 'in_progress', 'duplicate' => true)
    expect(requests.length).to eq(2)
  end

  it 'supports namespace-only integrations and preserves reservations across credential rotation' do
    provider_key_policy
    config['auth'] = { 'type' => 'apiKey', 'name' => 'X-API-Key', 'credential' => 'api_key' }
    transport = independent_transport { |_request| payout_response }
    adapters = [['integration-a', 'first-secret'], ['integration-b', 'second-secret'], ['integration-a', 'rotated-secret']].map do |namespace, secret|
      adapter_class.new(transport: transport, state_store: store, state_namespace: namespace,
                        credentials: { api_key: secret })
    end
    results = adapters.map { |adapter| adapter.create_request(operation) }
    expect(results.map { |result| result['success'] }).to eq([true, true, true])
    expect(results.last['duplicate']).to be(true)
    expect(requests.length).to eq(2)
    expect(requests.map { |request| request[:headers].fetch('X-Payout-Key') }.uniq.length).to eq(2)
    store.synchronize do |state|
      expect(state.keys.join).not_to match(/first-secret|second-secret|rotated-secret/)
    end
  end

  it 'preserves an ambiguous reservation when credentials rotate under a stable account' do
    transport = independent_transport { |_request| raise Timeout::Error }
    original, rotated = %w[first-secret rotated-secret].map do |secret|
      adapter_class.new(transport: transport, state_store: store, account: 'stable-merchant', credentials: { api_key: secret })
    end
    expect(original.create_request(operation).dig('error', 'ambiguous')).to be(true)
    expect(rotated.create_request(operation).dig('error', 'code')).to eq('reconciliation_required')
    expect(requests.length).to eq(1)
  end

  it 'does not collide account and provider identity separators in lifecycle keys' do
    transport = independent_transport { |_request| raise 'Callbacks must not send requests' }
    first, second = ['account:provider', 'account'].map do |account|
      adapter_class.new(transport: transport, state_store: store, account: account,
                        credentials: { callback_secret: 'test-callback-secret' })
    end
    expect(signed_callback(first, { 'id' => 'id', 'status' => 'completed' })['status']).to eq('approved')
    expect(signed_callback(second, { 'id' => 'provider:id', 'status' => 'pending' }))
      .to include('status' => 'in_progress', 'provider_id' => 'provider:id')
  end

  it 'fails closed on legacy shared-store reservations and lifecycle state instead of redispatching' do
    account = 'existing-merchant'
    prefix = "independent-contract:sandbox:#{account}"
    merchant_digest = Digest::SHA256.hexdigest(operation.fetch('id'))
    old_request = "request:#{prefix}:#{merchant_digest}"
    old_lifecycle = "lifecycle:#{prefix}:p-1"
    legacy = { old_request => { 'inflight' => false, 'fingerprint' => 'old-ambiguous-create' },
               old_lifecycle => { 'status' => 'approved', 'provider_status' => 'completed' } }
    store.synchronize { |state| state.merge!(legacy) }
    adapter = adapter_class.new(state_store: store, account: account,
                                credentials: { callback_secret: 'test-callback-secret' },
                                transport: independent_transport { |_request| raise 'Legacy state must be reconciled first' })
    [adapter.create_request(operation), adapter.fetch_status(operation.merge('provider_id' => 'p-1')),
     signed_callback(adapter, { 'id' => 'p-1', 'status' => 'completed' })].each do |result|
      expect(result.dig('error')).to include('code' => 'state_migration_required',
                                             'action' => 'reconcile_and_migrate_state', 'retryable' => false)
    end
    store.synchronize { |state| expect(state).to eq(legacy) }
    expect(requests).to be_empty
  end

  it 'does not bypass legacy unscoped state when adding a newly required account' do
    unscoped = "request:independent-contract:sandbox::#{Digest::SHA256.hexdigest(operation.fetch('id'))}"
    store.synchronize { |state| state[unscoped] = { 'result' => { 'status' => 'approved', 'provider_id' => 'already-paid' } } }
    adapter = adapter_class.new(state_store: store, account: 'newly-explicit-account',
                                transport: independent_transport { |_request| raise 'An old unscoped reservation must not be ignored' })
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('state_migration_required')
    expect(requests).to be_empty
    store.synchronize { |state| expect(state.keys).to eq([unscoped]) }
  end

  it 'snapshots scope configuration without freezing or following caller-owned mutable strings' do
    namespace = +'integration-a'
    account = +'merchant-a'
    mode = +'sandbox'
    adapter = adapter_class.new(state_store: store, state_namespace: namespace, account: account, mode: mode,
                                transport: independent_transport { |_request| payout_response })
    expect(adapter.create_request(operation)['success']).to be(true)
    namespace.replace('integration-b')
    account.replace('merchant-b')
    mode.replace('live')
    expect(adapter.create_request(operation)).to include('success' => true, 'duplicate' => true)
    expect(requests.length).to eq(1)
  end

  it 'also snapshots the stable account supplied through credentials without freezing the caller value' do
    account = +'merchant-from-credentials'
    adapter = adapter_class.new(state_store: store, credentials: { account: account },
                                transport: independent_transport { |_request| payout_response })
    expect(adapter.create_request(operation)['success']).to be(true)
    account.replace('rotated-caller-value')
    expect(adapter.create_request(operation)).to include('success' => true, 'duplicate' => true)
    expect(requests.length).to eq(1)
  end

  it 'delivers distinct progress evidence but deduplicates event IDs and repeated terminal effects' do
    config['status_mapping']['processing'] = 'in_progress'
    config['status_order'].insert(1, 'processing')
    adapter = build_adapter(independent_transport { |_request| payout_response })
    delivered = []
    approved = []
    adapter.define_singleton_method(:approve_operation) { |id| approved << id; { 'success' => true } }
    adapter.define_singleton_method(:paygen_callback_result) do |result, payload|
      delivered << payload.fetch('event_id')
      paygen_backend_callback_result(result, payload)
    end
    events = [%w[one pending initial], %w[two processing processing],
              %w[three completed first-terminal], %w[four completed updated-terminal]].map do |id, status, marker|
      { 'id' => 'p-1', 'event_id' => id, 'status' => status, 'marker' => marker }
    end
    first, progress, terminal, update = events.map { |event| signed_callback(adapter, event) }
    expect(first['status']).to eq('in_progress')
    expect(progress).to include('status' => 'in_progress', 'provider_status' => 'processing')
    expect(progress.dig('data', 'marker')).to eq('processing')
    expect(progress['ignored']).to be_nil
    expect(terminal['backend_applied']).to be(true)
    expect(update).to include('status' => 'approved', 'effect_ignored' => 'duplicate_terminal_outcome')
    expect(update.dig('data', 'marker')).to eq('updated-terminal')
    expect(update['ignored']).to be_nil
    expect(signed_callback(adapter, events.last)['ignored']).to eq('duplicate')
    stale = adapter.fetch_status(operation.merge('provider_id' => 'p-1'))
    expect(stale.dig('data', 'marker')).to eq('updated-terminal')
    expect(delivered).to eq(%w[one two three])
    expect(approved).to eq(['p-1'])
  end

  [false, true].each do |serialized|
    it "preserves exact nested decimal result types through #{serialized ? 'JSON-backed' : 'memory'} store and retained paths" do
      selected_store = if serialized
                         Class.new do
                           def initialize = @snapshot = '{}'
                           def synchronize
                             state = JSON.parse(@snapshot)
                             result = yield state
                             @snapshot = JSON.generate(state)
                             result
                           end
                         end.new
                       else
                         store
                       end
      transport = independent_transport do |_request|
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: '{"id":"p-1","status":"completed","amount":90071992547409.93,"nested":[{"fee":0.0100,"text":"0.0100","count":3,"flag":false}]}' }
      end
      build = -> { adapter_class.new(transport: transport, state_store: selected_store, account: 'decimal-merchant') }
      first = build.call.create_request(operation)
      expect(first.dig('data', 'amount')).to be_a(BigDecimal)
      expect(first.dig('data', 'amount')).to eq(BigDecimal('90071992547409.93'))
      first['data']['nested'][0]['text'].replace('caller mutation')
      cached = build.call.create_request(operation)
      expected = { 'fee' => BigDecimal('0.0100'), 'text' => '0.0100', 'count' => 3, 'flag' => false }
      expect(cached.dig('data', 'amount')).to be_a(BigDecimal)
      expect(cached.dig('data', 'amount')).to eq(BigDecimal('90071992547409.93'))
      expect(cached.dig('data', 'nested', 0)).to eq(expected)
      expect(cached.dig('data', 'nested', 0, 'fee')).to be_a(BigDecimal)
      retained_adapter = build.call
      retained_adapter.define_singleton_method(:paygen_response) do |response, _role, _operation|
        response.merge('body' => '{"id":"p-1","status":"pending"}')
      end
      retained = retained_adapter.fetch_status(operation.merge('provider_id' => 'p-1'))
      expect(retained).to include('status' => 'approved', 'ignored' => 'invalid_transition')
      expect(retained.dig('data', 'nested', 0)).to eq(expected)
      expect(retained.dig('data', 'amount')).to be_a(BigDecimal)
      expect(requests.length).to eq(2)
    end
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
