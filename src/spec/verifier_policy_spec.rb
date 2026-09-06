# frozen_string_literal: true

require 'spec_helper'
require 'paygen/runtime/verifier'

RSpec.describe Paygen::Runtime::Verifier do
  let(:response_schema) do
    { 'type' => 'object', 'required' => ['data'],
      'properties' => { 'data' => { 'type' => 'object', 'required' => %w[id state],
                                   'properties' => { 'id' => { 'type' => 'string' },
                                                     'state' => { 'type' => 'string', 'enum' => %w[pending paid failed] } } } } }
  end
  let(:config) do
    {
      'provider' => 'native_envelope', 'mode' => 'sandbox', 'openapi' => '3.1.0',
      'servers' => ['https://example.test/v1'],
      'amount' => { 'input_unit' => 'major', 'scale' => 100, 'minimum' => 1, 'currencies' => ['RUB'] },
      'request_mapping' => { 'reference' => { 'from' => 'id' }, 'amount' => { 'from' => 'amount', 'transform' => 'decimal_number' } },
      'idempotency' => { 'header' => nil, 'from' => 'id', 'strategy' => 'reconcile_before_retry' },
      'auth' => { 'type' => 'bearer', 'credential' => 'token' },
      'response' => { 'id' => 'data.id', 'status' => 'data.state' },
      'status_mapping' => { 'pending' => 'in_progress', 'paid' => 'approved', 'failed' => 'rejected' },
      'endpoints' => {
        'create' => { 'method' => 'POST', 'path' => '/payments',
                      'responses' => { '201' => { 'content' => { 'application/json' => { 'schema' => response_schema } } } } },
        'status' => { 'method' => 'GET', 'path' => '/payments/{id}',
                      'responses' => { '200' => { 'content' => { 'application/json' => { 'schema' => response_schema } } } } }
      }
    }
  end

  def adapter(configuration = config)
    service = Class.new { include Paygen::Runtime::Adapter }
    service.const_set(:PAYGEN_CONFIG, configuration)
    service.new
  end

  it 'proves strict replay policy through observed HTTP counts and validates native response envelopes' do
    report = described_class.new(adapter: adapter, seed: 51).run(scenario_pack: 'transport')
    expect(report['checks'].reject { |entry| entry['passed'] }).to eq([])
    expect(report['success']).to be(true)
    expect(report['coverage']).to include('does not prove live provider compatibility')
    contracts = report['checks'].find { |entry| entry['name'] == 'create_and_fetch_status' }.dig('observed', 'response_contracts')
    expect(contracts).to all(include('schema' => 'valid', 'source' => 'effective_openapi', 'payload_source' => 'profile_derived_simulator'))
    %w[local_create_cache_and_payload_conflict timeout_after_commit_requires_reconciliation rate_limit_preserves_reconciliation_policy].each do |name|
      entry = report['checks'].find { |check| check['name'] == name }
      expect(entry['passed']).to be(true)
      expect(entry.dig('evidence', 'requests').count { |request| request['role'] == 'create' }).to eq(1)
    end
  end

  it 'catches an adapter that secretly redispatches strict-policy creates even if the simulator deduplicates them' do
    config['idempotency']['body'] = 'reference'
    # The provider recognizes the reference, but its retention window is unknown.
    # The adapter must still enforce reconciliation and count actual dispatches.
    config['idempotency'].delete('strategy')
    instance = adapter
    instance.define_singleton_method(:reserve_create_request) do |_request, _operation, _role|
      nil
    end
    report = described_class.new(adapter: instance).run(scenario_pack: 'transport')
    replay = report['checks'].find { |check| check['name'] == 'local_create_cache_and_payload_conflict' }
    expect(replay['passed']).to be(false)
    expect(replay['error']).to include('another provider create request')
    expect(replay.dig('evidence', 'created_count')).to eq(1)
  end

  it 'rejects a schema-invalid simulator response even when its mapped status and identifier look successful' do
    schema = response_schema
    schema['required'] << 'bank_reference'
    schema['properties']['bank_reference'] = { 'type' => 'string', 'pattern' => '^BANK-[0-9]{3}$' }
    report = described_class.new(adapter: adapter).run(scenario_pack: 'transport')
    check = report['checks'].find { |entry| entry['name'] == 'create_and_fetch_status' }
    expect(check['passed']).to be(false)
    expect(check['error']).to include('invalid_provider_response', '/bank_reference: pattern')
  end

  it 'reports absent response schemas without treating undeclared validation as successful schema evidence' do
    config['endpoints'].each_value { |endpoint| endpoint['responses'].each_value { |response| response.clear } }
    report = described_class.new(adapter: adapter).run(scenario_pack: 'transport')
    check = report['checks'].find { |entry| entry['name'] == 'create_and_fetch_status' }
    expect(check['passed']).to be(true)
    expect(check.dig('observed', 'response_contracts')).to all(include('schema' => 'not_declared'))
  end

  it 'verifies the actual authentication bytes sent by the generated adapter' do
    instance = adapter
    instance.define_singleton_method(:paygen_request) do |request, _role, _operation|
      request.merge(headers: request.fetch(:headers).merge('Authorization' => 'Bearer incorrect'))
    end
    report = described_class.new(adapter: instance).run(scenario_pack: 'transport')
    expect(report['success']).to be(false)
    expect(report['checks'].find { |entry| entry['name'] == 'create_and_fetch_status' }['passed']).to be(false)
  end

  it 'preserves an explicitly mapped reversal result instead of recasting it as a rejection' do
    config['status_mapping']['returned'] = 'reversed'
    config['simulator'] = { 'scenarios' => { 'booked_then_returned' => { 'statuses' => %w[paid returned] } } }
    response_schema.dig('properties', 'data', 'properties', 'state', 'enum') << 'returned'
    report = described_class.new(adapter: adapter).run(scenario_pack: 'reversals')
    entry = report['checks'].find { |check| check['name'] == 'booked_then_returned' }
    expect(entry['passed']).to be(true)
    expect(entry.dig('observed', 'after', 'status')).to eq('reversed')
  end
end
