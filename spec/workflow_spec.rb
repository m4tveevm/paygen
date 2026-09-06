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
  let(:repeatable_operations) { [] }
  let(:engine) { described_class.new(document, sources: { 'api' => api }, transport: transport, repeatable_operations: repeatable_operations) }

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

  it 'rejects an unknown workflow dependency during validation' do
    document['workflows'][0]['dependsOn'] = ['missing']
    expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_WORKFLOW_REF') }
  end

  it 'rejects an unknown local step dependency before the first HTTP request' do
    status_step['dependsOn'] = ['missing']
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 1_500_000 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_STEP_REF') }
  end

  it 'rejects an unknown workflow in a cross-workflow step dependency' do
    status_step['dependsOn'] = ['$workflows.missing.steps.create']
    expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_WORKFLOW_REF') }
  end

  it 'rejects an unknown step in an existing cross-workflow dependency' do
    document['workflows'] << { 'workflowId' => 'setup', 'steps' => [create_step.dup] }
    status_step['dependsOn'] = ['$workflows.setup.steps.missing']
    expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_STEP_REF') }
  end

  it 'accepts valid local and cross-workflow step dependencies' do
    document['workflows'] << { 'workflowId' => 'setup', 'steps' => [create_step.dup] }
    document['workflows'][0]['dependsOn'] = ['setup']
    status_step['dependsOn'] = ['create', '$workflows.setup.steps.create']
    expect(engine.validate!).to be(engine)
  end

  %w[successActions failureActions onSuccess onFailure].each do |field|
    it "rejects unknown workflow targets in #{field}" do
      owner = field.end_with?('Actions') ? document['workflows'][0] : create_step
      owner[field] = [{ 'name' => 'transfer', 'type' => 'goto', 'workflowId' => 'missing' }]
      expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_WORKFLOW_REF') }
    end

    it "rejects unknown step targets in #{field}" do
      owner = field.end_with?('Actions') ? document['workflows'][0] : create_step
      owner[field] = [{ 'name' => 'transfer', 'type' => 'goto', 'stepId' => 'missing' }]
      expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_STEP_REF') }
    end
  end

  it 'validates targets of reusable actions in their workflow context' do
    document['components'] = { 'failureActions' => { 'recover' => { 'name' => 'recover', 'type' => 'retry', 'stepId' => 'missing' } } }
    create_step['onFailure'] = [{ 'reference' => '$components.failureActions.recover' }]
    expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_STEP_REF') }
  end

  it 'rejects a later unknown operationId before creating a payout' do
    status_step['operationId'] = 'unknownOperation'
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 1_500_000 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_OPERATION_ID') }
  end

  it 'rejects unknown source names in qualified operation references' do
    create_step['operationId'] = '$sourceDescriptions.missing.createPayout'
    expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_SOURCE') }
  end

  it 'checks operations in sources bound by their declared URL' do
    status_step['operationId'] = '$sourceDescriptions.api.missing'
    runner = described_class.new(document, sources: { 'provider.yaml' => api }, transport: transport)
    expect { runner.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_OPERATION_ID') }
  end

  it 'rejects a missing operationPath target during validation' do
    status_step.delete('operationId')
    status_step['operationPath'] = '{$sourceDescriptions.api.url}#/paths/~1missing/get'
    expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_MISSING') }
  end

  it 'rejects operationPath pointers to existing non-operation values' do
    status_step.delete('operationId')
    status_step['operationPath'] = '{$sourceDescriptions.api.url}#/info/title'
    expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_OPERATION_PATH') }
  end

  it 'defers external operation lookups when no source document is supplied' do
    status_step['operationId'] = 'notKnownUntilSourceIsBound'
    expect(Paygen::Core::Input).not_to receive(:read)
    expect(transport).not_to receive(:request)
    runner = described_class.new(document, transport: transport)
    expect(runner.validate!).to be(runner)
    expect(Paygen::Core::Input.parse(runner.export(format: :json))).to eq(document)
  end

  it 'defers declared external workflow identities until their source is supplied' do
    document['sourceDescriptions'] << { 'name' => 'other', 'url' => 'https://workflows.example/other.yaml', 'type' => 'arazzo' }
    document['workflows'][0]['dependsOn'] = ['$sourceDescriptions.other.prepare']
    status_step['dependsOn'] = ['$sourceDescriptions.other.prepare.steps.ready']
    expect(Paygen::Core::Input).not_to receive(:read)
    expect(engine.validate!).to be(engine)
    supplied = { 'arazzo' => '1.1.0', 'workflows' => [{ 'workflowId' => 'prepare', 'steps' => [] }] }
    runner = described_class.new(document, sources: { 'api' => api, 'other' => supplied }, transport: transport)
    expect { runner.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_STEP_REF') }
  end

  it 'rejects unknown workflows in supplied external sources' do
    document['sourceDescriptions'] << { 'name' => 'other', 'url' => 'other.yaml', 'type' => 'arazzo' }
    document['workflows'][0]['dependsOn'] = ['$sourceDescriptions.other.missing']
    supplied = { 'arazzo' => '1.1.0', 'workflows' => [{ 'workflowId' => 'prepare', 'steps' => [create_step.dup] }] }
    runner = described_class.new(document, sources: { 'api' => api, 'other.yaml' => supplied }, transport: transport)
    expect { runner.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_WORKFLOW_REF') }
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

  def add_refresh_recovery
    repeatable_operations << { method: 'POST', url: 'https://provider.example/v1/refresh' }
    api['paths']['/refresh'] = { 'post' => { 'operationId' => 'refreshToken', 'responses' => { '200' => { 'description' => 'Token renewed' } } } }
    api['paths']['/payouts']['post']['parameters'] = [{ 'name' => 'Authorization', 'in' => 'header', 'schema' => { 'type' => 'string' } }]
    create_step['parameters'] = [{ 'name' => 'Authorization', 'in' => 'header', 'value' => 'Bearer {$steps.refresh.outputs.token}' }]
    create_step['onFailure'] = [{ 'name' => 'renew', 'type' => 'retry', 'stepId' => 'refresh', 'retryLimit' => 1, 'criteria' => [{ 'condition' => '$statusCode == 401' }] }]
    helper = { 'stepId' => 'refresh', 'operationId' => 'refreshToken', 'successCriteria' => [{ 'condition' => '$statusCode == 200' }], 'outputs' => { 'token' => '$response.body#/token' } }
    document['workflows'][0]['steps'].unshift(helper)
    helper
  end

  it 'executes a retry helper step and binds refreshed outputs on the next attempt' do
    add_refresh_recovery
    allow(transport).to receive(:request).with(method: 'POST', url: 'https://provider.example/v1/refresh', headers: {}, body: nil).and_return(
      { status: 200, headers: {}, body: '{"token":"expired"}' },
      { status: 200, headers: {}, body: '{"token":"renewed"}' }
    )
    allow(transport).to receive(:request).with(hash_including(method: 'POST', url: 'https://provider.example/v1/payouts', headers: hash_including('Authorization' => 'Bearer expired'))).and_return(status: 401, headers: {}, body: '{}')
    allow(transport).to receive(:request).with(hash_including(method: 'POST', url: 'https://provider.example/v1/payouts', headers: hash_including('Authorization' => 'Bearer renewed'))).and_return(status: 201, headers: {}, body: '{"id":"p_123"}')
    outcome = engine.run('payout', inputs: { 'amount' => 1_500_000 })
    expect(outcome['success']).to be(true)
    expect(outcome['trace'].map { |event| event['stepId'] }).to eq(%w[refresh create refresh create status])
    expect(outcome.dig('steps', 'refresh', 'outputs', 'token')).to eq('renewed')
  end

  it 'stops the payout when its retry helper fails' do
    add_refresh_recovery
    allow(transport).to receive(:request).with(hash_including(url: 'https://provider.example/v1/refresh')).and_return(
      { status: 200, headers: {}, body: '{"token":"expired"}' }, { status: 500, headers: {}, body: '{}' }
    )
    allow(transport).to receive(:request).with(hash_including(url: 'https://provider.example/v1/payouts')).and_return(status: 401, headers: {}, body: '{}')
    outcome = engine.run('payout', inputs: { 'amount' => 1_500_000 })
    expect(outcome['success']).to be(false)
    expect(transport).not_to have_received(:request).with(hash_including(method: 'GET'))
    expect(outcome['trace'].map { |event| event['stepId'] }).to eq(%w[refresh create refresh])
    expect(transport).to have_received(:request).with(hash_including(url: 'https://provider.example/v1/payouts')).once
  end

  it 'counts helper execution toward the shared step limit' do
    add_refresh_recovery
    stub_const('Paygen::Core::Workflow::MAX_STEPS', 2)
    allow(transport).to receive(:request).with(hash_including(url: 'https://provider.example/v1/refresh')).and_return(status: 200, headers: {}, body: '{"token":"expired"}')
    allow(transport).to receive(:request).with(hash_including(url: 'https://provider.example/v1/payouts')).and_return(status: 401, headers: {}, body: '{}')
    expect { engine.run('payout', inputs: { 'amount' => 1_500_000 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_LIMIT') }
    expect(transport).to have_received(:request).with(hash_including(url: 'https://provider.example/v1/refresh')).once
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

  it 'serializes embedded structured inputs as JSON and keeps scalar strings unquoted' do
    create_step['requestBody']['payload'] = '{"payout":{$inputs.payout},"items":{$inputs.items},"reference":"{$inputs.reference}"}'
    inputs = {
      'amount' => 1_500_000, 'payout' => { 'amount' => 42 },
      'items' => [{ 'id' => 'item_1' }], 'reference' => 'ref_1'
    }
    body = '{"payout":{"amount":42},"items":[{"id":"item_1"}],"reference":"ref_1"}'
    allow(transport).to receive(:request).with(hash_including(method: 'POST', body: body)).and_return(status: 201, headers: {}, body: '{"id":"p_123"}')

    expect(engine.run('payout', inputs: inputs)['success']).to be(true)
    expect(transport).to have_received(:request).with(hash_including(body: body)).once
  end

  it 'embeds unparsed XML string values without JSON quoting or escaping' do
    create_step['requestBody'] = { 'contentType' => 'application/xml', 'payload' => '<Envelope>{$inputs.message}</Envelope>' }
    inputs = { 'amount' => 1_500_000, 'message' => '<Payout amount="42"/>' }
    body = '<Envelope><Payout amount="42"/></Envelope>'
    allow(transport).to receive(:request).with(hash_including(method: 'POST', body: body)).and_return(status: 201, headers: {}, body: '{"id":"p_123"}')

    expect(engine.run('payout', inputs: inputs)['success']).to be(true)
    expect(transport).to have_received(:request).with(hash_including(body: body)).once
  end

  it 'resolves workflow inputs, outputs and dependencies with hyphenated identifiers' do
    setup_step = JSON.parse(JSON.generate(create_step)).merge('stepId' => 'refresh-token')
    setup_step['requestBody']['payload']['amount'] = 42
    allow(transport).to receive(:request).with(hash_including(method: 'POST', body: '{"amount":42}')).and_return(status: 201, headers: {}, body: '{"id":"p_123"}')
    document['workflows'] << {
      'workflowId' => 'setup-token', 'steps' => [setup_step],
      'outputs' => { 'token-value.v1' => '$steps.refresh-token.outputs.id' }
    }
    document['workflows'][0]['dependsOn'] = ['setup-token']
    create_step['requestBody']['payload']['amount'] = '$workflows.setup-token.inputs.amount'
    status_step['dependsOn'] = ['$workflows.setup-token.steps.refresh-token']
    document['workflows'][0]['outputs']['token'] = '$workflows.setup-token.outputs.token-value.v1'

    expect(engine.run('payout', inputs: { 'amount' => 1_500_000 })['outputs']).to eq(
      'state' => 'completed', 'token' => 'p_123'
    )
  end

  it 'keeps workflow state local to each document when nested workflow IDs coincide' do
    external = JSON.parse(JSON.generate(document))
    external['workflows'][0]['outputs'] = { 'amount' => '$workflows.payout.inputs.amount' }
    document['sourceDescriptions'] << { 'name' => 'other', 'url' => 'other.yaml', 'type' => 'arazzo' }
    document['workflows'][0]['steps'] << {
      'stepId' => 'invoke', 'workflowId' => '$sourceDescriptions.other.payout',
      'parameters' => [{ 'name' => 'amount', 'value' => 42 }],
      'outputs' => { 'amount' => '$response.body#/amount' }
    }
    document['workflows'][0]['outputs'] = {
      'parentAmount' => '$workflows.payout.inputs.amount',
      'childAmount' => '$steps.invoke.outputs.amount'
    }
    allow(transport).to receive(:request).with(hash_including(method: 'POST', body: '{"amount":42}')).and_return(status: 201, headers: {}, body: '{"id":"p_123"}')
    runner = described_class.new(document, sources: { 'api' => api, 'other' => external }, transport: transport)

    expect(runner.run('payout', inputs: { 'amount' => 1_500_000 })['outputs']).to eq(
      'parentAmount' => 1_500_000, 'childAmount' => 42
    )
  end

  it 'applies payload replacements without changing inputs used by later requests' do
    create_step['requestBody'] = {
      'contentType' => 'application/json', 'payload' => '$inputs.payout',
      'replacements' => [{ 'target' => '/amount', 'value' => '$inputs.amount' }]
    }
    document['workflows'][0]['steps'] = [create_step, {
      'stepId' => 'second', 'operationId' => 'createPayout',
      'requestBody' => { 'contentType' => 'application/json', 'payload' => '$inputs.payout' }
    }]
    document['workflows'][0].delete('outputs')
    inputs = { 'amount' => 1_500_000, 'payout' => { 'amount' => 42 } }
    allow(transport).to receive(:request).with(hash_including(method: 'POST', body: '{"amount":42}')).and_return(status: 201, headers: {}, body: '{}')

    expect(engine.run('payout', inputs: inputs)['success']).to be(true)
    expect(inputs['payout']).to eq('amount' => 42)
    expect(transport).to have_received(:request).with(hash_including(body: '{"amount":1500000}')).once
    expect(transport).to have_received(:request).with(hash_including(body: '{"amount":42}')).once
  end

  it 'copies replacement values before later replacements modify their children' do
    create_step['requestBody'] = {
      'contentType' => 'application/json', 'payload' => { 'payout' => {} },
      'replacements' => [
        { 'target' => '/payout', 'value' => '$inputs.payout' },
        { 'target' => '/payout/amount', 'value' => '$inputs.amount' }
      ]
    }
    inputs = { 'amount' => 1_500_000, 'payout' => { 'amount' => 42 } }
    allow(transport).to receive(:request).with(hash_including(method: 'POST', body: '{"payout":{"amount":1500000}}')).and_return(status: 201, headers: {}, body: '{"id":"p_123"}')

    expect(engine.run('payout', inputs: inputs)['success']).to be(true)
    expect(inputs['payout']).to eq('amount' => 42)
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

  it 'requires an explicit transport but still imports and exports without networking' do
    expect(Paygen::Runtime::HTTPTransport).not_to receive(:new)
    runner = described_class.new(document, sources: { 'api' => api })
    expect(runner.validate!).to be(runner)
    expect(JSON.parse(runner.export(format: :json))).to eq(document)
    expect { runner.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_TRANSPORT') }
  end

  it 'does not repeat a POST when an independent provider commits before losing its response' do
    committed = []
    provider = Object.new
    provider.define_singleton_method(:request) do |**request|
      committed << request
      raise Timeout::Error, 'response lost after committing payout'
    end
    create_step['onFailure'] = [{ 'name' => 'repeat', 'type' => 'retry', 'retryLimit' => 2 }]
    runner = described_class.new(document, sources: { 'api' => api }, transport: provider)
    expect { runner.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED') }
    expect(committed.length).to eq(1)
    expect(committed.first).to include(method: 'POST', body: '{"amount":42}')
  end

  it 'does not let a wrapper retry an ambiguous nested write' do
    document['workflows'] << {
      'workflowId' => 'wrapper', 'steps' => [{ 'stepId' => 'invoke', 'workflowId' => 'payout',
        'parameters' => [{ 'name' => 'amount', 'value' => 1_500_000 }],
        'onFailure' => [{ 'name' => 'again', 'type' => 'retry', 'retryLimit' => 2 }] }]
    }
    allow(transport).to receive(:request).with(hash_including(method: 'POST')).and_raise(IOError)
    expect { engine.run('wrapper') }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED') }
    expect(transport).to have_received(:request).with(hash_including(method: 'POST')).once
  end

  it 'does not retry an entire nested workflow after its write succeeded but polling failed' do
    document['workflows'] << {
      'workflowId' => 'wrapper', 'steps' => [{ 'stepId' => 'invoke', 'workflowId' => 'payout',
        'parameters' => [{ 'name' => 'amount', 'value' => 1_500_000 }],
        'onFailure' => [{ 'name' => 'again', 'type' => 'retry', 'retryLimit' => 2 }] }]
    }
    allow(transport).to receive(:request).with(hash_including(method: 'GET')).and_raise(Timeout::Error)
    expect { engine.run('wrapper') }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED') }
    expect(transport).to have_received(:request).with(hash_including(method: 'POST')).once
  end

  it 'refuses to retry an HTTP 500 write whose outcome may be ambiguous' do
    create_step['onFailure'] = [{ 'name' => 'again', 'type' => 'retry', 'retryLimit' => 2 }]
    allow(transport).to receive(:request).with(hash_including(method: 'POST')).and_return(status: 500, headers: {}, body: '{}')
    expect { engine.run('payout', inputs: { 'amount' => 1_500_000 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED') }
    expect(transport).to have_received(:request).with(hash_including(method: 'POST')).once
  end

  it 'prevents goto from repeating an ambiguous HTTP 500 write' do
    create_step['onFailure'] = [{ 'name' => 'again', 'type' => 'goto', 'stepId' => 'create' }]
    allow(transport).to receive(:request).with(hash_including(method: 'POST')).and_return(status: 500, headers: {}, body: '{}')
    expect { engine.run('payout', inputs: { 'amount' => 1_500_000 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED') }
    expect(transport).to have_received(:request).with(hash_including(method: 'POST')).once
  end

  it 'retains bounded retries for a timed-out read operation' do
    attempts = 0
    status_step['onFailure'] = [{ 'name' => 'again', 'type' => 'retry', 'retryLimit' => 1 }]
    allow(transport).to receive(:request).with(hash_including(method: 'GET')) do
      attempts += 1
      raise Timeout::Error if attempts == 1
      { status: 200, headers: {}, body: '{"status":"completed"}' }
    end
    expect(engine.run('payout', inputs: { 'amount' => 1_500_000 })['success']).to be(true)
    expect(attempts).to eq(2)
    expect(transport).to have_received(:request).with(hash_including(method: 'POST')).once
  end

  it 'rejects XPath in a later step before any provider request, including during validation' do
    status_step['successCriteria'] = [{ 'context' => '$response.body', 'condition' => '/status', 'type' => 'xpath' }]
    expect(transport).not_to receive(:request)
    expect { engine.validate! }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_UNSUPPORTED') }
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_UNSUPPORTED') }
  end

  it 'rejects unsupported selectors in workflow outputs before any provider request' do
    document['workflows'][0]['outputs'] = { 'result' => { 'type' => 'xpath', 'context' => '$response.body', 'selector' => '/status' } }
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_UNSUPPORTED') }
  end

  it 'rejects XPath payload replacements in a later step before creating a payout' do
    status_step['requestBody'] = { 'payload' => {}, 'replacements' => [{ 'targetSelectorType' => { 'type' => 'xpath', 'version' => 'xpath-30' }, 'target' => '/x', 'value' => '$inputs.amount' }] }
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_UNSUPPORTED') }
  end

  it 'rejects unsupported runtime expressions in a later step before a payout' do
    status_step['parameters'][0]['value'] = '$secrets.provider_key'
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_EXPRESSION') }
  end

  it 'rejects unsupported array parameter serialization in a later operation before a payout' do
    api['paths']['/payouts/{id}']['get']['parameters'][0]['schema'] = { 'type' => 'array', 'items' => { 'type' => 'string' } }
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_UNSUPPORTED') }
  end

  it 'rejects an undeclared parameter in a later operation before a payout' do
    status_step['parameters'][0]['name'] = 'missing'
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_PARAMETER') }
  end

  it 'rejects a malformed later simple criterion before a payout' do
    status_step['successCriteria'] = [{ 'condition' => '$statusCode == (200' }]
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_CRITERION') }
  end

  it 'preflights later nested sources and their action targets before the parent POST' do
    external = JSON.parse(JSON.generate(document))
    external['workflows'][0]['steps'][1]['successCriteria'] = [{ 'context' => '$response.body', 'condition' => '/status', 'type' => 'xpath' }]
    document['sourceDescriptions'] << { 'name' => 'other', 'url' => 'other.yaml', 'type' => 'arazzo' }
    status_step['onFailure'] = [{ 'name' => 'recover', 'type' => 'goto', 'workflowId' => '$sourceDescriptions.other.payout' }]
    runner = described_class.new(document, sources: { 'api' => api, 'other' => external }, transport: transport)
    expect(transport).not_to receive(:request)
    expect { runner.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_UNSUPPORTED') }
  end

  it 'requires every reachable nested source before the parent POST' do
    document['sourceDescriptions'] << { 'name' => 'other', 'url' => 'other.yaml', 'type' => 'arazzo' }
    document['workflows'][0]['steps'] << { 'stepId' => 'later', 'workflowId' => '$sourceDescriptions.other.payout' }
    expect(Paygen::Core::Input).not_to receive(:read)
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_SOURCE') }
  end

  it 'schedules forward local step dependencies before their dependent step' do
    status_step['dependsOn'] = ['create']
    document['workflows'][0]['steps'] = [status_step, create_step]
    expect(engine.validate!).to be(engine)
    outcome = engine.run('payout', inputs: { 'amount' => 1_500_000 })
    expect(outcome['success']).to be(true)
    expect(outcome['trace'].map { |event| event['stepId'] }).to eq(%w[create status])
    expect(transport).to have_received(:request).with(hash_including(method: 'POST')).once
  end

  it 'schedules implicit output dependencies even when the consumer appears first' do
    document['workflows'][0]['steps'] = [status_step, create_step]
    outcome = engine.run('payout', inputs: { 'amount' => 1_500_000 })
    expect(outcome['success']).to be(true)
    expect(outcome['trace'].map { |event| event['stepId'] }).to eq(%w[create status])
  end

  %w[$steps.missing.outputs.id $steps.create.outputs.missing $workflows.payout.steps.create.outputs.missing].each do |reference|
    it "rejects #{reference} before a payout" do
      status_step['parameters'][0]['value'] = reference
      expect(transport).not_to receive(:request)
      expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_OUTPUT_REF') }
    end
  end

  it 'validates output references in interpolated payloads and reusable action criteria before effects' do
    document['components'] = { 'failureActions' => { 'recover' => {
      'name' => 'recover', 'type' => 'end', 'criteria' => [{ 'condition' => '$steps.missing.outputs.id == 1' }]
    } } }
    status_step['onFailure'] = [{ 'reference' => '$components.failureActions.recover' }]
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_OUTPUT_REF') }
    status_step.delete('onFailure')
    status_step['requestBody'] = { 'payload' => { 'reference' => 'prefix-{$steps.create.outputs.missing}' } }
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_OUTPUT_REF') }
  end

  it 'rejects implicit cycles and self-dependent request values before effects' do
    create_step['requestBody']['payload']['previous'] = '$steps.status.outputs.state'
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_DEPENDENCY') }
    create_step['requestBody']['payload']['previous'] = '$steps.create.outputs.id'
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_DEPENDENCY') }
  end

  it 'can structurally round-trip unsupported execution dialects without running them' do
    status_step['successCriteria'] = [{ 'context' => '$response.body', 'condition' => '/status', 'type' => 'xpath' }]
    expect(engine.validate!(execution: false)).to be(engine)
    expect(Paygen::Core::Input.parse(engine.export(format: :json))).to eq(document)
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_UNSUPPORTED') }
  end

  it 'rejects cyclic step prerequisites before any provider request' do
    create_step['dependsOn'] = ['status']
    status_step['dependsOn'] = ['create']
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_DEPENDENCY') }
  end

  it 'rejects a cross-workflow prerequisite without an execution dependency before a payout' do
    document['workflows'] << { 'workflowId' => 'setup', 'steps' => [create_step.dup] }
    status_step['dependsOn'] = ['$workflows.setup.steps.create']
    expect(transport).not_to receive(:request)
    expect { engine.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_DEPENDENCY') }
  end

  it 'resolves completed prerequisites from an external workflow document' do
    external = JSON.parse(JSON.generate(document))
    external['workflows'][0]['workflowId'] = 'prepare'
    external['workflows'][0]['steps'] = [JSON.parse(JSON.generate(status_step))]
    external['workflows'][0]['steps'][0]['parameters'][0]['value'] = 'p_123'
    document['sourceDescriptions'] << { 'name' => 'other', 'url' => 'other.yaml', 'type' => 'arazzo' }
    document['workflows'][0]['dependsOn'] = ['$sourceDescriptions.other.prepare']
    status_step['dependsOn'] = ['$sourceDescriptions.other.prepare.steps.status']
    runner = described_class.new(document, sources: { 'api' => api, 'other' => external }, transport: transport)
    expect(runner.run('payout', inputs: { 'amount' => 1_500_000 })['success']).to be(true)
  end

  %w[goto retry].each do |action_type|
    it "prevents a failed GET #{action_type} action from repeating a committed POST" do
      committed = []
      provider = Object.new
      provider.define_singleton_method(:request) do |**request|
        if request[:method] == 'POST'
          committed << request
          { status: 201, headers: {}, body: '{"id":"p_123"}' }
        else
          raise Timeout::Error, 'polling response lost'
        end
      end
      action = { 'name' => 'recreate', 'type' => action_type, 'stepId' => 'create' }
      action['retryLimit'] = 1 if action_type == 'retry'
      status_step['onFailure'] = [action]
      runner = described_class.new(document, sources: { 'api' => api }, transport: provider)
      expect { runner.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED') }
      expect(committed.length).to eq(1)
    end
  end

  it 'shares write reservations with an external recovery workflow after a failed GET' do
    committed = []
    provider = Object.new
    provider.define_singleton_method(:request) do |**request|
      if request[:method] == 'POST'
        committed << request
        { status: 201, headers: {}, body: '{"id":"p_123"}' }
      else
        raise Timeout::Error
      end
    end
    external = JSON.parse(JSON.generate(document))
    external['workflows'][0]['workflowId'] = 'recover'
    document['sourceDescriptions'] << { 'name' => 'other', 'url' => 'other.yaml', 'type' => 'arazzo' }
    status_step['onFailure'] = [{ 'name' => 'recreate', 'type' => 'retry', 'retryLimit' => 1,
      'workflowId' => '$sourceDescriptions.other.recover', 'parameters' => [{ 'name' => 'amount', 'value' => '$inputs.amount' }] }]
    runner = described_class.new(document, sources: { 'api' => api, 'other' => external }, transport: provider)
    expect { runner.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED') }
    expect(committed.length).to eq(1)
  end

  it 'does not accept repeatability declarations from an untrusted Arazzo extension' do
    create_step['x-paygen-repeatable'] = true
    status_step['onFailure'] = [{ 'name' => 'recreate', 'type' => 'goto', 'stepId' => 'create' }]
    allow(transport).to receive(:request).with(hash_including(method: 'GET')).and_raise(Timeout::Error)
    expect { engine.run('payout', inputs: { 'amount' => 1_500_000 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED') }
    expect(transport).to have_received(:request).with(hash_including(method: 'POST')).once
  end

  it 'scopes trusted repeatability to the exact method and URL' do
    repeatable_operations << { method: 'POST', url: 'https://other-provider.example/v1/payouts' }
    repeatable_operations << { method: 'PUT', url: 'https://provider.example/v1/payouts' }
    status_step['onFailure'] = [{ 'name' => 'recreate', 'type' => 'goto', 'stepId' => 'create' }]
    allow(transport).to receive(:request).with(hash_including(method: 'GET')).and_raise(Timeout::Error)
    expect { engine.run('payout', inputs: { 'amount' => 1_500_000 }) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED') }
    expect(transport).to have_received(:request).with(hash_including(method: 'POST')).once
  end

  context 'when a repeated prerequisite changes the write payload' do
    let(:quote_step) do
      { 'stepId' => 'quote', 'operationId' => 'getQuote',
        'outputs' => { 'token' => '$response.body#/token' } }
    end
    let(:observed) { { quotes: 0, polls: 0, attempts: [], committed: [], rejections: [] } }
    let(:provider) do
      evidence = observed
      Object.new.tap do |instance|
        instance.define_singleton_method(:request) do |**request|
          if request[:url].end_with?('/quote')
            evidence[:quotes] += 1
            { status: 200, headers: {}, body: JSON.generate('token' => "quote-#{evidence[:quotes]}") }
          elsif request[:method] == 'POST'
            payload = JSON.parse(request.fetch(:body))
            evidence[:attempts] << payload
            rejection = evidence[:rejections].shift
            evidence[:committed] << payload unless rejection
            { status: rejection || 201, headers: {}, body: '{"id":"p_123"}' }
          else
            evidence[:polls] += 1
            raise Timeout::Error, 'lost polling response' if evidence[:polls] == 1

            { status: 200, headers: {}, body: '{"status":"completed"}' }
          end
        end
      end
    end
    let(:runner) do
      described_class.new(document, sources: { 'api' => api }, transport: provider,
                          repeatable_operations: repeatable_operations)
    end

    before do
      api['paths']['/quote'] = { 'get' => { 'operationId' => 'getQuote', 'responses' => { '200' => { 'description' => 'Quote' } } } }
      create_step['dependsOn'] = ['quote']
      create_step['requestBody']['payload'].merge!('reference' => 'merchant-1', 'quote' => '$steps.quote.outputs.token')
      document['workflows'][0]['steps'].unshift(quote_step)
    end

    %w[goto retry].each do |action_type|
      it "blocks #{action_type} from creating the same payment with a refreshed quote" do
        action = { 'name' => 'requote', 'type' => action_type, 'stepId' => 'quote' }
        if action_type == 'retry'
          action['retryLimit'] = 1
          quote_step['onSuccess'] = [{ 'name' => 'create', 'type' => 'goto', 'stepId' => 'create' }]
        end
        status_step['onFailure'] = [action]

        expect { runner.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) do |error|
          expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED')
        end
        expect(observed[:quotes]).to eq(2)
        expect(observed[:committed]).to eq([{ 'amount' => 42, 'reference' => 'merchant-1', 'quote' => 'quote-1' }])
        expect(observed[:attempts]).to eq(observed[:committed])
      end
    end

    it 'retains logical write identity when an external workflow is invoked again with changed inputs' do
      external = JSON.parse(JSON.generate(document))
      nested = external['workflows'][0]
      nested['steps'] = [nested['steps'].find { |step| step['stepId'] == 'create' }]
      nested['steps'][0].delete('dependsOn')
      nested['steps'][0]['requestBody']['payload']['quote'] = '$inputs.quote'
      nested['outputs'] = { 'id' => '$steps.create.outputs.id' }
      document['sourceDescriptions'] << { 'name' => 'other', 'url' => 'other.yaml', 'type' => 'arazzo' }
      invocation = { 'stepId' => 'invoke', 'workflowId' => '$sourceDescriptions.other.payout',
                     'parameters' => [{ 'name' => 'amount', 'value' => '$inputs.amount' },
                                      { 'name' => 'quote', 'value' => '$steps.quote.outputs.token' }],
                     'outputs' => { 'id' => '$response.body#/id' } }
      document['workflows'][0]['steps'] = [quote_step, invocation, status_step]
      status_step['parameters'][0]['value'] = '$steps.invoke.outputs.id'
      status_step['onFailure'] = [{ 'name' => 'requote', 'type' => 'goto', 'stepId' => 'quote' }]
      nested_runner = described_class.new(document, sources: { 'api' => api, 'other' => external }, transport: provider)

      expect { nested_runner.run('payout', inputs: { 'amount' => 42 }) }.to raise_error(Paygen::Error) do |error|
        expect(error.code).to eq('ARAZZO_RECONCILIATION_REQUIRED')
      end
      expect(observed[:quotes]).to eq(2)
      expect(observed[:attempts].map { |body| body['quote'] }).to eq(['quote-1'])
      expect(observed[:committed].length).to eq(1)
    end

    [401, 429].each do |status|
      it "releases logical and wire reservations after explicit HTTP #{status} rejection" do
        observed[:rejections] << status
        observed[:polls] = 1
        create_step['onFailure'] = [{ 'name' => 'requote', 'type' => 'retry', 'stepId' => 'quote', 'retryLimit' => 1 }]

        expect(runner.run('payout', inputs: { 'amount' => 42 })['success']).to be(true)
        expect(observed[:attempts].map { |body| body['quote'] }).to eq(%w[quote-1 quote-2])
        expect(observed[:committed].map { |body| body['quote'] }).to eq(['quote-2'])
      end
    end

    it 'still allows repetition explicitly authorized by the trusted Ruby caller' do
      repeatable_operations << { method: 'POST', url: 'https://provider.example/v1/payouts' }
      status_step['onFailure'] = [{ 'name' => 'requote', 'type' => 'goto', 'stepId' => 'quote' }]

      expect(runner.run('payout', inputs: { 'amount' => 42 })['success']).to be(true)
      expect(observed[:committed].map { |body| body['quote'] }).to eq(%w[quote-1 quote-2])
    end

    it 'starts a separate write ledger for each top-level run' do
      observed[:polls] = 1
      2.times { expect(runner.run('payout', inputs: { 'amount' => 42 })['success']).to be(true) }
      expect(observed[:committed].length).to eq(2)
    end
  end
end
