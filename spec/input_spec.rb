# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'

RSpec.describe Paygen::Core::Input do
  let(:document) { { 'openapi' => '3.0.3', 'info' => { 'title' => 'API', 'version' => '1' }, 'paths' => {} } }

  it 'loads JSON from stdin and validates both OAS dialects' do
    %w[3.0.3 3.1.0].each do |version|
      document['openapi'] = version
      expect(described_class.load('-', stdin: StringIO.new(JSON.generate(document)))).to eq(document)
    end
  end

  it 'uses JSON-compatible YAML 1.2 scalars and string keys' do
    parsed = described_class.parse("code: 044525225\nanswer: yes\nstatus: true\nnullable: null\nresponses:\n  200: ok\n")
    expect(parsed).to eq('code' => '044525225', 'answer' => 'yes', 'status' => true, 'nullable' => nil, 'responses' => { '200' => 'ok' })
  end

  it 'rejects duplicate keys including JSON keys before conversion' do
    ["a: 1\na: 2\n", '{"a": 1, "a": 2}'].each do |text|
      expect { described_class.parse(text) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('INPUT_DUPLICATE') }
    end
  end

  it 'denies aliases, object tags, merge keys and multi-document streams' do
    ["a: &a [1]\nb: *a", 'a: !ruby/object:Gem::Requirement {}', "a: {<<: {b: 1}}", "---\na: 1\n---\nb: 2"].each do |text|
      expect { described_class.parse(text) }.to raise_error(Paygen::Error)
    end
  end

  it 'bounds document input, nesting, and nonfinite numbers' do
    expect { described_class.parse('x' * (described_class::MAX_BYTES + 1)) }.to raise_error(Paygen::Error)
    expect { described_class.parse('{"x":' * 110 + '0' + '}' * 110) }.to raise_error(Paygen::Error)
    expect { described_class.parse('a: .nan') }.to raise_error(Paygen::Error)
  end

  it 'rejects invalid OAS objects using the official meta schema' do
    document['paths'] = { '/payout' => { 'post' => { 'responses' => { '200' => {} } } } }
    expect { described_class.validate!(document) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('OAS_INVALID') }
  end

  it 'resolves escaped pointers while preserving null values' do
    expect(described_class.pointer({ 'a/b' => { '~key' => nil } }, '/a~1b/~0key')).to be_nil
    expect { described_class.pointer([], '/-1') }.to raise_error(Paygen::Error)
  end

  it 'resolves local documents and nested refs relative to each document' do
    Dir.mktmpdir do |dir|
      Dir.mkdir(File.join(dir, 'defs'))
      File.write(File.join(dir, 'defs', 'value.yaml'), "value:\n  type: string\n")
      File.write(File.join(dir, 'defs', 'schema.yaml'), "type: object\nproperties:\n  id:\n    $ref: 'value.yaml#/value'\n")
      document['components'] = { 'schemas' => { 'Item' => { '$ref' => 'defs/schema.yaml' } } }
      resolved = described_class.resolve(document, base_dir: dir)
      expect(resolved.dig('components', 'schemas', 'Item', 'properties', 'id', 'type')).to eq('string')
    end
  end

  it 'denies traversal, symlink escapes, network refs and cycles' do
    Dir.mktmpdir do |dir|
      File.symlink('/etc/passwd', File.join(dir, 'escape.yaml'))
      ['../../etc/passwd', 'escape.yaml', 'https://example.com/spec.json'].each do |ref|
        expect { described_class.resolve({ '$ref' => ref }, base_dir: dir) }.to raise_error(Paygen::Error)
      end
      expect { described_class.resolve({ 'a' => { '$ref' => '#/a' } }, base_dir: dir) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_CYCLE') }
    end
  end

  it 'preserves 3.1 schema ref sibling constraints through conjunction' do
    document['openapi'] = '3.1.0'
    document['components'] = { 'schemas' => { 'Base' => { 'type' => 'integer', 'minimum' => 10 }, 'Restricted' => { '$ref' => '#/components/schemas/Base', 'minimum' => 2 } } }
    schema = described_class.resolve(document).dig('components', 'schemas', 'Restricted')
    expect(JSONSchemer.schema(schema).valid?(5)).to be(false)
    expect(JSONSchemer.schema(schema).valid?(10)).to be(true)
  end

  it 'rejects private DNS answers even mixed with public addresses' do
    allow(Resolv).to receive(:getaddresses).with('provider.example').and_return(['93.184.216.34', '127.0.0.1'])
    expect { described_class.public_addresses('provider.example') }.to raise_error(Paygen::Error) { |error| expect(error.exit_code).to eq(5) }
  end

  it 'rejects unsafe source URLs before a connection is made' do
    %w[http://example.com ftp://example.com https://user:pass@example.com https://example.com:8080 https://example.com/#secret].each do |url|
      expect { described_class.https_uri(url) }.to raise_error(Paygen::Error)
    end
  end
end
