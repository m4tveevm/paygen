# frozen_string_literal: true
require 'spec_helper'
require 'paygen/collection'

RSpec.describe Paygen::Collection do
  around do |example|
    Dir.mktmpdir('paygen-collection-spec-') do |directory|
      @directory = directory
      example.run
    end
  end

  let(:source) { File.expand_path('../../fixtures/novapay/openapi.yaml', __dir__) }
  let(:project) { Paygen::Project.init(source, output: File.join(@directory, 'project')) }
  let(:output) { File.join(@directory, 'collection') }
  let(:generator) { Paygen::Generator.new(project) }
  let(:collection) { described_class.new(project) }

  def export
    generator.generate
    collection.export(output: output)
  end

  def request_named(name)
    target = Dir[File.join(output, "*-#{name}.bru")].fetch(0)
    File.read(target)
  end

  it 'exports an ordered application collection and the matching generated fixtures' do
    result = export
    expect(result).to include('status' => 'exported', 'format' => 'bruno', 'path' => output)
    expect(JSON.parse(File.read(File.join(output, 'bruno.json')))).to include('type' => 'collection')
    expect(File.read(File.join(output, 'fixtures.json'))).to eq(File.read(project.path('generated/fixtures.json')))
    expect(File.read(File.join(output, 'environments/local.bru'))).to include('http://127.0.0.1:9293')
    requests = Dir[File.join(output, '[0-9]*.bru')].map { |path| File.read(path) }
    expect(requests.map { |body| body.match(/seq: (\d+)/)[1].to_i }).to eq((1..requests.length).to_a)
    expect(requests.all? { |body| body.include?('url: {{baseUrl}}/') && body.include?('tests {') }).to be(true)
    expect(request_named('create-operation')).to include('req.setBody(operation)')
    expect(request_named('retry-same-operation')).to include('/operations/{{operationId}}/retry')
    expect(request_named('cancel-before-settlement')).to include('/operations/{{operationId}}-c/cancel')
    expect(request_named('reject-invalid-provider-credentials')).to include('req.setBody(operation)', '.error.http_status).to.equal(401)')
    expect(request_named('final-evidence')).to include('created_count', 'backend_events', '.to.equal(2)')
  end

  it 'uses exact signed callback bytes and rejects invalid and duplicate deliveries' do
    export
    expect(request_named('obtain-signed-local-callback')).to include('event.raw_body', 'event.headers')
    expect(request_named('apply-signed-callback')).to include('body: text', 'req.setBody(event.raw_body)', 'req.setHeader(name, value)')
    expect(request_named('reject-invalid-callback-signature')).to include('"intentionally-invalid"', '.error.code).to.equal("invalid_signature")')
    expect(request_named('ignore-duplicate-callback')).to include('.ignored).to.equal("duplicate")')
    expect(request_named('final-evidence')).to include('initialBackendEvents', '.to.equal(1)')
  end

  it 'keeps schema example strings as inert JSON through Bruno interpolation' do
    malicious = "\"; }\nscript:pre-request { throw new Error('injected'); }\n{{baseUrl}} Пример"
    document = Paygen::Core::Input.read(project.path('source/openapi.json'))
    document['components']['schemas']['CreatePayoutRequest']['properties']['memo'] = { 'type' => 'string', 'example' => malicious }
    project.write('source/openapi.json', Paygen.json(document))
    profile = project.profile
    profile['request_mapping']['memo'] = { 'from' => 'memo' }
    project.write('integration.yml', YAML.dump(profile))
    project.configure(profile) # Explicitly review the authored source and profile together.
    export
    request = request_named('create-operation')
    expression = request.lines.find { |line| line.include?('const operation = ') }.strip.delete_prefix('const operation = ').delete_suffix(';')
    literal = expression.delete_prefix('JSON.parse(').delete_suffix(')')
    expect(literal).not_to include('{{', "\n", 'script:pre-request {')
    expect(JSON.parse(JSON.parse(literal)).fetch('memo')).to eq(malicious)
    expect(request.scan(/^script:pre-request \{/).length).to eq(1)
  end

  it 'uses generated override values without changing the profile' do
    generator.generate(overrides: { 'amount' => { 'minimum' => 250000 } })
    collection.export(output: output)
    request = request_named('create-operation')
    expression = request.lines.find { |line| line.include?('const operation = ') }.strip.delete_prefix('const operation = ').delete_suffix(';')
    sample = JSON.parse(JSON.parse(expression.delete_prefix('JSON.parse(').delete_suffix(')')))
    expect(sample.fetch('amount')).to eq('2500.0')
    expect(project.profile.dig('amount', 'minimum')).to eq(100000)
    metadata = JSON.parse(File.read(File.join(output, 'paygen-collection.json')))
    expect(metadata['config_sha256']).to eq(Digest::SHA256.hexdigest(File.read(project.path('generated/config.json'))))
  end

  it 'generates the same collection bytes twice and changes no project files' do
    generator.generate
    before = project.input_hashes
    first = collection.export(output: output)
    second_path = File.join(@directory, 'second')
    second = collection.export(output: second_path)
    expect(first['files']).to eq(second['files'])
    expect(first['files'].all? { |name| File.binread(File.join(output, name)) == File.binread(File.join(second_path, name)) }).to be(true)
    expect(project.input_hashes).to eq(before)
    expect(generator.diff).to be_empty
  end

  it 'omits callback verification rather than claiming to implement a provider-side hook' do
    profile = project.profile
    profile['callback']['signature']['algorithm'] = 'provider_verification'
    project.write('integration.yml', YAML.dump(profile))
    export
    expect(Dir[File.join(output, '*callback*.bru')]).to be_empty
    expect(JSON.parse(File.read(File.join(output, 'paygen-collection.json')))['callback_checks']).to be(false)
    expect(File.read(File.join(output, 'README.md'))).to include('Provider-side verification hooks require a separate application implementation')
  end

  it 'omits optional status, cancel, callback and credential checks when not configured' do
    profile = project.profile
    profile['operations'] = { 'create' => 'createPayout', 'status' => nil, 'cancel' => nil, 'balance' => nil, 'callback' => nil }
    profile['auth'] = { 'type' => 'none' }
    profile.delete('callback')
    project.write('integration.yml', YAML.dump(profile))
    # The no-auth profile must match the operation contract explicitly.
    document = Paygen::Core::Input.read(project.path('source/openapi.json'))
    document.delete('security')
    document['paths']['/payouts']['post']['security'] = []
    project.write('source/openapi.json', Paygen.json(document))
    project.configure(profile) # Confirm the replacement no-auth contract.
    export
    expect(Dir[File.join(output, '*cancel*.bru')]).to be_empty
    expect(Dir[File.join(output, '*callback*.bru')]).to be_empty
    expect(Dir[File.join(output, '*credentials*.bru')]).to be_empty
    expect(request_named('final-evidence')).to include('.to.equal(1)', '.to.equal(0)')
  end

  it 'requires a fresh generated project and preserves a manually edited file' do
    generator.generate
    target = project.path('generated/config.json')
    File.write(target, '{}')
    expect { collection.export(output: output) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('GENERATED_DRIFT') }
    expect(File.read(target)).to eq('{}')
    expect(File.exist?(output)).to be(false)
  end

  it 'refuses stale input semantics even when generated files are untouched' do
    generator.generate
    profile = project.profile
    profile['amount']['minimum'] += 100
    project.write('integration.yml', YAML.dump(profile))
    expect { collection.export(output: output) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('GENERATED_DRIFT') }
    expect(File.exist?(output)).to be(false)
  end

  it 'refuses a diagnostic-only draft' do
    profile = project.profile
    profile['operations']['create'] = 'unknown'
    project.write('integration.yml', YAML.dump(profile))
    generator.generate(draft: true)
    expect { collection.export(output: output) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('SEMANTIC_BLOCKERS') }
  end

  it 'refuses overwrite without changing the destination' do
    export
    File.write(File.join(output, 'owned.txt'), 'keep')
    expect { collection.export(output: output) }.to raise_error(Paygen::Error, /already exists/)
    expect(File.read(File.join(output, 'owned.txt'))).to eq('keep')
  end

  it 'refuses destinations inside the project, including symlink aliases' do
    generator.generate
    expect { collection.export(output: project.path('user-collection')) }.to raise_error(Paygen::Error, /inside the project/)
    File.symlink(project.root, File.join(@directory, 'alias'))
    expect { collection.export(output: File.join(@directory, 'alias', 'new', 'collection')) }.to raise_error(Paygen::Error, /inside the project/)
    expect(File.exist?(project.path('new'))).to be(false)
  end

  it 'rejects a dangling destination symlink and unsupported formats' do
    generator.generate
    File.symlink(File.join(@directory, 'missing'), output)
    expect { collection.export(output: output) }.to raise_error(Paygen::Error, /already exists/)
    expect { collection.export(output: output, format: 'javascript') }.to raise_error(Paygen::Error, /format must be bruno/)
  end

  it 'leaves no partial output when writing a bundle fails' do
    generator.generate
    allow(File).to receive(:write).and_call_original
    allow(File).to receive(:write).with(a_string_ending_with('/bruno.json'), anything).and_raise(IOError, 'disk full')
    expect { collection.export(output: output) }.to raise_error(IOError, 'disk full')
    expect(File.exist?(output)).to be(false)
    expect(Dir[File.join(@directory, '.paygen-collection-*')]).to be_empty
  end
end
