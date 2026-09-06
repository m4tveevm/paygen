# frozen_string_literal: true
require 'spec_helper'
require 'paygen/runtime/adapter'
require_relative 'support/provider_harness'

RSpec.describe Paygen::Core::IR do
  let(:document) do
    { 'openapi' => '3.1.0', 'info' => { 'title' => 'OAuth Payout', 'version' => '1' },
      'servers' => [{ 'url' => 'https://api.example.test' }],
      'security' => [{ 'OAuth' => ['payouts:write'] }],
      'components' => { 'securitySchemes' => { 'OAuth' => { 'type' => 'oauth2', 'flows' => {
        'clientCredentials' => { 'tokenUrl' => 'https://api.example.test/token',
                                 'scopes' => { 'payouts:write' => 'Create', 'payouts:read' => 'Read' } }
      } } } },
      'paths' => {
        '/payouts' => { 'post' => { 'operationId' => 'createPayout', 'responses' => {} } },
        '/payouts/{id}' => { 'get' => { 'operationId' => 'getPayout', 'responses' => {},
                                       'security' => [{ 'OAuth' => ['payouts:read'] }] } }
      } }
  end
  let(:profile) do
    { 'operations' => { 'create' => 'createPayout', 'status' => 'getPayout' },
      'auth' => { 'type' => 'oauth2', 'credential' => 'access_token', 'scopes' => %w[payouts:read payouts:write] },
      'request_mapping' => { 'amount' => { 'from' => 'amount', 'transform' => 'minor_units' } },
      'status_mapping' => { 'pending' => 'in_progress' },
      'amount' => { 'scale' => 100, 'currencies' => ['USD'] }, 'idempotency' => {} }
  end
  def ir = described_class.new(document, profile: profile)

  it 'requires explicit roles, required evidence and amount units for response bindings' do
    base = { 'response_path' => 'data.amount', 'operation_path' => 'amount',
             'roles' => %w[create status], 'required' => true, 'response_unit' => 'minor' }
    profile['response_bindings'] = { 'amount' => base }
    expect(ir.diagnostics).to be_empty
    [base.reject { |key, _| key == 'response_unit' }, base.merge('roles' => ['callback']),
     base.merge('roles' => []), base.merge('required' => 'yes'), base.merge('response_unit' => 'cents'),
     base.merge('response_path' => ''), base.merge('eval' => 'arbitrary code')].each do |rule|
      profile['response_bindings'] = { 'amount' => rule }
      expect(ir.diagnostics.map { |diagnostic| diagnostic['code'] }).to include('INVALID_RESPONSE_BINDING')
    end
    profile['response_bindings'] = { 'guessed_field' => base }
    expect(ir.diagnostics.map { |diagnostic| diagnostic['code'] }).to include('INVALID_RESPONSE_BINDING')
  end

  it 'accepts bounded conditional mapping with explicit default and ordered field fallbacks' do
    profile['request_mapping']['route'] = {
      'from' => 'route', 'fallback_from' => ['legacy.route'], 'default' => false,
      'when' => { 'from' => 'kind', 'equals' => 'transfer', 'default' => 'transfer' }
    }
    expect(ir.diagnostics).to be_empty
    expect(ir.config.dig('request_mapping', 'route')).to eq(profile.dig('request_mapping', 'route'))
  end

  it 'reports malformed conditional rules before generation instead of silently applying them' do
    malformed = [
      { 'from' => 'route', 'when' => 'kind == transfer' },
      { 'from' => 'route', 'when' => { 'from' => 'kind', 'equals' => ['transfer'] } },
      { 'from' => 'route', 'when' => { 'from' => 'kind' } },
      { 'from' => 'route', 'when' => { 'from' => '', 'equals' => 'transfer' } },
      { 'from' => 'route', 'when' => { 'from' => 'kind', 'equals' => 'transfer', 'eval' => 'true' } },
      { 'from' => 'route', 'fallback_from' => 'legacy.route' },
      { 'from' => 'route', 'fallback_from' => [nil] },
      { 'value' => 'fixed', 'default' => 'ignored' },
      { 'from' => 'route', 'unsupported_condition' => true }
    ]
    malformed.each do |rule|
      profile['request_mapping']['route'] = rule
      expect(ir.diagnostics.map { |diagnostic| diagnostic['code'] }).to include('INVALID_MAPPING')
    end
    profile['request_mapping'].delete('route')
    profile['request_mappings'] = { 'cancel' => { 'route' => malformed.first } }
    expect(ir.diagnostics.map { |diagnostic| diagnostic['code'] }).to include('INVALID_MAPPING')
  end

  it 'infers OAuth2 and the scopes required by selected outgoing operations' do
    profile.delete('auth')
    expect(ir.profile['auth']).to eq('type' => 'oauth2', 'credential' => 'access_token',
                                    'scopes' => %w[payouts:read payouts:write])
    expect(ir.diagnostics.map { |item| item['code'] }.uniq).to eq(['OPERATOR_REVIEW_REQUIRED'])
  end

  it 'sends the confirmed OAuth2 token and required scopes to the payout transport' do
    transport = double('transport')
    tokens = double('token provider')
    expect(tokens).to receive(:call).with(scopes: %w[payouts:read payouts:write], account: nil).and_return('test-access-token')
    expect(transport).to receive(:request).with(hash_including(headers: hash_including('Authorization' => 'Bearer test-access-token')))
                                        .and_return(status: 201, headers: {}, body: '{"id":"p-1","status":"pending"}')
    service = Class.new(Provider::BaseService) { include Paygen::Runtime::Adapter }
    service.const_set(:PAYGEN_CONFIG, ir.config)
    result = service.new(transport: transport, token_provider: tokens).create_request('id' => 'op-1', 'amount' => '10', 'currency' => 'USD')
    expect(result['success']).to be(true)
  end

  it 'infers scopes from final explicit operation selections across semantic layers' do
    document['paths']['/submit'] = { 'post' => { 'operationId' => 'submitPayment', 'responses' => {},
                                               'security' => [{ 'OAuth' => ['payouts:submit'] }] } }
    profile.delete('auth')
    profile['operations'].delete('create')
    selection = { 'operations' => { 'create' => 'submitPayment' } }
    [
      described_class.new(document.merge('x-paygen' => selection), profile: profile),
      described_class.new(document, recipe: selection, profile: profile),
      described_class.new(document, profile: profile.merge(selection)),
      described_class.new(document, profile: profile, overrides: selection)
    ].each do |selected|
      expect(selected.diagnostics.map { |item| item['code'] }.uniq).to eq(['OPERATOR_REVIEW_REQUIRED'])
      expect(selected.profile.dig('auth', 'scopes')).to eq(%w[payouts:read payouts:submit])
    end
    expect(ir.provenance.dig('auth.scopes', 'origin')).to eq('inference')
  end

  it 'fails before transport if the inferred OAuth2 credential is missing' do
    transport = double('transport')
    expect(transport).not_to receive(:request)
    service = Class.new(Provider::BaseService) { include Paygen::Runtime::Adapter }
    service.const_set(:PAYGEN_CONFIG, ir.config)
    result = service.new(transport: transport).create_request('id' => 'op-1', 'amount' => '10', 'currency' => 'USD')
    expect(result.dig('error', 'code')).to eq('configuration_error')
  end

  it 'requires explicit authentication when multiple schemes prevent inference' do
    profile.delete('auth')
    document['components']['securitySchemes']['Other'] = { 'type' => 'apiKey', 'in' => 'header', 'name' => 'X-Key' }
    expect(ir.diagnostics.map { |item| item['code'] }).to include('AUTH_REQUIRED')
    profile['auth'] = { 'type' => 'oauth2', 'credential' => 'access_token', 'scopes' => %w[payouts:read payouts:write] }
    expect(ir.diagnostics).to be_empty
  end

  it 'does not allow an explicit none profile to silently remove required authentication' do
    profile['auth'] = { 'type' => 'none' }
    expect(ir.diagnostics.map { |item| item['code'] }).to include('AUTH_REQUIRED')
  end

  it 'respects operation-level anonymous alternatives and security overrides' do
    document['paths']['/payouts']['post']['security'] = [{ 'OAuth' => [] }, {}]
    document['paths']['/payouts/{id}']['get']['security'] = []
    profile['auth'] = { 'type' => 'none' }
    expect(ir.diagnostics).to be_empty
  end

  it 'keeps callback authentication separate from outgoing authentication' do
    profile.delete('auth')
    document['paths']['/payouts']['post']['security'] = []
    document['paths']['/payouts/{id}']['get']['security'] = []
    document['paths']['/callback'] = { 'post' => { 'operationId' => 'payoutCallback', 'responses' => {} } }
    profile['callback'] = { 'signature' => { 'algorithm' => 'hmac-sha256' } }
    expect(ir.profile).not_to have_key('auth')
    expect(ir.diagnostics).to be_empty
  end

  it 'accepts empty idempotency as a conservative policy without inferring a provider header' do
    expect(ir.config.fetch('idempotency')).to eq({})
    expect(ir.diagnostics).to be_empty
  end

  it 'requires a declared provider identity before accepting a provider-key policy' do
    profile['idempotency'] = { 'strategy' => 'provider_key', 'ttl_seconds' => 60 }
    expect(ir.diagnostics.map { |item| item['code'] }).to include('IDEMPOTENCY_IDENTITY_REQUIRED')
    profile['idempotency']['body'] = 'reference'
    expect(ir.diagnostics).to be_empty
  end

  it 'rejects unknown strategies and non-positive or non-integer retention windows' do
    profile['idempotency'] = { 'strategy' => 'assume_supported' }
    expect(ir.diagnostics.map { |item| item['code'] }).to include('IDEMPOTENCY_STRATEGY_UNSUPPORTED')
    [0, -1, '60', 60.0, nil].each do |ttl|
      profile['idempotency'] = { 'header' => 'X-Request-Id', 'ttl_seconds' => ttl }
      expect(ir.diagnostics.map { |item| item['code'] }).to include('INVALID_IDEMPOTENCY_TTL')
    end
  end
end
