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
    expect { described_class.parse(('{"x":' * 110) + '0' + ('}' * 110)) }.to raise_error(Paygen::Error)
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

  it 'keeps the retrieval identity for child-to-root refs through load and project generation' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'main.yaml')
      original = document.merge('openapi' => '3.1.0', 'components' => { 'schemas' => {
        'Recipient' => { '$id' => 'https://schemas.example/recipient', 'type' => 'string' },
        'Wrapper' => { '$ref' => './wrapper.yaml' }
      } })
      File.write(source, JSON.generate(original))
      File.write(File.join(dir, 'wrapper.yaml'), '{"type":"object","properties":{"recipient":{"$ref":"./main.yaml#/components/schemas/Recipient"}}}')
      loaded = described_class.load(source)
      expect(described_class.resolve(loaded).dig('components', 'schemas', 'Wrapper', 'properties', 'recipient', 'type')).to eq('string')
      project = Paygen::Project.init(source, output: File.join(dir, 'integration'))
      expect(project.effective_document).to eq(loaded)
    end
  end

  it 'makes an HTTPS root self-reference portable without authorizing external fetches' do
    url = 'https://provider.example/openapi.json'
    original = document.merge('openapi' => '3.1.0', 'components' => { 'schemas' => {
      'Recipient' => { 'type' => 'string' },
      'Wrapper' => { 'type' => 'object', 'properties' => {
        'recipient' => { '$ref' => "#{url}#/components/schemas/Recipient" }
      } }
    } })
    allow(Resolv).to receive(:getaddresses).with('provider.example').and_return(['93.184.216.34'])
    stub_request(:get, url).to_return(body: JSON.generate(original))

    imported = described_class.load(url)
    expect(imported.dig('components', 'schemas', 'Wrapper', 'properties', 'recipient', '$ref'))
      .to eq('#/components/schemas/Recipient')
    serialized = JSON.parse(JSON.generate(imported))
    expect(described_class.resolve(serialized).dig('components', 'schemas', 'Wrapper', 'properties', 'recipient', 'type')).to eq('string')

    external = original.dup
    external['components'] = { 'schemas' => { 'Foreign' => { '$ref' => 'https://other.example/schema.json' } } }
    expect { described_class.graph(external, source_uri: url) }.to raise_error(Paygen::Error) do |error|
      expect(error.code).to eq('REF_EXTERNAL_DENIED')
    end
  end

  %w[https://PROVIDER.example/openapi.json https://provider.example:443/unused/../openapi%2Ejson].each do |url|
    it "canonicalizes retrieval identity for local and absolute refs from #{url}" do
      original = document.merge('components' => { 'schemas' => {
        'Value' => { 'type' => 'string' },
        'Local' => { '$ref' => '#/components/schemas/Value' },
        'Absolute' => { '$ref' => 'https://provider.example/openapi.json#/components/schemas/Value' }
      } })
      allow(Resolv).to receive(:getaddresses).with(URI.parse(url).hostname).and_return(['93.184.216.34'])
      stub_request(:get, url).to_return(body: JSON.generate(original))

      imported = described_class.load(url)
      %w[Local Absolute].each do |name|
        expect(imported.dig('components', 'schemas', name, '$ref')).to eq('#/components/schemas/Value')
      end
      expect(WebMock).to have_requested(:get, url).once
    end
  end

  it 'uses the final redirect URL for absolute and relative self-references' do
    url = 'https://provider.example/latest'
    final_url = 'https://cdn.example/v2/openapi.json'
    original = document.merge('components' => { 'schemas' => {
      'Value' => { 'type' => 'string' },
      'Absolute' => { '$ref' => "#{final_url}#/components/schemas/Value" },
      'Relative' => { '$ref' => './openapi.json#/components/schemas/Value' }
    } })
    allow(Resolv).to receive(:getaddresses).with('provider.example').and_return(['93.184.216.34'])
    allow(Resolv).to receive(:getaddresses).with('cdn.example').and_return(['93.184.216.35'])
    stub_request(:get, url).to_return(status: 302, headers: { 'Location' => 'https://cdn.example/current' })
    stub_request(:get, 'https://cdn.example/current').to_return(status: 307, headers: { 'Location' => '/v2/openapi.json' })
    stub_request(:get, final_url).to_return(body: JSON.generate(original))

    imported = described_class.load(url)
    %w[Absolute Relative].each do |name|
      expect(imported.dig('components', 'schemas', name, '$ref')).to eq('#/components/schemas/Value')
    end
    expect(WebMock).to have_requested(:get, url).once
    expect(WebMock).to have_requested(:get, 'https://cdn.example/current').once
    expect(WebMock).to have_requested(:get, final_url).once
  end

  it 'uses one root document for filename and in-directory symlink aliases' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'main.yaml')
      File.symlink(source, File.join(dir, 'alias.yaml'))
      original = document.merge('openapi' => '3.1.0', 'components' => { 'schemas' => {
        'Value' => { '$id' => 'https://schemas.example/value', 'type' => 'string' },
        'Alias' => { '$ref' => './alias.yaml#/components/schemas/Value' }
      } })
      File.write(source, JSON.generate(original))
      resolved = described_class.resolve(described_class.read(source), source_path: source)
      expect(resolved.dig('components', 'schemas', 'Alias', 'type')).to eq('string')
    end
  end

  it 'keeps relative root resource IDs portable when a bundled project moves directories' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'main.yaml')
      original = document.merge('openapi' => '3.1.0', 'components' => { 'schemas' => {
        'Value' => { '$id' => 'value.yaml', 'type' => 'string' },
        'Wrapper' => { '$ref' => './wrapper.yaml' }
      } })
      File.write(source, JSON.generate(original))
      File.write(File.join(dir, 'wrapper.yaml'), '{"type":"object","properties":{"value":{"$ref":"./main.yaml#/components/schemas/Value"}}}')
      project = Paygen::Project.init(source, output: File.join(dir, 'integration'))
      resolved = described_class.resolve(project.effective_document)
      expect(resolved.dig('components', 'schemas', 'Wrapper', 'properties', 'value', 'type')).to eq('string')
      expect(File.read(project.path('source/openapi.json'))).not_to include(dir)
    end
  end

  it 'still rejects duplicate IDs in different documents with identical contents' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'main.yaml')
      original = document.merge('openapi' => '3.1.0', 'components' => { 'schemas' => {
        'Value' => { '$id' => 'https://schemas.example/value', 'type' => 'string' },
        'Duplicate' => { '$ref' => './copy.yaml#/components/schemas/Value' }
      } })
      [source, File.join(dir, 'copy.yaml')].each { |file| File.write(file, JSON.generate(original)) }
      expect { described_class.load(source) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_ID_DUPLICATE') }
    end
  end

  it 'rebases external relative IDs and references when bundling into a portable project' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'main.yaml')
      Dir.mkdir(File.join(dir, 'schemas'))
      original = document.merge('openapi' => '3.1.0', 'components' => { 'schemas' => {
        'Value' => { '$id' => 'value.yaml', 'type' => 'string' },
        'Wrapper' => { '$ref' => './schemas/wrapper.yaml' }
      } })
      File.write(source, JSON.generate(original))
      File.write(File.join(dir, 'schemas', 'wrapper.yaml'), '{"$id":"wrapper.yaml","type":"object","properties":{"value":{"$ref":"../main.yaml#/components/schemas/Value"}}}')
      project = Paygen::Project.init(source, output: File.join(dir, 'integration'))
      resolved = described_class.resolve(project.effective_document)
      expect(resolved.dig('components', 'schemas', 'Wrapper', 'properties', 'value', 'type')).to eq('string')
      expect(File.read(project.path('source/openapi.json'))).not_to include(dir)
    end
  end

  it 'preserves 3.1 schema ref sibling constraints through conjunction' do
    document['openapi'] = '3.1.0'
    document['components'] = { 'schemas' => { 'Base' => { 'type' => 'integer', 'minimum' => 10 }, 'Restricted' => { '$ref' => '#/components/schemas/Base', 'minimum' => 2 } } }
    schema = described_class.resolve(document).dig('components', 'schemas', 'Restricted')
    expect(JSONSchemer.schema(schema).valid?(5)).to be(false)
    expect(JSONSchemer.schema(schema).valid?(10)).to be(true)
  end

  it 'materializes one reused external schema resource across load, serialization and project resolution' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'main.json')
      File.symlink(File.join(dir, 'shared.json'), File.join(dir, 'alias.json'))
      original = document.merge('openapi' => '3.1.0', 'components' => { 'schemas' => {
        'First' => { '$ref' => 'shared.json' }, 'Second' => { '$ref' => 'shared.json' },
        'Alias' => { '$ref' => 'alias.json', 'description' => 'same source resource' }
      } })
      File.write(source, JSON.generate(original))
      File.write(File.join(dir, 'shared.json'), JSON.generate({ '$id' => 'shared.json', 'type' => 'string', 'minLength' => 2 }))
      project = Paygen::Project.init(source, output: File.join(dir, 'project'))
      loaded = described_class.load(source)
      expect(JSON.parse(File.read(project.path('source/openapi.json')))).to eq(loaded)
      expect(loaded.dig('components', 'schemas', 'Second')).to eq('$ref' => 'paygen-local:///source/shared.json')
      resolved = described_class.resolve(JSON.parse(JSON.generate(loaded)))
      expect(resolved.dig('components', 'schemas', 'Second', 'minLength')).to eq(2)
      expect(JSONSchemer.schema(resolved.dig('components', 'schemas', 'Alias')).valid?('a')).to be(false)
      expect(described_class.resolve(project.effective_document).dig('components', 'schemas', 'First', 'minLength')).to eq(2)
    end
  end

  it 'retains reused nested IDs and scoped anchors in an external resource' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'main.json')
      original = document.merge('openapi' => '3.1.0', 'components' => { 'schemas' => {
        'First' => { '$ref' => 'shared.json' }, 'Second' => { '$ref' => 'shared.json' }
      } })
      external = { '$id' => 'shared.json', 'type' => 'object', '$defs' => {
        'Value' => { '$id' => 'value.json', '$anchor' => 'scalar', 'type' => 'string' }
      }, 'properties' => { 'value' => { '$ref' => 'value.json#scalar' } } }
      File.write(source, JSON.generate(original))
      File.write(File.join(dir, 'shared.json'), JSON.generate(external))
      loaded = described_class.load(source)
      resolved = described_class.resolve(JSON.parse(JSON.generate(loaded)))
      expect(resolved.dig('components', 'schemas', 'Second', 'properties', 'value', 'type')).to eq('string')
      expect { described_class.graph(JSON.parse(JSON.generate(loaded))) }.not_to raise_error
    end
  end

  it 'keeps a reused external recursive resource in the import graph but rejects recursive generation' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'main.json')
      original = document.merge('openapi' => '3.1.0', 'components' => { 'schemas' => {
        'First' => { '$ref' => 'shared.json' }, 'Second' => { '$ref' => 'shared.json' }
      } })
      File.write(source, JSON.generate(original))
      File.write(File.join(dir, 'shared.json'), JSON.generate({ '$id' => 'shared.json', 'type' => 'object', 'properties' => { 'next' => { '$ref' => '#' } } }))
      loaded = described_class.load(source)
      expect { described_class.graph(JSON.parse(JSON.generate(loaded))) }.not_to raise_error
      expect { described_class.resolve(loaded) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_CYCLE') }
    end
  end

  it 'does not merge two distinct external documents declaring the same resource ID' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'main.json')
      original = document.merge('openapi' => '3.1.0', 'components' => { 'schemas' => {
        'First' => { '$ref' => 'one.json' }, 'Second' => { '$ref' => 'two.json' }
      } })
      File.write(source, JSON.generate(original))
      %w[one two].each do |name|
        File.write(File.join(dir, "#{name}.json"), JSON.generate({ '$id' => 'https://schema.example/shared', 'type' => 'string' }))
      end
      expect { described_class.load(source) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_ID_DUPLICATE') }
    end
  end

  it 'bundles external refs while preserving editable root pointers' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'defs.yaml'), "type: object\nproperties:\n  id:\n    $ref: '#/$defs/id'\n$defs:\n  id: {type: string}\n")
      original = document.merge('components' => { 'schemas' => { 'External' => { '$ref' => 'defs.yaml' }, 'Alias' => { '$ref' => '#/components/schemas/External' } } })
      bundled = described_class.bundle(original, base_dir: dir)
      expect(bundled.dig('components', 'schemas', 'Alias', '$ref')).to eq('#/components/schemas/External')
      expect(bundled.dig('components', 'schemas', 'External', 'properties', 'id', 'type')).to eq('string')
      expect(described_class.resolve(bundled).dig('components', 'schemas', 'Alias', 'properties', 'id', 'type')).to eq('string')
    end
  end

  it 'keeps example data and dollar-ref property names out of reference traversal' do
    original = document.merge('components' => { 'schemas' => { 'Record' => { 'type' => 'object', 'properties' => { '$ref' => { 'type' => 'string' } }, 'example' => { '$ref' => 'literal user data' } } } })
    expect(described_class.resolve(original)).to eq(original)
  end

  it 'rejects private DNS answers even mixed with public addresses' do
    allow(Resolv).to receive(:getaddresses).with('provider.example').and_return(['93.184.216.34', '127.0.0.1'])
    expect { described_class.public_addresses('provider.example') }.to raise_error(Paygen::Error) { |error| expect(error.exit_code).to eq(5) }
  end

  it 'downloads HTTPS through a validated DNS address and parses the result' do
    allow(Resolv).to receive(:getaddresses).with('provider.example').and_return(['93.184.216.34'])
    stub_request(:get, 'https://provider.example/openapi.json').to_return(body: JSON.generate(document))
    expect(described_class.load('https://provider.example/openapi.json')).to eq(document)
  end

  it 'revalidates redirected destinations and denies private targets' do
    allow(Resolv).to receive(:getaddresses).with('provider.example').and_return(['93.184.216.34'])
    allow(Resolv).to receive(:getaddresses).with('metadata.internal').and_return(['169.254.169.254'])
    stub_request(:get, 'https://provider.example/openapi.json').to_return(status: 302, headers: { 'Location' => 'https://metadata.internal/latest' })
    expect { described_class.load('https://provider.example/openapi.json') }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('SSRF_DENIED') }
    expect(WebMock).not_to have_requested(:get, 'https://metadata.internal/latest')
  end

  it 'does not authorize external refs in a redirected document' do
    url = 'https://provider.example/latest'
    original = document.merge('components' => { 'schemas' => {
      'Foreign' => { '$ref' => 'https://other.example/schema.json' }
    } })
    allow(Resolv).to receive(:getaddresses).with('provider.example').and_return(['93.184.216.34'])
    stub_request(:get, url).to_return(status: 302, headers: { 'Location' => '/openapi.json' })
    stub_request(:get, 'https://provider.example/openapi.json').to_return(body: JSON.generate(original))

    expect { described_class.load(url) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('REF_EXTERNAL_DENIED') }
    expect(WebMock).not_to have_requested(:get, 'https://other.example/schema.json')
  end

  it 'bounds redirect chains while preserving the text-only download API' do
    url = 'https://provider.example/openapi.json'
    allow(Resolv).to receive(:getaddresses).with('provider.example').and_return(['93.184.216.34'])
    stub_request(:get, url).to_return(body: JSON.generate(document))
    expect(described_class.fetch_https(url)).to eq(JSON.generate(document))
    expect(described_class.read(url)).to eq(document)

    stub_request(:get, url).to_return(status: 302, headers: { 'Location' => url })
    expect { described_class.load(url) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('INPUT_REDIRECTS') }
    expect(WebMock).to have_requested(:get, url).times(6)
  end

  it 'rejects unsafe source URLs before a connection is made' do
    %w[http://example.com ftp://example.com https://user:pass@example.com https://example.com:8080 https://example.com/#secret].each do |url|
      expect { described_class.https_uri(url) }.to raise_error(Paygen::Error)
    end
  end
end
