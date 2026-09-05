# frozen_string_literal: true

require 'spec_helper'
require 'paygen/runtime/adapter'
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

  it 'marks timeout-after-commit as ambiguous and requires reconciliation without automatic retry' do
    allow(transport).to receive(:request).and_raise(Timeout::Error)
    result = adapter.create_request(operation)
    expect(result['error']).to include('code' => 'transport_timeout', 'ambiguous' => true,
                                       'retryable' => false, 'action' => 'reconcile_before_retry')
    expect(transport).to have_received(:request).once
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

  it 'rejects HTTP, userinfo, header injection and hook origin changes' do
    adapter.configure_paygen(credentials: { api_key: 'key' }, transport: transport, base_url: 'http://api.example.test')
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('security_denial')
    adapter.configure_paygen(credentials: { api_key: "key\r\nInjected: bad" }, transport: transport)
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('security_denial')
    adapter.configure_paygen(credentials: { api_key: 'key' }, transport: transport)
    adapter.define_singleton_method(:paygen_request) { |request, _role, _op| request.merge(url: 'https://evil.example/pay') }
    expect(adapter.create_request(operation).dig('error', 'code')).to eq('security_denial')
  end

  it 'redacts secret fields and PAN-shaped strings in structured error output' do
    allow(transport).to receive(:request).and_return(response({ 'error' => { 'code' => 'private-api-value 4111111111111111' } }, status: 400))
    result = adapter.create_request(operation)
    expect(JSON.generate(result)).not_to include('private-api-value', '4111111111111111')
  end

  it 'preserves decimal conversion over deterministic boundary fuzz cases' do
    config['amount']['minimum'] = 1
    config['endpoints']['create'].delete('request_schema')
    random = Random.new(7)
    observed = []
    allow(transport).to receive(:request) do |**request|
      observed << JSON.parse(request[:body])['amount']
      response({ 'id' => 'p-1', 'status' => 'pending' })
    end
    minor_values = [1, 99, 100, 101, 2**53 + 1] + Array.new(100) { random.rand(1..10**12) }
    config['amount']['maximum'] = 10**20
    minor_values.each_with_index do |minor, index|
      major = "#{minor / 100}.#{(minor % 100).to_s.rjust(2, '0')}"
      expect(adapter.create_request(operation.merge('id' => "fuzz-#{index}", 'amount' => major))['success']).to be(true)
    end
    expect(observed).to eq(minor_values)
  end
end
