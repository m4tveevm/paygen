# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Paygen::Core::Workflow do
  let(:api) do
    { 'openapi' => '3.1.0', 'info' => { 'title' => 'API', 'version' => '1' },
      'servers' => [{ 'url' => 'https://provider.example/v1' }],
      'paths' => {
        '/payouts' => { 'post' => { 'operationId' => 'createPayout', 'responses' => { '201' => { 'description' => 'Created' } } } },
        '/payouts/{id}' => { 'get' => { 'operationId' => 'getPayout', 'parameters' => [{ 'name' => 'id', 'in' => 'path', 'required' => true, 'schema' => { 'type' => 'string' } }], 'responses' => { '200' => { 'description' => 'OK' } } } }
      } }
  end
  let(:create_step) do
    { 'stepId' => 'create', 'operationId' => 'createPayout',
      'requestBody' => { 'contentType' => 'application/json', 'payload' => { 'amount' => '$inputs.amount' } },
      'successCriteria' => [{ 'condition' => '$statusCode == 201' }],
      'outputs' => { 'id' => '$response.body#/id' } }
  end
  let(:status_step) do
    { 'stepId' => 'status', 'operationId' => 'getPayout',
      'parameters' => [{ 'name' => 'id', 'in' => 'path', 'value' => '$steps.create.outputs.id' }],
      'successCriteria' => [{ 'condition' => "$statusCode == 200 && $response.body.status == 'completed'" }],
      'outputs' => { 'state' => '$response.body#/status' } }
  end
  let(:document) do
    { 'arazzo' => '1.1.0', 'info' => { 'title' => 'Payout lifecycle', 'version' => '1' },
      'sourceDescriptions' => [{ 'name' => 'api', 'url' => 'provider.yaml', 'type' => 'openapi' }],
      'workflows' => [{ 'workflowId' => 'payout', 'inputs' => { 'type' => 'object', 'required' => ['amount'], 'properties' => { 'amount' => { 'type' => 'integer', 'minimum' => 1 } } },
                        'steps' => [create_step, status_step], 'outputs' => { 'state' => '$steps.status.outputs.state' } }] }
  end
  let(:transport) { instance_double(Paygen::Runtime::HTTPTransport) }
  let(:engine) { described_class.new(document, sources: { 'api' => api }, transport: transport) }

  before do
    allow(transport).to receive(:request).with(method: 'POST', url: 'https://provider.example/v1/payouts', headers: { 'Content-Type' => 'application/json' }, body: '{"amount":1500000}').and_return(status: 201, headers: {}, body: '{"id":"p_123"}')
    allow(transport).to receive(:request).with(method: 'GET', url: 'https://provider.example/v1/payouts/p_123', headers: {}, body: nil).and_return(status: 200, headers: {}, body: '{"status":"completed"}')
  end

  it 'validates against the official schema and runs create/status outputs' do
    expect(engine.validate!).to be(engine)
    outcome = engine.run('payout', inputs: { 'amount' => 1_500_000 }, seed: 42)
    expect(outcome).to include('success' => true, 'outputs' => { 'state' => 'completed' }, 'seed' => 42)
    expect(outcome['trace'].size).to eq(2)
    expect(outcome['trace'].to_s).not_to include('1500000')
  end

  it 'round-trips YAML and JSON without losing workflow expressions' do
    %i[yaml json].each do |format|
      expect(Paygen::Core::Input.parse(engine.export(format: format))).to eq(document)
    end
  end

  it 'rejects duplicate IDs and malformed constructs on import' do
    document['workflows'][0]['steps'] << create_step.merge('operationId' => 'getPayout')
    expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_DUPLICATE') }
  end

  it 'validates workflow inputs before making a request' do
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => -1 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_INPUTS') }
  end

  it 'supports operationPath and RFC JSONPath criteria' do
    create_step.delete('operationId')
    create_step['operationPath'] = '{$sourceDescriptions.api.url}#/paths/~1payouts/post'
    status_step['successCriteria'] = [{ 'context' => '$response.body', 'condition' => '$.status', 'type' => 'jsonpath' }]
    expect(engine.run('payout', inputs: { 'amount' => 1_500_000 })['success']).to be(true)
  end

  it 'retries matching failures with a bounded injected delay' do
    delays = []
    create_step['onFailure'] = [{ 'name' => 'busy', 'type' => 'retry', 'retryAfter' => 0.01, 'retryLimit' => 1, 'criteria' => [{ 'condition' => '$statusCode == 429' }] }]
    allow(transport).to receive(:request).with(hash_including(method: 'POST')).and_return({ status: 429, headers: {}, body: '{}' }, { status: 201, headers: {}, body: '{"id":"p_123"}' })
    runner = described_class.new(document, sources: { 'api' => api }, transport: transport, sleeper: ->(delay) { delays << delay })
    expect(runner.run('payout', inputs: { 'amount' => 1_500_000 })['success']).to be(true)
    expect(delays).to eq([0.01])
  end

  it 'ends failures without claiming success' do
    allow(transport).to receive(:request).with(hash_including(method: 'POST')).and_return(status: 400, headers: {}, body: '{}')
    expect(transport).not_to receive(:request).with(hash_including(method: 'GET'))
    expect(engine.run('payout', inputs: { 'amount' => 1_500_000 })['success']).to be(false)
  end

  it 'runs nested workflows with explicitly mapped inputs' do
    document['workflows'] << { 'workflowId' => 'wrapper', 'steps' => [{ 'stepId' => 'invoke', 'workflowId' => 'payout', 'parameters' => [{ 'name' => 'amount', 'value' => 1_500_000 }], 'outputs' => { 'result' => '$response.body#/state' } }], 'outputs' => { 'state' => '$steps.invoke.outputs.result' } }
    expect(engine.run('wrapper')['outputs']).to eq('state' => 'completed')
  end

  it 'rejects recursive workflow calls' do
    document['workflows'] << { 'workflowId' => 'loop', 'steps' => [{ 'stepId' => 'again', 'workflowId' => 'loop' }] }
    expect { engine.run('loop') }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_CYCLE') }
  end

  it 'evaluates grouped conditions without evaluating Ruby' do
    condition = described_class::Condition
    expect(condition.new("('COMPLETED' == 'completed' && 201 >= 200) || false", ->(_) {}).evaluate).to be(true)
    expect { condition.new('Kernel.system("touch pwned")', ->(_) {}).evaluate }.to raise_error(Paygen::Error)
  end
end
