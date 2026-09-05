# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Paygen::Core::Input, 'reference graph imports' do
  let(:document) do
    {
      'openapi' => '3.1.0', 'info' => { 'title' => 'Graph API', 'version' => '1' },
      'paths' => { '/transfers' => { 'post' => {
        'operationId' => 'createTransfer',
        'requestBody' => { 'content' => { 'application/json' => { 'schema' => { '$ref' => '#/components/schemas/Transfer' } } } },
        'responses' => { '201' => { 'description' => 'Created' } }
      } } },
      'components' => { 'schemas' => { 'Transfer' => { 'type' => 'object', 'properties' => { 'amount' => { 'type' => 'integer' } } } } }
    }
  end

  it 'imports complete pinned native documents without rewriting or expanding their schema graphs' do
    %w[paypal/upstream/paypal.json adyen/upstream/adyen.json adyen/upstream/adyen-webhooks.json].each do |relative|
      original = described_class.read(File.expand_path("../fixtures/#{relative}", __dir__))
      imported = described_class.graph(original)
      expect(imported).to eq(original)
      expect(Paygen.json(imported)).to include('"$ref"')
      path = imported.fetch('paths', imported['webhooks']).values.find { |item| item.key?('post') }
      operation = described_class.resolve_fragment(imported, path.fetch('post'))
      schema = operation.dig('requestBody', 'content', 'application/json', 'schema')
      expect(schema).to be_a(Hash)
      expect(schema).not_to have_key('$ref')
      expect(original).to eq(described_class.read(File.expand_path("../fixtures/#{relative}", __dir__)))
    end
  end

  it 'bounds retained graph nodes independently from repeated reference expansion' do
    (described_class::MAX_REFS + 1).times do |index|
      document['paths']["/transfers/#{index}"] = document['paths']['/transfers']
    end
    expect { described_class.resolve(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_LIMIT') }
    expect(described_class.graph(document)).to eq(document)
    operation = described_class.resolve_fragment(document, document.dig('paths', '/transfers', 'post'))
    expect(operation.dig('requestBody', 'content', 'application/json', 'schema', 'properties', 'amount', 'type')).to eq('integer')
  end

  it 'retains legal unused recursive schemas and diagnoses a selected recursive schema' do
    document['components']['schemas']['Tree'] = {
      'type' => 'object', 'properties' => { 'children' => { 'type' => 'array', 'items' => { '$ref' => '#/components/schemas/Tree' } } }
    }
    expect(described_class.graph(document)).to eq(document)
    expect { described_class.resolve_fragment(document, document.dig('paths', '/transfers', 'post')) }.not_to raise_error
    expect do
      described_class.resolve_fragment(document, { '$ref' => '#/components/schemas/Tree' }, schema_context: true)
    end.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_CYCLE') }
  end

  it 'retains internal dynamic schemas but requires explicit normalization when they are selected' do
    document['components']['schemas']['Tree'] = {
      '$dynamicAnchor' => 'node', 'type' => 'object',
      'properties' => { 'children' => { 'type' => 'array', 'items' => { '$dynamicRef' => '#node' } } }
    }
    expect(described_class.graph(document)).to eq(document)
    expect do
      described_class.resolve_fragment(document, document.dig('components', 'schemas', 'Tree'), schema_context: true)
    end.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_DYNAMIC_UNSUPPORTED') }
    document['components']['schemas']['Tree']['$dynamicRef'] = 'https://example.com/tree'
    expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_EXTERNAL_DENIED') }
  end

  it 'checks missing references even in unrelated branches and rejects unsafe references before validation' do
    ['#/components/schemas/Absent', 'https://example.com/schema', '#/components/%XX', 12].each do |ref|
      document['components']['schemas']['Unused'] = { '$ref' => ref }
      expect { described_class.graph(document) }.to raise_error(Paygen::Error)
    end
  end

  it 'validates unrelated operation shapes and illegal Reference Object siblings instead of silently discarding them' do
    document['paths']['/unrelated'] = { 'get' => { 'responses' => { '200' => {} } } }
    expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('OAS_INVALID') }
    document['paths'].delete('/unrelated')
    document['components']['headers'] = { 'Location' => { 'schema' => { 'type' => 'string' } } }
    document['paths']['/transfers']['post']['responses']['201']['headers'] = {
      'Location' => { '$ref' => '#/components/headers/Location', 'example' => 'https://example.com/transfer' }
    }
    expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('OAS_INVALID') }
  end

  it 'keeps reference-shaped example payloads and extension data literal' do
    schema = document['components']['schemas']['Transfer']
    schema['properties']['$ref'] = { 'type' => 'string' }
    schema['example'] = { '$ref' => 'https://example.com/literal' }
    schema['x-test'] = { '$dynamicRef' => 'https://example.com/literal' }
    document['paths']['/transfers']['post']['requestBody']['content']['application/json']['schema']['example'] = { '$ref' => 'literal user data' }
    expect(described_class.graph(document)).to eq(document)
  end

  it 'treats plural schema examples as literal data while still resolving media-type Example Objects' do
    schema = document['components']['schemas']['Transfer']
    schema['examples'] = [{ '$ref' => 'literal user data' }, { '$dynamicRef' => 'https://example.com/literal' }]
    schema['properties']['examples'] = { '$ref' => '#/components/schemas/TransferAmount' }
    document['components']['schemas']['TransferAmount'] = { 'type' => 'integer' }
    document['components']['examples'] = { 'Transfer' => { 'value' => { '$ref' => 'literal user data', 'amount' => 12 } } }
    media_type = document['paths']['/transfers']['post']['requestBody']['content']['application/json']
    media_type['examples'] = { 'named' => { '$ref' => '#/components/examples/Transfer' } }
    expect(described_class.graph(document)).to eq(document)
    selected = described_class.resolve_fragment(document, document['paths']['/transfers']['post'])
    content = selected.dig('requestBody', 'content', 'application/json')
    expect(content.dig('schema', 'examples')).to eq(schema['examples'])
    expect(content.dig('schema', 'properties', 'examples')).to eq('type' => 'integer')
    expect(content.dig('examples', 'named', 'value')).to eq('$ref' => 'literal user data', 'amount' => 12)
    media_type['examples']['named']['$ref'] = '#/components/examples/Missing'
    expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_MISSING') }
  end

  it 'dereferences only the Reference Object chain for operation inventory' do
    document['components']['pathItems'] = { 'Transfers' => document['paths']['/transfers'] }
    document['paths']['/transfers'] = { '$ref' => '#/components/pathItems/Transfers', 'summary' => 'Selected path' }
    resolved = described_class.dereference(document, document['paths']['/transfers'])
    expect(resolved['summary']).to eq('Selected path')
    expect(resolved.dig('post', 'requestBody', 'content', 'application/json', 'schema', '$ref')).to eq('#/components/schemas/Transfer')
    document['components']['pathItems']['Transfers'] = { '$ref' => '#/paths/~1transfers' }
    expect { described_class.dereference(document, document['paths']['/transfers']) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_CYCLE') }
  end

  it 'preserves conjunctive 3.1 constraints when expanding a selected schema fragment' do
    reference = { '$ref' => '#/components/schemas/Transfer', 'required' => ['amount'] }
    schema = described_class.resolve_fragment(document, reference, schema_context: true)
    expect(JSONSchemer.schema(schema).valid?({})).to be(false)
    expect(JSONSchemer.schema(schema).valid?({ 'amount' => 12 })).to be(true)
  end

  it 'accepts relative OAuth URLs in both dialects without modifying source URLs or disabling unrelated format checks' do
    %w[3.0.3 3.1.0].each do |version|
      document['openapi'] = version
      document['components']['securitySchemes'] = {
        'oauth' => { 'type' => 'oauth2', 'flows' => {
          'clientCredentials' => { 'tokenUrl' => '/token', 'refreshUrl' => '../refresh', 'scopes' => {} },
          'authorizationCode' => { 'authorizationUrl' => 'authorize?scope=payouts', 'tokenUrl' => '/token', 'scopes' => {} }
        } }
      }
      original = Paygen.json(document)
      expect(described_class.graph(document)).to eq(document)
      expect(Paygen.json(document)).to eq(original)
      expect(document.dig('components', 'securitySchemes', 'oauth', 'flows', 'clientCredentials', 'tokenUrl')).to eq('/token')
      document['info']['contact'] = { 'email' => 'not an email' }
      expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('OAS_INVALID') }
      document['info'].delete('contact')
    end
  end

  it 'keeps malformed OAuth URL and non-string URL diagnostics' do
    ['bad token URL', 'https://example.com/%ZZ', 12].each do |url|
      document['components']['securitySchemes'] = {
        'oauth' => { 'type' => 'oauth2', 'flows' => { 'clientCredentials' => { 'tokenUrl' => url, 'scopes' => {} } } }
      }
      expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('OAS_INVALID') }
    end
  end
end
