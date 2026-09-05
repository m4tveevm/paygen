# frozen_string_literal: true

require 'spec_helper'
require 'rack/mock'
require 'paygen/runtime/simulator'
require 'paygen/runtime/verifier'

RSpec.describe Paygen::Runtime::Simulator do
  let(:configuration) do
    {
      'provider' => 'sample', 'mode' => 'sandbox',
      'servers' => ['https://simulator.example/v1'],
      'amount' => { 'scale' => 100, 'minimum' => 100, 'currencies' => ['USD'] },
      'auth' => { 'type' => 'apiKey', 'in' => 'header', 'name' => 'X-Key', 'credential' => 'api_key' },
      'idempotency' => { 'header' => 'Idempotency-Key' },
      'request_mapping' => { 'amount' => { 'from' => 'amount', 'transform' => 'minor_units' },
                             'currency' => { 'from' => 'currency' }, 'external_id' => { 'from' => 'id' } },
      'response' => { 'id' => 'id', 'status' => 'status' },
      'status_mapping' => { 'pending' => 'in_progress', 'paid' => 'approved',
                            'failed' => 'rejected', 'cancelled' => 'rejected' },
      'callback' => {
        'id' => 'payout_id', 'status' => 'status', 'event' => 'event',
        'event_id' => 'event_id', 'sequence' => 'sequence',
        'events' => { 'payment.pending' => 'pending', 'payment.paid' => 'paid' },
        'signature' => { 'algorithm' => 'hmac-sha256', 'header' => 'X-Signature', 'credential' => 'callback_secret' }
      },
      'endpoints' => {
        'create' => { 'method' => 'post', 'path' => '/payouts', 'responses' => { '201' => {} } },
        'status' => { 'method' => 'get', 'path' => '/payouts/{id}', 'responses' => { '200' => {} } },
        'cancel' => { 'method' => 'post', 'path' => '/payouts/{id}/cancel', 'responses' => { '200' => {} } },
        'balance' => { 'method' => 'get', 'path' => '/balance', 'responses' => { '200' => {} } },
        'callback' => { 'method' => 'post', 'path' => '/callback', 'request_schema' => {} }
      }
    }
  end

  def payout(simulator, key: 'operation-key', amount: 100)
    simulator.request(method: 'POST', url: 'https://simulator.example/v1/payouts',
                      headers: { 'Idempotency-Key' => key, 'Content-Type' => 'application/json' },
                      body: JSON.generate({ 'external_id' => key, 'amount' => amount, 'currency' => 'USD' }))
  end

  def status(simulator, id)
    simulator.request(method: 'GET', url: "https://simulator.example/v1/payouts/#{id}", headers: {}, body: nil)
  end

  def parsed(response)
    JSON.parse(response.fetch(:body))
  end

  it 'commits once for a stable key and rejects a changed body with the same key' do
    simulator = described_class.new(config: configuration, seed: 42)
    original = payout(simulator)
    expect(original[:status]).to eq(201)
    expect(parsed(payout(simulator))['id']).to eq(parsed(original)['id'])
    expect(payout(simulator, amount: 200)[:status]).to eq(409)
    expect(simulator.evidence['created_count']).to eq(1)
  end

  it 'raises an actual timeout after persisting the operation and returns it on retry' do
    simulator = described_class.new(config: configuration, scenario: 'timeout_after_commit')
    expect { payout(simulator) }.to raise_error(Timeout::Error)
    expect(simulator.evidence['created_count']).to eq(1)
    expect(payout(simulator)[:status]).to eq(201)
    expect(simulator.evidence['created_count']).to eq(1)
    expect(simulator.evidence['requests'].first['transport_timeout']).to be(true)
  end

  it 'returns 504 through Rack after a commit and accepts a safe retry' do
    simulator = described_class.new(config: configuration, scenario: 'timeout_after_commit')
    client = Rack::MockRequest.new(simulator)
    args = { 'HTTP_IDEMPOTENCY_KEY' => 'rack-operation', 'CONTENT_TYPE' => 'application/json',
             input: '{"amount":100,"currency":"USD"}' }
    expect(client.post('/v1/payouts', args).status).to eq(504)
    expect(client.post('/v1/payouts', args).status).to eq(201)
    expect(simulator.evidence['created_count']).to eq(1)
  end

  it 'has reproducible identifiers, state transitions, and signed event bytes' do
    first = described_class.new(config: configuration, seed: 55)
    second = described_class.new(config: configuration, seed: 55)
    a = payout(first)
    b = payout(second)
    expect(a).to eq(b)
    id = parsed(a).fetch('id')
    expect(parsed(status(first, id)).fetch('status')).to eq('paid')
    expect(status(second, id)).to eq(status(first, id))
    expect(first.callback_events).to eq(second.callback_events)
    events = first.callback_events(duplicate: true, out_of_order: true)
    expect(events.first['payload']['sequence']).to eq(2)
    expect(events[-1]).to eq(events[-2])
    events.each do |event|
      expected = OpenSSL::HMAC.hexdigest('SHA256', 'paygen-test-secret', event.fetch('raw_body'))
      expect(event['headers']['X-Signature']).to eq(expected)
    end
  end

  it 'rate limits one create attempt and records no payout for that rejected attempt' do
    simulator = described_class.new(config: configuration, scenario: 'rate_limit')
    limited = payout(simulator)
    expect(limited[:status]).to eq(429)
    expect(limited[:headers]['retry-after']).to eq('1')
    expect(simulator.evidence['created_count']).to eq(0)
    expect(payout(simulator)[:status]).to eq(201)
  end

  it 'uses a supported webhook event when an HTTP pending status has no webhook event' do
    configuration['status_mapping']['processing'] = 'in_progress'
    configuration['callback']['events'] = { 'payment.processing' => 'processing', 'payment.paid' => 'paid' }
    configuration['simulator'] = { 'scenarios' => { 'success' => { 'statuses' => %w[pending paid] } } }
    simulator = described_class.new(config: configuration)
    payout(simulator)
    event = simulator.callback_events.first.fetch('payload')
    expect(event['event']).to eq('payment.processing')
    expect(event['status']).to eq('processing')
  end

  it 'distinguishes an invalid cancellation conflict from idempotent create replay' do
    simulator = described_class.new(config: configuration)
    id = parsed(payout(simulator)).fetch('id')
    status(simulator, id)
    conflict = simulator.request(method: 'POST', url: "https://simulator.example/v1/payouts/#{id}/cancel")
    expect(conflict[:status]).to eq(409)
    expect(parsed(conflict)).to eq('error' => { 'code' => 'invalid_status', 'message' => 'invalid_status' })
  end

  it 'preserves a cancellation even when the operation is subsequently polled' do
    simulator = described_class.new(config: configuration)
    id = parsed(payout(simulator)).fetch('id')
    cancelled = simulator.request(method: 'POST', url: "https://simulator.example/v1/payouts/#{id}/cancel")
    expect(cancelled[:status]).to eq(200)
    expect(parsed(status(simulator, id))['status']).to eq(parsed(cancelled)['status'])
  end

  it 'serves paid then failed and explicit booked then returned without equating booked with paid' do
    configuration['status_mapping'].merge!('booked' => 'in_progress', 'returned' => 'rejected')
    configuration['simulator'] = { 'scenarios' => { 'booked_then_returned' => { 'statuses' => %w[booked returned] } } }
    %w[paid_then_failed booked_then_returned].each do |scenario|
      simulator = described_class.new(config: configuration, scenario: scenario)
      id = parsed(payout(simulator)).fetch('id')
      statuses = 2.times.map { parsed(status(simulator, id))['status'] }
      expect(statuses).to eq(scenario == 'paid_then_failed' ? %w[paid failed] : %w[booked returned])
    end
  end

  it 'applies response role mappings and exposes batch item failure separately' do
    configuration['response'] = {
      'id' => 'batch.id', 'status' => 'batch.status', 'scope' => 'batch',
      'roles' => { 'status' => { 'items' => 'items', 'item_status' => 'state',
                               'item_id' => 'item.id', 'item_external_id' => 'item.external_id' } }
    }
    simulator = described_class.new(config: configuration, scenario: 'batch_success_item_failed')
    create = parsed(payout(simulator))
    response = parsed(status(simulator, create.dig('batch', 'id')))
    expect(response.dig('batch', 'status')).to eq('paid')
    expect(response.dig('items', 0, 'state')).to eq('failed')
    expect(response.dig('items', 0, 'item', 'external_id')).to eq('operation-key')
  end

  it 'parses form bodies and canonicalizes object order for idempotency' do
    simulator = described_class.new(config: configuration)
    original = simulator.request(method: 'POST', url: '/payouts',
                                 headers: { 'Content-Type' => 'application/x-www-form-urlencoded', 'Idempotency-Key' => 'form-key' },
                                 body: 'metadata%5Bid%5D=example&currency=USD&amount=100')
    repeated = simulator.request(method: 'POST', url: '/payouts',
                                 headers: { 'Content-Type' => 'application/json', 'Idempotency-Key' => 'form-key' },
                                 body: '{"amount":"100","currency":"USD","metadata":{"id":"example"}}')
    expect(original[:status]).to eq(201)
    expect(repeated).to eq(original)
  end

  it 'rejects unknown scenarios, invalid JSON, and unknown endpoints' do
    expect { described_class.new(config: configuration, scenario: 'invented') }.to raise_error(ArgumentError)
    simulator = described_class.new(config: configuration)
    expect(simulator.request(method: 'POST', url: '/payouts', body: 'broken')[:status]).to eq(400)
    expect(simulator.request(method: 'GET', url: '/missing')[:status]).to eq(404)
  end

  it 'runs actual adapter fault checks and produces evidence for every result' do
    klass = Class.new do
      include Paygen::Runtime::Adapter
    end
    klass.const_set(:PAYGEN_CONFIG, configuration)
    report = Paygen::Runtime::Verifier.new(adapter: klass.new, seed: 72).run
    expect(report['checks'].reject { |entry| entry['passed'] }).to eq([])
    expect(report['success']).to be(true)
    expect(report['passed']).to be >= 9
    expect(report['checks']).to all(include('evidence' => include('requests' => be_an(Array))))
    expect(report['checks'].flat_map { |entry| entry.dig('evidence', 'requests') }.size).to be > 15
  end

  it 'fails verification when the adapter approves unknown statuses' do
    klass = Class.new do
      include Paygen::Runtime::Adapter

      def create_request(operation, role = 'create')
        result = super
        return result unless result.dig('error', 'code') == 'unknown_status'

        result.merge('success' => true, 'status' => 'approved')
      end
    end
    klass.const_set(:PAYGEN_CONFIG, configuration)
    report = Paygen::Runtime::Verifier.new(adapter: klass.new).run
    failure = report['checks'].find { |entry| entry['name'] == 'unknown_status_fails_closed' }
    expect(failure['passed']).to be(false)
    expect(report['success']).to be(false)
  end

  it 'refuses to verify a public provider target' do
    klass = Class.new { include Paygen::Runtime::Adapter }
    klass.const_set(:PAYGEN_CONFIG, configuration)
    verifier = Paygen::Runtime::Verifier.new(adapter: klass.new, target: 'https://payments.example')
    expect { verifier.run }.to raise_error(Paygen::Runtime::SecurityError, /loopback/)
  end
end
