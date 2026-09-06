# frozen_string_literal: true

require 'spec_helper'
require 'paygen/runtime/adapter'
require 'prop_check'
require_relative 'support/provider_harness'

RSpec.describe Paygen::Runtime::Adapter do
  let(:config) do
    {
      'provider' => 'reference', 'mode' => 'sandbox', 'servers' => ['https://api.example.test/v1'],
      'amount' => { 'scale' => 100, 'minimum' => 100_000, 'maximum' => 10**15, 'currencies' => ['RUB'] },
      'request_mapping' => {
        'amount' => { 'from' => 'amount', 'transform' => 'minor_units' },
        'currency' => { 'from' => 'currency' }, 'external_id' => { 'from' => 'id' },
        'recipient.phone' => { 'from' => 'payout_requisite.sbp.phone' },
        'recipient.bank_code' => { 'from' => 'payout_requisite.sbp.bank_code' }
      },
      'status_mapping' => { 'pending' => 'in_progress', 'processing' => 'in_progress',
                            'paid' => 'approved', 'failed' => 'rejected', 'cancelled' => 'rejected' },
      'status_order' => %w[pending processing paid failed cancelled],
      'status_transitions' => { 'paid' => ['failed'] },
      'idempotency' => { 'strategy' => 'provider_key', 'header' => 'Idempotency-Key', 'ttl_seconds' => 60 },
      'response' => { 'id' => 'id', 'status' => 'status', 'error' => 'error.code' },
      'auth' => { 'type' => 'apiKey', 'in' => 'header', 'name' => 'X-API-Key', 'credential' => 'api_key' },
      'callback' => {
        'id' => 'payout_id', 'status' => 'status', 'event' => 'event', 'event_id' => 'event_id', 'sequence' => 'sequence',
        'signature' => { 'algorithm' => 'hmac-sha256', 'header' => 'X-Signature', 'credential' => 'callback_secret' },
        'events' => { 'payout.paid' => 'paid', 'payout.failed' => 'failed', 'payout.pending' => 'pending' }
      },
      'endpoints' => {
        'create' => {
          'method' => 'post', 'path' => '/payouts',
          'request_schema' => { 'type' => 'object', 'required' => %w[amount currency external_id recipient],
                                'properties' => { 'amount' => { 'type' => 'integer', 'minimum' => 100_000 },
                                                  'recipient' => { 'type' => 'object', 'required' => ['bank_code'] } } }
        },
        'status' => { 'method' => 'get', 'path' => '/payouts/{payout_id}' },
        'cancel' => { 'method' => 'post', 'path' => '/payouts/{payout_id}/cancel' },
        'balance' => { 'method' => 'get', 'path' => '/balance' },
        'callback' => { 'method' => 'post', 'path' => '/hooks' }
      }
    }
  end
  let(:transport) { double('transport') }
  let(:operation) do
    { 'id' => 'op-123', 'amount' => '15000.01', 'currency' => 'RUB',
      'payout_requisite' => { 'sbp' => { 'phone' => '79001234567', 'bank_code' => '044525225' } } }
  end
  let(:adapter) do
    klass = Class.new(Provider::BaseService) { include Paygen::Runtime::Adapter }
    klass.const_set(:PAYGEN_CONFIG, config)
    klass.new(credentials: { api_key: 'private-api-value', callback_secret: 'active-secret', old_secret: 'old-secret' },
              transport: transport, clock: -> { Time.at(1_800_000_000) })
  end

  def response(body, status: 200, headers: {})
    { status: status, headers: headers, body: JSON.generate(body) }
  end

  def callback(status: 'paid', sequence: 1, event_id: 'evt-1', secret: 'active-secret', extra: {})
    payload = { 'payout_id' => 'p-1', 'event' => "payout.#{status}", 'status' => status,
                'sequence' => sequence, 'event_id' => event_id }.merge(extra)
    payload.delete('sequence') if sequence.nil?
    raw = JSON.generate(payload)
    signature = OpenSSL::HMAC.hexdigest('SHA256', secret, raw)
    [payload, raw, { 'x-signature' => signature }]
  end

  def deliver(message)
    payload, raw, headers = message
    adapter.process_callback(payload, raw_body: raw, headers: headers)
  end

  it 'validates conditions, required recipient fields, exact minimum, and currency before any HTTP request' do
    expect(transport).not_to receive(:request)
    expect(adapter.check_conditions(operation.merge('amount' => '1000'))['success']).to be(true)
    expect(adapter.check_conditions(operation.merge('amount' => '999.99')).dig('error', 'code')).to eq('validation_error')
    expect(adapter.create_request(operation.merge('currency' => 'EUR')).dig('error', 'code')).to eq('validation_error')
    invalid = Marshal.load(Marshal.dump(operation))
    invalid['payout_requisite']['sbp'].delete('bank_code')
    expect(adapter.create_request(invalid).dig('error', 'violations')).to include('/recipient: required')
  end

  it 'rejects float, excess precision, exponent notation, negative and oversized amounts' do
    [1000.01, '1000.001', '1e5', '-2000', '1000000000000000000'].each do |amount|
      expect(adapter.check_conditions(operation.merge('amount' => amount))['success']).to be(false)
    end
  end

  it 'builds exact integer amounts and stable UUID keys, including across fresh adapter instances' do
    requests = []
    allow(transport).to receive(:request) do |**request|
      requests << request
      response({ 'id' => 'p-1', 'status' => 'pending', 'recipient' => operation['payout_requisite'] }, status: 201)
    end
    first = adapter.create_request(operation)
    adapter.create_request(operation)
    another = adapter.class.new(credentials: { api_key: 'key' }, transport: transport)
    another.create_request(operation)
    expect(first).to include('success' => true, 'status' => 'in_progress', 'provider_id' => 'p-1')
    expect(JSON.parse(requests.first[:body])['amount']).to eq(1_500_001)
    expect(requests.first[:headers]['X-API-Key']).to eq('private-api-value')
    expect(requests.map { |request| request[:headers]['Idempotency-Key'] }.uniq.size).to eq(1)
    expect(requests.first[:headers]['Idempotency-Key']).to match(/\A[\da-f]{8}-[\da-f]{4}-5[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}\z/)
    expect(first.dig('data', 'recipient')).to eq('[REDACTED]')
  end

  it 'prevents reuse of an operation key with a changed request body' do
    allow(transport).to receive(:request).and_return(response({ 'id' => 'p-1', 'status' => 'pending' }, status: 201))
    expect(adapter.create_request(operation)['success']).to be(true)
    expect(adapter.create_request(operation.merge('amount' => '15000.02')).dig('error', 'code')).to eq('idempotency_conflict')
    expect(transport).to have_received(:request).once
  end

  it 'reads canonical operation objects without allowing profile-controlled method execution' do
    model = Struct.new(:id, :amount, :currency, :payout_requisite) do
      attr_reader :destroy_calls

      def destroy
        @destroy_calls = (@destroy_calls || 0) + 1
        'destroyed'
      end

      def merchant_reference
        'trusted-reference'
      end
    end
    object = model.new(*operation.values_at('id', 'amount', 'currency', 'payout_requisite'))
    expect(adapter.check_conditions(object)['success']).to be(true)
    config['request_mapping']['currency'] = { 'from' => 'destroy' }
    config['allowed_attributes'] = ['destroy']
    expect(transport).not_to receive(:request)
    expect(adapter.create_request(object).dig('error', 'code')).to eq('validation_error')
    expect(object.destroy_calls).to be_nil
    config['request_mapping']['currency'] = { 'from' => 'currency' }
    config['request_mapping']['external_id'] = { 'from' => 'merchant_reference' }
    expect(adapter.check_conditions(object)['success']).to be(false)
    adapter.configure_paygen(transport: transport, allowed_attributes: ['merchant_reference'])
    expect(adapter.check_conditions(object)['success']).to be(true)
    expect(object.destroy_calls).to be_nil
  end

  it 'marks timeout-after-commit as ambiguous and requires reconciliation without automatic retry' do
    allow(transport).to receive(:request).and_raise(Timeout::Error)
    result = adapter.create_request(operation)
    expect(result['error']).to include('code' => 'transport_timeout', 'ambiguous' => true,
                                       'retryable' => false, 'action' => 'reconcile_before_retry')
    expect(transport).to have_received(:request).once
  end

  it 'requires reconciliation when a create response exceeds the transport limit after commit' do
    allow(transport).to receive(:request).and_raise(Paygen::Runtime::ResponseSizeError, 'Response exceeds size limit')
    result = adapter.create_request(operation)
    expect(result['error']).to include('code' => 'security_denial', 'ambiguous' => true,
                                       'retryable' => false, 'action' => 'reconcile_before_retry')
    expect(result.dig('error', 'idempotency_key')).not_to be_empty
    expect(adapter.fetch_status('provider_id' => 'p-1').dig('error', 'ambiguous')).to be(false)
  end

  it 'maps create 409 to the existing payout and cancel 409 to a state conflict' do
    allow(transport).to receive(:request).and_return(response({ 'id' => 'p-1', 'status' => 'pending' }, status: 409))
    expect(adapter.create_request(operation)).to include('success' => true, 'duplicate' => true)
    allow(transport).to receive(:request).and_return(response({ 'error' => { 'code' => 'invalid_status' } }, status: 409))
    expect(adapter.cancel(operation.merge('provider_id' => 'p-1')).dig('error', 'code')).to eq('state_conflict')
  end

  it 'honors Retry-After and keeps 5xx create outcomes ambiguous even when retry is configured' do
    allow(transport).to receive(:request).and_return(response({}, status: 429, headers: { 'retry-after' => '60' }))
    expect(adapter.create_request(operation)['error']).to include('retryable' => true, 'retry_after' => 60)
    config['errors'] = { '500' => { 'action' => 'retry' } }
    allow(transport).to receive(:request).and_return(response({}, status: 500))
    expect(adapter.create_request(operation)['error']).to include('retryable' => false, 'ambiguous' => true)
  end

  it 'fails closed for unknown statuses and malformed response JSON' do
    allow(transport).to receive(:request).and_return(response({ 'id' => 'p-1', 'status' => 'mystery' }))
    expect(adapter.fetch_status('provider_id' => 'p-1').dig('error', 'code')).to eq('unknown_status')
    allow(transport).to receive(:request).and_return({ status: 200, body: '<html>error</html>' })
    expect(adapter.fetch_status('provider_id' => 'p-1').dig('error', 'code')).to eq('invalid_provider_response')
  end

  it 'never approves a successful batch without a matching item outcome' do
    config['response']['scope'] = 'batch'
    allow(transport).to receive(:request).and_return(response({ 'id' => 'batch-1', 'status' => 'paid' }))
    expect(adapter.create_request(operation)['status']).to eq('in_progress')
    config['response']['roles'] = { 'status' => { 'items' => 'items', 'item_status' => 'status',
                                                 'item_external_id' => 'external_id', 'item_id' => 'id' } }
    allow(transport).to receive(:request).and_return(response({
      'id' => 'batch-1', 'status' => 'paid', 'items' => [{ 'id' => 'item-1', 'external_id' => 'op-123', 'status' => 'failed' }]
    }))
    expect(adapter.fetch_status(operation.merge('provider_id' => 'batch-1'))).to include('status' => 'rejected', 'provider_item_id' => 'item-1')
    expect(adapter.fetch_status(operation.merge('id' => 'wrong', 'provider_id' => 'batch-1')).dig('error', 'code')).to eq('ambiguous_item_evidence')
  end

  it 'requires exact signed raw body and constant-time validated signatures' do
    payload, raw, headers = callback
    expect(adapter.process_callback(payload, raw_body: raw, headers: headers)['status']).to eq('approved')
    expect(adapter.process_callback(payload, headers: headers).dig('error', 'code')).to eq('missing_raw_body')
    expect(adapter.process_callback(payload, raw_body: "#{raw} ", headers: headers).dig('error', 'code')).to eq('invalid_signature')
    expect(adapter.process_callback(payload.merge('status' => 'failed'), raw_body: raw, headers: headers).dig('error', 'code')).to eq('payload_mismatch')
    expect(Paygen::Runtime::Security.secure_compare('a', 'aa')).to be(false)
  end

  it 'supports secret rotation, rejects duplicate/out-of-order callbacks and preserves reversals' do
    config['callback']['signature']['credentials'] = %w[callback_secret old_secret]
    message = callback(secret: 'old-secret', sequence: 2)
    expect(deliver(message)['status']).to eq('approved')
    expect(deliver(message)).to include('ignored' => 'duplicate', 'status' => 'approved')
    expect(deliver(callback(status: 'pending', sequence: 1, event_id: 'late'))).to include('ignored' => 'out_of_order', 'status' => 'approved')
    expect(deliver(callback(status: 'failed', sequence: 3, event_id: 'reversal'))['status']).to eq('rejected')
  end

  it 'rejects status regressions when callbacks lack event IDs and timestamps' do
    config['callback'].delete('event_id')
    config['callback'].delete('sequence')
    expect(deliver(callback)['status']).to eq('approved')
    expect(deliver(callback(status: 'pending', event_id: 'late'))).to include('ignored' => 'invalid_transition', 'status' => 'approved')
  end

  it 'compares callback timestamps when one event omits its optional sequence number' do
    config['callback']['timestamp'] = 'created_at'
    first = callback(sequence: nil, extra: { 'created_at' => '2026-09-05T10:00:00Z' })
    reversal = callback(status: 'failed', sequence: 3, event_id: 'reversal',
                        extra: { 'created_at' => '2026-09-05T10:00:01Z' })
    expect(deliver(first)['status']).to eq('approved')
    expect(deliver(reversal)).to include('status' => 'rejected')
    expect(deliver(callback(status: 'failed', sequence: nil, event_id: 'older',
                            extra: { 'created_at' => '2026-09-05T09:59:59Z' })))
      .to include('status' => 'rejected', 'ignored' => 'out_of_order')
  end

  it 'keeps provider sequence ordering authoritative when both callbacks provide it' do
    config['callback']['timestamp'] = 'created_at'
    first = callback(sequence: 2, extra: { 'created_at' => '2026-09-05T10:00:01Z' })
    reversal = callback(status: 'failed', sequence: 3, event_id: 'reversal',
                        extra: { 'created_at' => '2026-09-05T10:00:00Z' })
    expect(deliver(first)['status']).to eq('approved')
    expect(deliver(reversal)['status']).to eq('rejected')
  end

  it 'rejects mismatched event/status, tenant, mode and callback scope' do
    config['callback'].merge!('account_field' => 'account', 'mode_field' => 'livemode',
                              'mode_values' => { 'sandbox' => false }, 'constraints' => { 'direction' => 'outgoing' })
    adapter.configure_paygen(credentials: { callback_secret: 'active-secret' }, transport: transport, account: 'acct-1')
    expect(deliver(callback(extra: { 'account' => 'acct-2', 'livemode' => false })).dig('error', 'code')).to eq('account_mismatch')
    expect(deliver(callback(extra: { 'account' => 'acct-1', 'livemode' => true })).dig('error', 'code')).to eq('mode_mismatch')
    expect(deliver(callback(extra: { 'account' => 'acct-1', 'livemode' => false, 'direction' => 'incoming' })).dig('error', 'code')).to eq('callback_scope_mismatch')
    config['callback'].delete('account_field')
    config['callback'].delete('mode_field')
    config['callback'].delete('constraints')
    expect(deliver(callback(extra: { 'event' => 'payout.failed' })).dig('error', 'code')).to eq('event_status_mismatch')
  end

  it 'verifies timestamped multi-signature callbacks and rejects expired timestamps' do
    config['callback']['signature'].merge!('algorithm' => 'stripe-v1')
    payload, raw, = callback
    timestamp = 1_800_000_000
    signature = OpenSSL::HMAC.hexdigest('SHA256', 'active-secret', "#{timestamp}.#{raw}")
    headers = { 'X-Signature' => "t=#{timestamp},v1=old,v1=#{signature}" }
    expect(adapter.process_callback(payload, raw_body: raw, headers: headers)['success']).to be(true)
    headers['X-Signature'] = "t=#{timestamp - 301},v1=#{signature}"
    expect(adapter.process_callback(payload, raw_body: raw, headers: headers).dig('error', 'code')).to eq('invalid_signature')
  end

  it 'decodes hex HMAC keys and base64 signatures' do
    config['callback']['signature'].merge!('encoding' => 'base64', 'key_encoding' => 'hex')
    adapter.configure_paygen(credentials: { callback_secret: '616263' }, transport: transport)
    payload, raw, = callback
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', 'abc', raw))
    expect(adapter.process_callback(payload, raw_body: raw, headers: { 'X-Signature' => signature })['success']).to be(true)
  end

  it 'normalizes OAS 3.0 nullable schema fields without dropping a property named nullable' do
    config['endpoints']['callback']['request_schema'] = {
      'type' => 'object', 'properties' => { 'failure_code' => { 'type' => 'string', 'nullable' => true },
                                           'nullable' => { 'type' => 'integer' } }
    }
    expect(deliver(callback(extra: { 'failure_code' => nil, 'nullable' => 1 }))['success']).to be(true)
    expect(deliver(callback(event_id: 'bad-field', extra: { 'failure_code' => nil, 'nullable' => 'invalid' })).dig('error', 'code')).to eq('invalid_callback')
    config['openapi'] = '3.1.0'
    expect(deliver(callback(event_id: 'oas31', extra: { 'failure_code' => nil })).dig('error', 'code')).to eq('invalid_callback')
  end

  it 'enforces boolean OAS 3.0 exclusive amount bounds' do
    config['endpoints']['create']['request_schema']['properties']['amount']['exclusiveMinimum'] = true
    expect(adapter.check_conditions(operation.merge('amount' => '1000'))['success']).to be(false)
    expect(adapter.check_conditions(operation.merge('amount' => '1000.01'))['success']).to be(true)
  end

  it 'requires an explicit verifier hook for provider verification callbacks' do
    config['callback']['signature'] = { 'algorithm' => 'provider_verification' }
    expect(deliver(callback).dig('error', 'code')).to eq('invalid_signature')
    adapter.define_singleton_method(:paygen_verify_callback) { |_payload, raw_body:, headers:| raw_body.include?('p-1') && headers.key?('x-signature') }
    expect(deliver(callback)['success']).to be(true)
  end

  it 'maps nested array requests to fixed-precision decimal strings and supports form encoding' do
    config['request_mapping'] = { 'items.0.amount' => { 'from' => 'amount', 'transform' => 'decimal_string' } }
    config['endpoints']['create'].delete('request_schema')
    config['request_encoding'] = 'form'
    expect(transport).to receive(:request) do |**request|
      expect(URI.decode_www_form(request[:body])).to eq([['items[0][amount]', '15000.01']])
      expect(request[:headers]['Content-Type']).to eq('application/x-www-form-urlencoded')
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    expect(adapter.create_request(operation)['success']).to be(true)
  end

  it 'supports bearer, basic and delegated OAuth tokens and account headers without leaking them' do
    config['auth'] = { 'type' => 'oauth2', 'scopes' => ['payouts'], 'headers' => { 'Account' => { 'credential' => 'account' }, 'Version' => { 'value' => 'v1' } } }
    token_provider = ->(scopes:, account:) { expect(scopes).to eq(['payouts']); expect(account).to eq('acct-1'); 'oauth-token' }
    adapter.configure_paygen(credentials: {}, transport: transport, account: 'acct-1', token_provider: token_provider)
    expect(transport).to receive(:request) do |**request|
      expect(request[:headers]).to include('Authorization' => 'Bearer oauth-token', 'Account' => 'acct-1', 'Version' => 'v1')
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    expect(adapter.create_request(operation)['success']).to be(true)
  end

  it 'sends Basic authentication and query API keys through their configured locations' do
    config['auth'] = { 'type' => 'basic' }
    adapter.configure_paygen(credentials: { username: 'merchant', password: 'private-password' }, transport: transport)
    expect(transport).to receive(:request) do |**request|
      expect(request[:headers]['Authorization']).to eq("Basic #{Base64.strict_encode64('merchant:private-password')}")
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    expect(adapter.create_request(operation)['success']).to be(true)
    config['auth'] = { 'type' => 'apiKey', 'in' => 'query', 'name' => 'key', 'credential' => 'api_key' }
    adapter.configure_paygen(credentials: { api_key: 'a+secret/key' }, transport: transport)
    expect(transport).to receive(:request) do |**request|
      expect(URI.decode_www_form(URI.parse(request[:url]).query)).to eq([['key', 'a+secret/key']])
      expect(request[:headers]).not_to have_key('Authorization')
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    expect(adapter.create_request(operation)['success']).to be(true)
  end

  it 'rejects HTTP, userinfo, header injection and hook origin changes' do
    adapter.configure_paygen(credentials: { api_key: 'key' }, transport: transport, base_url: 'http://api.example.test')
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('security_denial')
    adapter.configure_paygen(credentials: { api_key: "key\r\nInjected: bad" }, transport: transport)
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('security_denial')
    adapter.configure_paygen(credentials: { api_key: 'key' }, transport: transport)
    adapter.define_singleton_method(:paygen_request) { |request, _role, _op| request.merge(url: 'https://evil.example/pay') }
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('security_denial')
  end

  it 'binds requests and post-hook origin checks to the selected operation server' do
    config['endpoints']['status']['servers'] = [{ 'url' => 'https://status.example.org/v2' }]
    expect(transport).to receive(:request) do |**request|
      expect(request[:url]).to eq('https://status.example.org/v2/payouts/p-1')
      response({ 'id' => 'p-1', 'status' => 'paid' })
    end
    expect(adapter.fetch_status('provider_id' => 'p-1')['success']).to be(true)
    adapter.define_singleton_method(:paygen_request) do |request, _role, _operation|
      request.merge(url: 'https://api.example.test/v1/payouts/p-1')
    end
    expect(adapter.fetch_status('provider_id' => 'p-1').dig('error', 'code')).to eq('security_denial')
  end

  it 'uses a trusted explicit base URL override for every operation role' do
    config['endpoints']['status']['servers'] = [{ 'url' => 'https://status.example.org/v2' }]
    adapter.configure_paygen(credentials: { api_key: 'key' }, transport: transport, base_url: 'https://mock.example.org/v3')
    requests = []
    allow(transport).to receive(:request) do |**request|
      requests << request[:url]
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    expect(adapter.create_request(operation)['success']).to be(true)
    expect(adapter.fetch_status('provider_id' => 'p-1')['success']).to be(true)
    expect(requests).to eq(['https://mock.example.org/v3/payouts', 'https://mock.example.org/v3/payouts/p-1'])
  end

  it 'selects the requested mode from server descriptions or explicit mode fields' do
    config['mode'] = 'production'
    config['servers'] = [{ 'url' => 'https://sandbox.example.org/v1', 'description' => 'Sandbox' },
                         { 'url' => 'https://payments.example.org/v1', 'description' => 'Production' }]
    config['endpoints']['status']['servers'] = [
      { 'url' => 'https://status-sandbox.example.org/v2', 'mode' => 'sandbox' },
      { 'url' => 'https://status.example.org/v2', 'mode' => 'production' }
    ]
    adapter.configure_paygen(credentials: { api_key: 'key' }, transport: transport, mode: 'production')
    requests = []
    allow(transport).to receive(:request) do |**request|
      requests << request[:url]
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    expect(adapter.create_request(operation)['success']).to be(true)
    expect(adapter.fetch_status('provider_id' => 'p-1')['success']).to be(true)
    expect(requests).to eq(['https://payments.example.org/v1/payouts', 'https://status.example.org/v2/payouts/p-1'])
  end

  it 'expands server variable defaults before mode inference and operation origin checks' do
    config['servers'] = %w[production sandbox].map do |environment|
      { 'url' => 'https://{environment}.example.org/{version}',
        'variables' => { 'environment' => { 'default' => environment }, 'version' => { 'default' => 'v1' } } }
    end
    config['endpoints']['status']['servers'] = [{
      'url' => 'https://status-{environment}.example.org:{port}/{version}',
      'variables' => { 'environment' => { 'default' => 'sandbox' }, 'port' => { 'default' => '8443' },
                       'version' => { 'default' => 'v2' } }
    }]
    requests = []
    allow(transport).to receive(:request) do |**request|
      requests << request[:url]
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    expect(adapter.create_request(operation)['success']).to be(true)
    expect(adapter.fetch_status('provider_id' => 'p-1')['success']).to be(true)
    expect(requests).to eq(['https://sandbox.example.org/v1/payouts',
                            'https://status-sandbox.example.org:8443/v2/payouts/p-1'])
    adapter.define_singleton_method(:paygen_request) do |request, _role, _operation|
      request.merge(url: 'https://sandbox.example.org/v1/payouts/p-1')
    end
    expect(adapter.fetch_status('provider_id' => 'p-1').dig('error', 'code')).to eq('security_denial')
  end

  it 'rejects missing server defaults and unsafe expanded URLs before sending' do
    config['servers'] = [{ 'url' => 'https://{host}/v1', 'variables' => { 'host' => {} } }]
    expect(transport).not_to receive(:request)
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('configuration_error')
    config['servers'].first['variables']['host']['default'] = 'user:secret@example.org'
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('security_denial')
  end

  it 'fails closed when production is requested but only sandbox is configured' do
    config['mode'] = 'production'
    config['servers'] = [{ 'url' => 'https://api.example.org/v1', 'description' => 'Sandbox' }]
    adapter.configure_paygen(credentials: { api_key: 'key' }, transport: transport, mode: 'production')
    expect(transport).not_to receive(:request)
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('configuration_error')
    config['servers'] = ['https://sandbox.example.org/v1']
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('configuration_error')
  end

  it 'redacts secret fields and PAN-shaped strings in structured error output' do
    allow(transport).to receive(:request).and_return(response({ 'error' => { 'code' => 'private-api-value 4111111111111111' } }, status: 400))
    result = adapter.create_request(operation)
    expect(JSON.generate(result)).not_to include('private-api-value', '4111111111111111')
  end

  it 'preserves exact minor units over boundaries and seeded shrinking property cases' do
    config['amount']['minimum'] = 1
    config['endpoints']['create'].delete('request_schema')
    random = Random.new(7)
    observed = []
    allow(transport).to receive(:request) do |**request|
      observed << JSON.parse(request[:body])['amount']
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    minor_values = [1, 99, 100, 101, (2**53) + 1]
    config['amount']['maximum'] = 10**20
    minor_values.each_with_index do |minor, index|
      major = "#{minor / 100}.#{(minor % 100).to_s.rjust(2, '0')}"
      expect(adapter.create_request(operation.merge('id' => "fuzz-#{index}", 'amount' => major))['success']).to be(true)
    end
    expect(observed).to eq(minor_values)
    amounts = PropCheck::Generators.choose(1..(10**12))
    seeded = PropCheck::Generator.new { |**args| amounts.generate(**args.merge(rng: random)) }
    PropCheck.forall(seeded).with_config(n_runs: 100, max_shrink_steps: 100).check do |minor|
      major = "#{minor / 100}.#{(minor % 100).to_s.rjust(2, '0')}"
      expect(adapter.create_request(operation.merge('id' => "property-#{minor}", 'amount' => major))['success']).to be(true)
      expect(observed.last).to eq(minor)
    end
  end

  it 'uses the PDF operation object provider_operation_id with legacy path mappings and missing response ids' do
    config['parameter_mapping'] = { 'status' => { 'payout_id' => 'provider_id' } }
    model = Struct.new(:provider_operation_id)
    object = model.new('pdf payment/42')
    expect(transport).to receive(:request).with(hash_including(url: 'https://api.example.test/v1/payouts/pdf%20payment%2F42'))
                                        .and_return(response({ 'status' => 'paid' }))
    expect(adapter.fetch_status(object)).to include('success' => true, 'status' => 'approved', 'provider_id' => object.provider_operation_id)
  end

  it 'preserves a native BaseService failed? result and its own failure helper before sending HTTP' do
    native_result = Struct.new(:http_status, :code) do
      def failed? = true
    end.new(:unprocessable_entity, 'backend_limit')
    base = Class.new(Provider::BaseService) do
      attr_reader :prechecks
      define_method(:check_conditions) do |object, role|
        @prechecks = [object, role]
        failure(:unprocessable_entity, 'backend_limit')
      end
      define_method(:failure) do |status, code|
        raise 'BaseService result contract was changed' unless [status, code] == [:unprocessable_entity, 'backend_limit']

        native_result
      end
      private :failure
    end
    service = Class.new(base) { include Paygen::Runtime::Adapter }
    service.const_set(:PAYGEN_CONFIG, config)
    instance = service.new(transport: transport)
    expect(transport).not_to receive(:request)
    expect(instance.create_request(operation)).to equal(native_result)
    expect(instance.prechecks).to eq([operation, 'create'])
  end

  it 'preserves a failed hash precheck and continues after successful native backend prechecks' do
    base = Class.new(Provider::BaseService)
    base.define_method(:check_conditions) { |_object, _role| { success: false, reason: 'backend_guard' } }
    service = Class.new(base) { include Paygen::Runtime::Adapter }
    service.const_set(:PAYGEN_CONFIG, config)
    instance = service.new(transport: transport)
    expect(instance.create_request(operation)).to eq(success: false, reason: 'backend_guard')
    base.define_method(:check_conditions) { |_object, _role| Struct.new(:failed?).new(false) }
    expect(instance.check_conditions(operation)).to include('success' => true)
  end

  it 'applies the explicit backend callback seam only to verified accepted terminal events' do
    approvals, rejections = [], []
    adapter.define_singleton_method(:approve_operation) { |id| approvals << id }
    adapter.define_singleton_method(:reject_operation) { |id, code| rejections << [id, code] }
    adapter.singleton_class.send(:private, :approve_operation, :reject_operation)
    adapter.define_singleton_method(:paygen_callback_result) do |result, payload|
      paygen_backend_callback_result(result, payload)
    end
    expect(deliver(callback(status: 'pending', event_id: 'pending'))['status']).to eq('in_progress')
    message = callback(sequence: 2)
    expect(deliver(message)).to include('status' => 'approved', 'backend_applied' => true)
    expect(deliver(message)['ignored']).to eq('duplicate')
    expect(deliver(callback(status: 'pending', sequence: 1, event_id: 'old'))['ignored']).to eq('out_of_order')
    expect(deliver(callback(status: 'failed', sequence: 3, event_id: 'bad', secret: 'invalid')).dig('error', 'code')).to eq('invalid_signature')
    expect(deliver(callback(status: 'failed', sequence: 3, event_id: 'failed', extra: { 'error' => { 'code' => 'bank_declined' } })))
      .to include('status' => 'rejected', 'backend_applied' => true)
    expect(approvals).to eq(['p-1'])
    expect(rejections).to eq([['p-1', 'bank_declined']])
  end

  it 'does not mark a callback consumed when the backend rejects its state update' do
    failed = Struct.new(:failed?).new(true)
    calls = 0
    adapter.define_singleton_method(:approve_operation) { |_id| calls += 1; calls == 1 ? failed : nil }
    adapter.define_singleton_method(:paygen_callback_result) do |result, payload|
      paygen_backend_callback_result(result, payload)
    end
    message = callback
    expect(deliver(message)).to equal(failed)
    expect(deliver(message)).to include('backend_applied' => true)
    expect(deliver(message)['ignored']).to eq('duplicate')
    expect(calls).to eq(2)
  end

  it 'leaves backend transitions opt-in and fails explicitly when the opt-in contract is missing' do
    adapter.define_singleton_method(:approve_operation) { |_id| raise 'unrequested backend mutation' }
    expect(deliver(callback)['status']).to eq('approved')
    adapter.define_singleton_method(:paygen_callback_result) do |result, payload|
      paygen_backend_callback_result(result, payload)
    end
    expect(deliver(callback(status: 'failed', event_id: 'rejected')).dig('error', 'code')).to eq('backend_callback_not_configured')
  end

  it 'serializes mapped path, query and header parameters with their declared schemas' do
    config['endpoints']['status']['parameters'] = [
      { 'name' => 'payout_id', 'in' => 'path', 'required' => true, 'schema' => { 'type' => 'string' } },
      { 'name' => 'limit', 'in' => 'query', 'required' => true, 'schema' => { 'type' => 'integer', 'minimum' => 1 } },
      { 'name' => 'include', 'in' => 'query', 'schema' => { 'type' => 'array', 'items' => { 'type' => 'string' } } },
      { 'name' => 'states', 'in' => 'query', 'explode' => false, 'schema' => { 'type' => 'array' } },
      { 'name' => 'X-Request-ID', 'in' => 'header', 'required' => true, 'schema' => { 'type' => 'string' } },
      { 'name' => 'X-Fields', 'in' => 'header', 'schema' => { 'type' => 'array' } }
    ]
    config['parameter_mapping'] = {
      'status' => { 'path' => { 'payout_id' => 'provider_operation_id' },
                    'query' => { 'limit' => { 'value' => 2 }, 'include' => { 'value' => ['bank', 'recipient'] },
                                 'states' => { 'value' => ['paid', 'failed'] } },
                    'header' => { 'X-Request-ID' => 'id', 'X-Fields' => { 'value' => ['id', 'status'] } } }
    }
    expect(transport).to receive(:request) do |**request|
      expect(URI.decode_www_form(URI.parse(request[:url]).query)).to eq([['limit', '2'], ['include', 'bank'], ['include', 'recipient'], ['states', 'paid,failed']])
      expect(request[:headers]).to include('X-Request-ID' => 'op-123', 'X-Fields' => 'id,status')
      response({ 'id' => 'p-1', 'status' => 'paid' })
    end
    expect(adapter.fetch_status(operation.merge('provider_operation_id' => 'p-1'))['status']).to eq('approved')
  end

  it 'rejects missing and incorrectly typed request parameters without sending HTTP or disclosing values' do
    config['endpoints']['status']['parameters'] = [
      { 'name' => 'limit', 'in' => 'query', 'required' => true, 'schema' => { 'type' => 'integer', 'minimum' => 1 } }
    ]
    expect(transport).not_to receive(:request)
    expect(adapter.fetch_status('provider_id' => 'p-1').dig('error', 'reason')).to eq('missing query parameter limit')
    invalid = adapter.fetch_status('provider_id' => 'p-1', 'limit' => 'private-api-value')
    expect(invalid.dig('error', 'code')).to eq('validation_error')
    expect(invalid.dig('error', 'reason')).to eq('invalid query parameter limit: integer')
    expect(JSON.generate(invalid)).not_to include('private-api-value')
  end

  it 'checks required automatically supplied authentication and idempotency parameters' do
    config['endpoints']['create']['parameters'] = [
      { 'name' => 'X-API-Key', 'in' => 'header', 'required' => true, 'schema' => { 'type' => 'string' } },
      { 'name' => 'Idempotency-Key', 'in' => 'header', 'required' => true, 'schema' => { 'type' => 'string', 'format' => 'uuid' } }
    ]
    allow(transport).to receive(:request).and_return(response({ 'id' => 'p-1', 'status' => 'pending' }))
    expect(adapter.create_request(operation)['success']).to be(true)
    config['auth'] = { 'type' => 'apiKey', 'in' => 'query', 'name' => 'access_key', 'credential' => 'api_key' }
    config['endpoints']['status']['parameters'] = [
      { 'name' => 'access_key', 'in' => 'query', 'required' => true, 'schema' => { 'type' => 'string' } }
    ]
    expect(adapter.fetch_status('provider_id' => 'p-1')['success']).to be(true)
  end

  it 'supports credential parameters without allowing them to replace authentication or idempotency' do
    config['endpoints']['status']['parameters'] = [
      { 'name' => 'X-Partner', 'in' => 'header', 'required' => true, 'schema' => { 'type' => 'string' } }
    ]
    config['parameter_mapping'] = { 'status' => { 'header' => { 'X-Partner' => { 'credential' => 'api_key' } } } }
    expect(transport).to receive(:request).with(hash_including(headers: hash_including('X-Partner' => 'private-api-value')))
                                        .and_return(response({ 'id' => 'p-1', 'status' => 'pending', 'echo' => 'private-api-value' }))
    expect(adapter.fetch_status('provider_id' => 'p-1').dig('data', 'echo')).to eq('[REDACTED]')
    config['endpoints']['status']['parameters'][0]['name'] = 'x-api-key'
    config['parameter_mapping']['status']['header'] = { 'x-api-key' => { 'value' => 'spoofed' } }
    expect(adapter.fetch_status('provider_id' => 'p-1').dig('error', 'code')).to eq('configuration_error')
  end

  it 'rejects unsupported cookie, object, content and non-form query serialization explicitly' do
    definitions = [
      { 'name' => 'session', 'in' => 'cookie' },
      { 'name' => 'filter', 'in' => 'query', 'style' => 'deepObject' },
      { 'name' => 'filter', 'in' => 'query', 'content' => { 'application/json' => { 'schema' => {} } } },
      { 'name' => 'filter', 'in' => 'query', 'allowReserved' => true },
      { 'name' => 'filter', 'in' => 'query', 'schema' => { 'type' => 'object' } }
    ]
    expect(transport).not_to receive(:request)
    definitions.each do |definition|
      config['endpoints']['status']['parameters'] = [definition]
      result = adapter.fetch_status('provider_id' => 'p-1', 'filter' => { 'status' => 'paid' })
      expect(result.dig('error', 'code')).to eq('configuration_error')
      expect(result.dig('error', 'reason')).to include('unsupported')
    end
  end

  it 'includes semantically relevant query and header parameters in create idempotency conflicts' do
    config['endpoints']['create']['parameters'] = [
      { 'name' => 'route', 'in' => 'query', 'schema' => { 'type' => 'string' } },
      { 'name' => 'X-Account', 'in' => 'header', 'schema' => { 'type' => 'string' } }
    ]
    allow(transport).to receive(:request).and_return(response({ 'id' => 'p-1', 'status' => 'pending' }))
    original = operation.merge('route' => 'bank-a', 'X-Account' => 'a')
    expect(adapter.create_request(original)['success']).to be(true)
    expect(adapter.create_request(original.merge('route' => 'bank-b')).dig('error', 'code')).to eq('idempotency_conflict')
    expect(adapter.create_request(original.merge('X-Account' => 'b')).dig('error', 'code')).to eq('idempotency_conflict')
    expect(transport).to have_received(:request).once
  end

  it 'emits exact decimal JSON numbers without Float conversion and rejects unsupported input precision' do
    config['request_mapping']['amount']['transform'] = 'decimal_number'
    config['endpoints']['create']['request_schema']['properties']['amount'] = { 'type' => 'number', 'minimum' => 1000 }
    expect(transport).to receive(:request) do |**request|
      expect(request[:body]).to include('"amount":9999999999999.99')
      expect(JSON.parse(request[:body], decimal_class: BigDecimal)['amount']).to eq(BigDecimal('9999999999999.99'))
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    expect(adapter.create_request(operation.merge('amount' => '9999999999999.99'))['success']).to be(true)
    expect(adapter.create_request(operation.merge('amount' => 1234.56)).dig('error', 'code')).to eq('validation_error')
    expect(adapter.create_request(operation.merge('amount' => '1234.567')).dig('error', 'code')).to eq('validation_error')
  end

  it 'preserves a declared UTF-8 Content-Type and rejects a charset the encoder does not produce' do
    config['endpoints']['create']['parameters'] = [
      { 'name' => 'Content-Type', 'in' => 'header', 'schema' => { 'enum' => ['application/json; charset=UTF-8', 'application/json; charset=CP866'] } }
    ]
    config['parameter_mapping'] = { 'create' => { 'header' => { 'Content-Type' => { 'value' => 'application/json; charset=UTF-8' } } } }
    expect(transport).to receive(:request).with(hash_including(headers: hash_including('Content-Type' => 'application/json; charset=UTF-8')))
                                        .and_return(response({ 'id' => 'p-1', 'status' => 'pending' }))
    expect(adapter.create_request(operation)['success']).to be(true)
    config['parameter_mapping']['create']['header']['Content-Type']['value'] = 'application/json; charset=CP866'
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('configuration_error')
  end

  it 'omits an explicitly null idempotency header for body-based provider identities' do
    config['idempotency'] = { 'header' => nil, 'from' => 'id' }
    expect(transport).to receive(:request) do |**request|
      expect(request[:headers].keys).not_to include(nil, 'Idempotency-Key')
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    expect(adapter.create_request(operation)['success']).to be(true)
  end

  it 'does not redispatch strict-policy creates after ambiguous timeouts and uses positive status evidence' do
    config['idempotency'] = { 'strategy' => 'reconcile_before_retry', 'header' => nil, 'from' => 'id' }
    requests = []
    allow(transport).to receive(:request) do |**request|
      requests << request
      raise Timeout::Error if request[:method] == 'POST'

      response({ 'id' => 'p-1', 'status' => 'paid' })
    end
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('transport_timeout')
    expect(adapter.create_request(operation).dig('error')).to include('code' => 'reconciliation_required', 'ambiguous' => true, 'retryable' => false)
    expect(requests.length).to eq(1)
    expect(adapter.fetch_status(operation.merge('provider_operation_id' => 'p-1'))['status']).to eq('approved')
    expect(adapter.create_request(operation)).to include('success' => true, 'status' => 'approved', 'duplicate' => true)
    expect(adapter.create_request(operation.merge('amount' => '15000.02')).dig('error', 'code')).to eq('idempotency_conflict')
    expect(requests.map { |request| request[:method] }).to eq(%w[POST GET])
  end

  it 'caches successful strict-policy creates without assuming the provider deduplicates requests' do
    config['idempotency'] = { 'strategy' => 'reconcile_before_retry', 'header' => nil, 'from' => 'id' }
    expect(transport).to receive(:request).once.and_return(response({ 'id' => 'p-1', 'status' => 'pending' }))
    result = adapter.create_request(operation)
    result['provider_id'] = 'caller-mutated'
    expect(adapter.create_request(operation)).to include('provider_id' => 'p-1', 'duplicate' => true)
  end

  it 'retains strict create reservations across adapters sharing a state store and does not unlock on 404' do
    config['idempotency'] = { 'strategy' => 'reconcile_before_retry', 'header' => nil, 'from' => 'id' }
    store = Paygen::Runtime::MemoryStateStore.new
    adapter.configure_paygen(credentials: { api_key: 'key' }, transport: transport, state_store: store,
                             integration_namespace: 'merchant-a')
    expect(transport).to receive(:request).once.and_return(response({}, status: 429, headers: { 'Retry-After' => '1' }))
    expect(adapter.create_request(operation).dig('error')).to include('retryable' => false, 'action' => 'reconcile_before_retry')
    another = adapter.class.new(credentials: { api_key: 'new-key' }, transport: transport, state_store: store,
                                integration_namespace: 'merchant-a')
    expect(another.create_request(operation).dig('error', 'code')).to eq('reconciliation_required')
    expect(transport).to receive(:request).once.and_return(response({}, status: 404))
    expect(another.fetch_status(operation.merge('provider_operation_id' => 'p-1')).dig('error', 'code')).to eq('not_found')
    expect(another.create_request(operation).dig('error', 'code')).to eq('reconciliation_required')
  end


  it 'fails before dispatch when an external store has no stable integration identity' do
    store = Paygen::Runtime::MemoryStateStore.new
    adapter.configure_paygen(credentials: { api_key: 'key' }, transport: transport, state_store: store)
    expect(transport).not_to receive(:request)
    expect(adapter.create_request(operation).dig('error', 'reason')).to include('integration_namespace')
  end

  it 'isolates identical merchant operation IDs by explicit integration namespace' do
    store = Paygen::Runtime::MemoryStateStore.new
    expect(transport).to receive(:request).twice.and_return(
      response({ 'id' => 'provider-a', 'status' => 'pending' }),
      response({ 'id' => 'provider-b', 'status' => 'pending' })
    )
    first = adapter.class.new(credentials: { api_key: 'key-a' }, transport: transport, state_store: store,
                              integration_namespace: 'integration-a')
    second = adapter.class.new(credentials: { api_key: 'key-b' }, transport: transport, state_store: store,
                               integration_namespace: 'integration-b')
    expect(first.create_request(operation)['provider_id']).to eq('provider-a')
    expect(second.create_request(operation)['provider_id']).to eq('provider-b')
  end

  it 'preserves BigDecimal result values across the success cache round trip' do
    config['response']['amount'] = 'amount'
    expect(transport).to receive(:request).once.and_return(
      { status: 200, headers: {}, body: '{"id":"p-1","status":"pending","amount":12.34}' }
    )
    first = adapter.create_request(operation)
    cached = adapter.create_request(operation)
    expect(cached.dig('data', 'amount')).to be_a(BigDecimal)
    expect(cached.dig('data', 'amount')).to eq(first.dig('data', 'amount'))
  end

  it 'applies distinct nonterminal callbacks even when both map to in_progress' do
    config['callback']['events']['payout.processing'] = 'processing'
    applied = []
    adapter.define_singleton_method(:paygen_callback_result) do |result, payload|
      applied << payload['event']
      result
    end
    expect(deliver(callback(status: 'pending', sequence: 1, event_id: 'pending-1'))['status']).to eq('in_progress')
    expect(deliver(callback(status: 'processing', sequence: 2, event_id: 'processing-2'))['status']).to eq('in_progress')
    expect(applied).to eq(%w[payout.pending payout.processing])
  end

  it 'selects exactly one declarative recipient variant' do
    config['request_mapping'].delete('recipient.phone')
    config['request_mapping'].delete('recipient.bank_code')
    config['request_variants'] = {
      'create' => [
        { 'when_present' => 'payout_requisite.sbp', 'mapping' => {
          'recipient.type' => { 'value' => 'sbp' }, 'recipient.phone' => { 'from' => 'payout_requisite.sbp.phone' },
          'recipient.bank_code' => { 'from' => 'payout_requisite.sbp.bank_code' }
        } },
        { 'when_present' => 'payout_requisite.card', 'mapping' => {
          'recipient.type' => { 'value' => 'card' }, 'recipient.phone' => { 'from' => 'payout_requisite.card.phone' },
          'recipient.card_number' => { 'from' => 'payout_requisite.card.card_number' }
        } }
      ]
    }
    config['endpoints']['create'].delete('request_schema')
    expect(transport).to receive(:request) do |**request|
      expect(JSON.parse(request[:body])['recipient']).to eq(
        'type' => 'card', 'phone' => '79001234567', 'card_number' => '4111111111111111'
      )
      response({ 'id' => 'p-card', 'status' => 'pending' })
    end
    card = operation.merge('payout_requisite' => { 'card' => {
      'phone' => '79001234567', 'card_number' => '4111111111111111'
    } })
    expect(adapter.create_request(card)['success']).to be(true)
  end

  it 'preserves false values in explicit boolean parameter mappings' do
    config['endpoints']['status']['parameters'] = [
      { 'name' => 'expanded', 'in' => 'query', 'required' => true, 'schema' => { 'type' => 'boolean' } }
    ]
    config['parameter_mapping'] = { 'status' => { 'query' => { 'expanded' => 'expand_response' } } }
    expect(transport).to receive(:request).with(hash_including(url: 'https://api.example.test/v1/payouts/p-1?expanded=false'))
                                        .and_return(response({ 'id' => 'p-1', 'status' => 'pending' }))
    expect(adapter.fetch_status('provider_id' => 'p-1', 'expand_response' => false)['success']).to be(true)
  end

  it 'binds status and cancel response identities to the requested backend operation' do
    allow(transport).to receive(:request).and_return(response({ 'id' => 'different-payout', 'status' => 'paid' }))
    object = Struct.new(:provider_operation_id).new('requested-payout')
    expect(adapter.fetch_status(object).dig('error', 'code')).to eq('provider_id_mismatch')
    expect(adapter.cancel(object).dig('error', 'code')).to eq('provider_id_mismatch')
    expect(adapter.create_request(operation)['success']).to be(true)
  end

  it 'prevents a known strict-policy merchant identity from being rebound to another provider operation' do
    config['idempotency'] = { 'strategy' => 'reconcile_before_retry', 'header' => nil, 'from' => 'id' }
    expect(transport).to receive(:request).once.and_return(response({ 'id' => 'original-payout', 'status' => 'pending' }))
    expect(adapter.create_request(operation)['provider_id']).to eq('original-payout')
    expect(adapter.fetch_status(operation.merge('provider_operation_id' => 'another-payout')).dig('error', 'code')).to eq('operation_identity_mismatch')
    expect(adapter.cancel(operation.merge('provider_operation_id' => 'another-payout')).dig('error', 'code')).to eq('operation_identity_mismatch')
    expect(adapter.create_request(operation)).to include('provider_id' => 'original-payout', 'status' => 'in_progress', 'duplicate' => true)
  end

  it 'rejects case-insensitive duplicate headers and transport routing headers before dispatch' do
    expect(transport).not_to receive(:request)
    config['endpoints']['create']['parameters'] = [
      { 'name' => 'X-Route', 'in' => 'header' }, { 'name' => 'x-route', 'in' => 'header' }
    ]
    expect(adapter.create_request(operation.merge('X-Route' => 'bank-a', 'x-route' => 'bank-b')).dig('error', 'reason'))
      .to include('duplicate case-insensitive header')
    config['endpoints']['create']['parameters'] = [{ 'name' => 'Host', 'in' => 'header' }]
    expect(adapter.create_request(operation.merge('Host' => 'another-origin.test')).dig('error', 'reason')).to include('transport-controlled')
  end

  it 'rejects transport header overrides or duplicate headers introduced by request hooks' do
    expect(transport).not_to receive(:request)
    adapter.define_singleton_method(:paygen_request) do |request, _role, _operation|
      request.merge(headers: request.fetch(:headers).merge('Host' => 'another-origin.test'))
    end
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('security_denial')
    adapter.define_singleton_method(:paygen_request) do |request, _role, _operation|
      request.merge(headers: request.fetch(:headers).merge('X-Route' => 'a', 'x-route' => 'b'))
    end
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('security_denial')
  end
end
