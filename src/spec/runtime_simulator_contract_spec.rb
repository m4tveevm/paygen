# frozen_string_literal: true

require 'spec_helper'
require 'rack/mock'
require 'paygen/runtime/simulator'

RSpec.describe Paygen::Runtime::Simulator, 'provider request contract' do
  let(:schema) do
    { 'type' => 'object', 'required' => %w[amount currency reference],
      'additionalProperties' => false,
      'properties' => { 'amount' => { 'type' => 'integer', 'minimum' => 1 },
                        'currency' => { 'type' => 'string', 'enum' => ['RUB'] },
                        'reference' => { 'type' => 'string', 'minLength' => 1 } } }
  end
  let(:configuration) do
    {
      'openapi' => '3.1.0', 'provider' => 'contract', 'idempotency' => {},
      'request_mapping' => { 'amount' => { 'from' => 'amount' }, 'currency' => { 'from' => 'currency' } },
      'status_mapping' => { 'pending' => 'in_progress', 'paid' => 'approved', 'cancelled' => 'rejected' },
      'endpoints' => {
        'create' => { 'method' => 'POST', 'path' => '/accounts/{account}/payouts',
                      'request_required' => true, 'request_schema' => schema,
                      'request_content' => { 'application/json' => { 'schema' => schema } },
                      'parameters' => [
                        { 'name' => 'account', 'in' => 'path', 'required' => true,
                          'schema' => { 'type' => 'integer', 'minimum' => 1 } },
                        { 'name' => 'urgent', 'in' => 'query', 'required' => true,
                          'schema' => { 'type' => 'boolean' } },
                        { 'name' => 'X-Revision', 'in' => 'header', 'required' => true,
                          'schema' => { 'type' => 'integer', 'enum' => [2] } }
                      ] },
        'cancel' => { 'method' => 'POST', 'path' => '/payouts/{id}/cancel',
                      'parameters' => [{ 'name' => 'id', 'in' => 'path', 'required' => true,
                                         'schema' => { 'type' => 'string', 'pattern' => '^sim_[a-z0-9]+$' } }],
                      'request_required' => true,
                      'request_content' => { 'application/json' => { 'schema' => {
                        'type' => 'object', 'required' => ['reason'],
                        'properties' => { 'reason' => { 'const' => 'requested' } }
                      } } } }
      }
    }
  end
  let(:simulator) { described_class.new(config: configuration) }
  let(:client) { Rack::MockRequest.new(simulator) }
  let(:body) { { 'amount' => 1050, 'currency' => 'RUB', 'reference' => 'merchant-1' } }
  let(:request) do
    { method: 'POST', url: '/accounts/1/payouts?urgent=false',
      headers: { 'Content-Type' => 'application/json; charset=UTF-8', 'X-Revision' => '2' },
      body: JSON.generate(body) }
  end

  it 'rejects an empty object through Rack without creating a payout' do
    result = client.post('/accounts/1/payouts?urgent=false',
                         'CONTENT_TYPE' => 'application/json', 'HTTP_X_REVISION' => '2', input: '{}')

    expect(result.status).to eq(400)
    expect(JSON.parse(result.body).dig('error', 'code')).to eq('invalid_request_body')
    expect(simulator.evidence['created_count']).to eq(0)
  end

  it 'checks required body presence independently of property requirements' do
    configuration['endpoints']['create']['request_content']['application/json']['schema'] = { 'type' => 'object' }
    result = simulator.request(**request.merge(body: nil))

    expect(result[:status]).to eq(400)
    expect(JSON.parse(result[:body]).dig('error', 'code')).to eq('missing_required_body')
    expect(simulator.evidence['created_count']).to eq(0)
  end

  it 'rejects invalid body fields and undeclared content types before mutation' do
    invalid = [body.merge('amount' => '1050'), body.merge('amount' => 0),
               body.merge('currency' => 'USD'), body.merge('extra' => true)]
    invalid.each do |payload|
      expect(simulator.request(**request.merge(body: JSON.generate(payload)))[:status]).to eq(400)
    end
    wrong_media = request.merge(headers: request[:headers].merge('Content-Type' => 'text/plain'))
    expect(simulator.request(**wrong_media)[:status]).to eq(415)
    expect(simulator.request(**request.merge(headers: { 'X-Revision' => '2' }))[:status]).to eq(415)
    expect(simulator.evidence['created_count']).to eq(0)
  end

  it 'checks path, query and case-insensitive header schemas on the wire' do
    invalid = [request.merge(url: '/accounts/invalid/payouts?urgent=false'),
               request.merge(url: '/accounts/0/payouts?urgent=false'),
               request.merge(url: '/accounts/1/payouts'),
               request.merge(url: '/accounts/1/payouts?urgent=perhaps'),
               request.merge(url: '/accounts/1/payouts?urgent=false&urgent=true'),
               request.merge(headers: { 'Content-Type' => 'application/json' }),
               request.merge(headers: request[:headers].merge('X-Revision' => '3')),
               request.merge(headers: request[:headers].merge('x-revision' => '2'))]
    invalid.each { |wire| expect(simulator.request(**wire)[:status]).to eq(400) }
    expect(simulator.evidence['created_count']).to eq(0)

    expect(simulator.request(**request.merge(headers: { 'content-type' => 'application/json', 'x-revision' => '2' }))[:status]).to eq(201)
    expect(simulator.evidence['created_count']).to eq(1)
  end

  it 'rejects invalid cancellation payloads without changing the existing payout' do
    created = JSON.parse(simulator.request(**request).fetch(:body))
    path = "/payouts/#{created.fetch('id')}/cancel"
    args = { method: 'POST', url: path, headers: { 'Content-Type' => 'application/json' } }

    expect(simulator.request(**args, body: '{}')[:status]).to eq(400)
    expect(simulator.request(**args, body: '{"reason":"invented"}')[:status]).to eq(400)
    expect(simulator.request(**args, body: '{"reason":"requested"}')[:status]).to eq(200)
    expect(simulator.evidence['created_count']).to eq(1)
  end

  it 'deserializes primitive arrays using declared form and simple parameter styles' do
    definitions = configuration['endpoints']['create']['parameters']
    definitions.concat([
      { 'name' => 'parts', 'in' => 'query', 'required' => true,
        'schema' => { 'type' => 'array', 'items' => { 'type' => 'integer' }, 'minItems' => 2 } },
      { 'name' => 'flags', 'in' => 'header', 'required' => true,
        'schema' => { 'type' => 'array', 'items' => { 'type' => 'boolean' } } }
    ])
    valid = request.merge(url: '/accounts/1/payouts?urgent=false&parts=1&parts=2',
                          headers: request[:headers].merge('flags' => 'true,false'))
    expect(simulator.request(**valid)[:status]).to eq(201)
    invalid = valid.merge(url: '/accounts/1/payouts?urgent=false&parts=1&parts=bad')
    expect(simulator.request(**invalid)[:status]).to eq(400)
    expect(simulator.evidence['created_count']).to eq(1)
  end

  it 'validates form integers after decoding while JSON strings remain strings' do
    configuration['endpoints']['create']['request_content']['application/x-www-form-urlencoded'] = { 'schema' => schema }
    wire = request.merge(headers: request[:headers].merge('Content-Type' => 'application/x-www-form-urlencoded'),
                         body: 'amount=1050&currency=RUB&reference=merchant-1')
    expect(simulator.request(**wire)[:status]).to eq(201)
    expect(simulator.request(**wire.merge(body: 'amount=invalid&currency=RUB&reference=merchant-2'))[:status]).to eq(400)
    expect(simulator.evidence['created_count']).to eq(1)
  end

  it 'rejects ambiguous and oversized form paths before allocation or mutation' do
    configuration['endpoints']['create']['request_content']['application/x-www-form-urlencoded'] = { 'schema' => schema }
    wire = request.merge(headers: request[:headers].merge('Content-Type' => 'application/x-www-form-urlencoded'))
    %w[amount=bad&amount=1050&currency=RUB&reference=merchant-1 amount=1050&amount[0]=1 items[999999999]=value].each do |payload|
      expect(simulator.request(**wire.merge(body: payload))[:status]).to eq(400)
    end
    expect(simulator.evidence['created_count']).to eq(0)
  end

  it 'validates an optional request body only when it is present' do
    configuration['endpoints']['cancel']['request_required'] = false
    created = JSON.parse(simulator.request(**request).fetch(:body))
    expect(simulator.request(method: 'POST', url: "/payouts/#{created.fetch('id')}/cancel")[:status]).to eq(200)
  end

  it 'respects the OpenAPI 3.0 nullable dialect without adapting the request mapping' do
    configuration['openapi'] = '3.0.3'
    schema['properties']['reference']['nullable'] = true
    valid = request.merge(body: JSON.generate(body.merge('reference' => nil)))
    expect(simulator.request(**valid)[:status]).to eq(201)

    configuration['openapi'] = '3.1.0'
    other = described_class.new(config: configuration)
    expect(other.request(**valid)[:status]).to eq(400)
    expect(other.evidence['created_count']).to eq(0)
  end

  it 'does not treat an unconfigured Idempotency-Key header as a provider guarantee' do
    uncertain = described_class.new(config: configuration, scenario: 'timeout_after_commit')
    wire = request.merge(headers: request[:headers].merge('Idempotency-Key' => 'client-assumption'))
    expect { uncertain.request(**wire) }.to raise_error(Timeout::Error)
    expect(uncertain.request(**wire)[:status]).to eq(201)
    expect(uncertain.evidence['created_count']).to eq(2)
  end
end
