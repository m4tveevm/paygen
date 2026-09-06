# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Paygen::Core::Input, 'OpenAPI 3.1 schema resources' do
  let(:recipient) { { 'type' => 'object', 'required' => ['account'], 'properties' => { 'account' => { 'type' => 'string' } } } }
  let(:transfer) do
    { '$id' => 'https://schemas.example/transfers.json', 'type' => 'object', 'required' => ['recipient'],
      '$defs' => { 'Recipient' => recipient }, 'properties' => { 'recipient' => { '$ref' => '#/$defs/Recipient' } } }
  end
  let(:document) do
    { 'openapi' => '3.1.0', 'info' => { 'title' => 'Resource scope', 'version' => '1' },
      'paths' => { '/transfers' => { 'post' => {
        'requestBody' => { 'content' => { 'application/json' => { 'schema' => { '$ref' => '#/components/schemas/Transfer' } } } },
        'responses' => { '201' => { 'description' => 'Created' } }
      } } }, 'components' => { 'schemas' => { 'Transfer' => transfer } } }
  end

  def selected_schema(source = document)
    operation = described_class.resolve_fragment(source, source.dig('paths', '/transfers', 'post'))
    operation.dig('requestBody', 'content', 'application/json', 'schema')
  end

  it 'resolves resource-relative $defs after graph import and a serialization round trip' do
    expect(described_class.graph(document)).to eq(document)
    imported = JSON.parse(JSON.generate(document))
    schema = selected_schema(imported)
    expect(schema.dig('properties', 'recipient')).to eq(recipient)
    expect(JSONSchemer.schema(schema).valid?({ 'recipient' => { 'account' => 'test-account' } })).to be(true)
    expect(JSONSchemer.schema(schema).valid?({ 'recipient' => {} })).to be(false)
  end

  it 'retains a selected child schema scope even when expansion starts below its $id' do
    value = transfer.dig('properties', 'recipient')
    expect(described_class.resolve_fragment(document, value, schema_context: true)).to eq(recipient)
    expect(described_class.dereference(document, value)).to eq(recipient)
  end

  it 'resolves embedded absolute IDs and relative IDs against the enclosing resource URI' do
    recipient['$id'] = './types/../recipient.json'
    transfer['properties']['recipient']['$ref'] = 'recipient.json'
    document['components']['schemas']['RecipientAlias'] = { '$ref' => 'https://schemas.example/recipient.json' }
    expect(described_class.graph(document)).to eq(document)
    expect(selected_schema.dig('properties', 'recipient')).to eq(recipient)
    expect(described_class.resolve_fragment(document, document.dig('components', 'schemas', 'RecipientAlias'), schema_context: true)).to eq(recipient)
    expect(WebMock).not_to have_requested(:any, /schemas\.example/)
  end

  it 'changes fragment scope again for a nested resource with its own $defs' do
    recipient['$id'] = 'recipient.json'
    recipient['$defs'] = { 'Account' => { 'type' => 'string', 'pattern' => '^account-' } }
    recipient['properties']['account'] = { '$ref' => '#/$defs/Account' }
    transfer['properties']['recipient']['$ref'] = 'recipient.json'
    expect(described_class.graph(document)).to eq(document)
    schema = selected_schema
    expect(schema.dig('properties', 'recipient', 'properties', 'account')).to eq(recipient['$defs']['Account'])
    expect(JSONSchemer.schema(schema).valid?({ 'recipient' => { 'account' => 'account-1' } })).to be(true)
    expect(JSONSchemer.schema(schema).valid?({ 'recipient' => { 'account' => 'wrong' } })).to be(false)
  end

  it 'keeps document-root pointer references outside an embedded resource in document scope' do
    document['components']['schemas']['Alias'] = { '$ref' => '#/components/schemas/Transfer' }
    document['paths']['/transfers']['post']['requestBody']['content']['application/json']['schema']['$ref'] = '#/components/schemas/Alias'
    expect(described_class.graph(document)).to eq(document)
    expect(selected_schema.dig('properties', 'recipient')).to eq(recipient)
  end

  it 'does not silently resolve a resource fragment against the enclosing OpenAPI root' do
    transfer['properties']['recipient']['$ref'] = '#/components/schemas/Transfer'
    expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_MISSING') }
  end

  it 'scopes identical anchor names independently and never searches other resources' do
    recipient['$anchor'] = 'Recipient'
    transfer['properties']['recipient']['$ref'] = '#Recipient'
    document['components']['schemas']['Other'] = { '$id' => 'https://schemas.example/other.json', '$anchor' => 'Recipient', 'type' => 'integer' }
    expect(described_class.graph(document)).to eq(document)
    expect(selected_schema.dig('properties', 'recipient')).to eq(recipient)
    document['components']['schemas']['WrongScope'] = { '$ref' => '#Recipient' }
    expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_ANCHOR') }
  end

  it 'rejects duplicate anchors within one resource' do
    recipient['$anchor'] = 'Recipient'
    transfer['$defs']['Duplicate'] = { '$anchor' => 'Recipient', 'type' => 'integer' }
    expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_ANCHOR') }
  end

  it 'rejects collisions after URI normalization rather than choosing a resource by traversal order' do
    document['components']['schemas']['Collision'] = { '$id' => 'https://SCHEMAS.example:443/unused/../transfers%2Ejson#', 'type' => 'integer' }
    expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_ID_DUPLICATE') }
  end


  it 'uses the real root filename when a relative ref points back to it' do
    Dir.mktmpdir do |dir|
      main = Marshal.load(Marshal.dump(document))
      main['components']['schemas']['Recipient'] = recipient
      main['paths']['/transfers']['post']['requestBody']['content']['application/json']['schema'] = {
        '$ref' => 'wrapper.yaml#/Recipient'
      }
      File.write(File.join(dir, 'main.yaml'), YAML.dump(main))
      File.write(File.join(dir, 'wrapper.yaml'), YAML.dump(
        'Recipient' => { '$ref' => 'main.yaml#/components/schemas/Recipient' }
      ))

      expect { described_class.load(File.join(dir, 'main.yaml')) }.not_to raise_error
    end
  end

  it 'ignores resource-shaped literal examples, defaults and schema property names' do
    recipient['properties']['$id'] = { 'type' => 'string' }
    recipient['examples'] = [{ '$id' => transfer['$id'], '$anchor' => 'Recipient', '$ref' => 'https://untrusted.example/data' }]
    expect(described_class.graph(document)).to eq(document)
    expect(selected_schema.dig('properties', 'recipient', 'examples')).to eq(recipient['examples'])
  end

  it 'retains an unused recursive resource and reports a selected resource cycle' do
    document['components']['schemas']['Tree'] = { '$id' => 'https://schemas.example/tree.json', 'type' => 'object', 'properties' => { 'child' => { '$ref' => '#' } } }
    expect(described_class.graph(document)).to eq(document)
    expect { selected_schema }.not_to raise_error
    expect do
      described_class.resolve_fragment(document, { '$ref' => 'https://schemas.example/tree.json' }, schema_context: true)
    end.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_CYCLE') }
  end

  it 'never downloads an unregistered resource, including relative refs under a remote $id' do
    ['https://untrusted.example/schema', 'missing.json', 'http://169.254.169.254/latest'].each do |ref|
      transfer['properties']['recipient']['$ref'] = ref
      expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_EXTERNAL_DENIED') }
    end
    expect(WebMock).not_to have_requested(:any, /untrusted\.example|schemas\.example|169\.254/)
  end

  it 'rejects unsupported or malformed IDs with a specific diagnostic' do
    ['https://schemas.example/transfer#named', 'https://schemas.example/%XX', 42].each do |id|
      transfer['$id'] = id
      expect { described_class.graph(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_ID') }
    end
  end

  it 'keeps local file resolution beneath the permitted source directory when an ID changes the base' do
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, 'schemas'))
      File.write(File.join(dir, 'schemas', 'recipient.json'), JSON.generate(recipient))
      transfer['$id'] = 'schemas/transfer.json'
      transfer['properties']['recipient']['$ref'] = 'recipient.json'
      expect(described_class.resolve(document, base_dir: dir).dig('components', 'schemas', 'Transfer', 'properties', 'recipient')).to eq(recipient)
      transfer['properties']['recipient']['$ref'] = '../../../etc/passwd'
      expect { described_class.resolve(document, base_dir: dir) }.to raise_error(Paygen::Error) { |error| expect(%w[REF_PATH REF_MISSING]).to include(error.code) }
    end
  end
end
