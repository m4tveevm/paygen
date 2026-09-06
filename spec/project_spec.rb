# frozen_string_literal: true
require 'spec_helper'

RSpec.describe 'Project generation lifecycle' do
  let(:source) { File.expand_path('../fixtures/novapay/openapi.yaml', __dir__) }
  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      example.run
    end
  end
  def project
    @project ||= Paygen::Project.init(source, output: File.join(@directory, 'project'))
  end
  def generator = Paygen::Generator.new(project)

  it 'loads Unicode and Ruby-looking configuration as literal data' do
    require 'paygen/runtime/reference_provider'
    description = "Русский текст\nPAYGEN_CONFIGURATION\n" + '#' + '{raise "configuration executed"}' + '\\d+\\path'
    config = project.ir.config.merge('description' => description)
    source = generator.send(:service, config)
    klass = Paygen::Runtime::ReferenceProvider.load_service(source: source.b, class_name: config.fetch('class_name'))
    expect(klass::PAYGEN_CONFIG).to eq(config)
  end

  it 'retains internal refs until overlays correct their shared schema' do
    pinned = Paygen::Core::Input.read(project.path('source/openapi.json'))
    expect(pinned.dig('paths', '/payouts', 'post', 'requestBody', 'content', 'application/json', 'schema')).to have_key('$ref')
    recipient = project.ir.config.dig('endpoints', 'create', 'request_schema', 'properties', 'recipient')
    expect(recipient.fetch('oneOf').map { |branch| branch.fetch('required') }).to eq([['bank_code'], ['card_number']])
  end

  it 'refuses to overwrite generated manual edits and preserves them' do
    generator.generate
    target = project.path('generated/novapay_service.rb')
    File.write(target, '# manual change')
    expect { generator.generate }.to raise_error(Paygen::Error) { |e| expect(e.code).to eq('GENERATED_DRIFT') }
    expect(File.read(target)).to eq('# manual change')
  end

  it 'detects profile and source changes before writing output' do
    generator.generate
    profile = project.profile
    profile['amount']['minimum'] = 200000
    project.write('integration.yml', YAML.dump(profile))
    expect(generator.diff.map { |d| d['path'] }).to include('config.json', 'novapay_service.rb')
    expect(project.lock.fetch('inputs')).not_to eq(project.input_hashes)
  end

  it 'tracks ephemeral overrides without rewriting the explicit profile' do
    original = File.read(project.path('integration.yml'))
    generator.generate(overrides: { 'amount' => { 'minimum' => 200000 } })
    expect(File.read(project.path('integration.yml'))).to eq(original)
    expect(generator.diff).to be_empty
    expect(project.lock.dig('overrides', 'amount', 'minimum')).to eq(200000)
  end

  it 'rejects managed-path traversal and symlink writes' do
    expect { project.write('../outside.txt', 'bad') }.to raise_error(Paygen::Error)
    outside = File.join(@directory, 'outside')
    Dir.mkdir(outside)
    File.symlink(outside, File.join(project.root, 'generated', 'escape'))
    expect { project.write('generated/escape/secret.txt', 'bad') }.to raise_error(Paygen::Error)
    expect(Dir.children(outside)).to be_empty
  end

  it 'writes a diagnostic-only draft for unresolved semantics' do
    profile = project.profile
    profile['operations']['create'] = 'missing_operation'
    project.write('integration.yml', YAML.dump(profile))
    expect { generator.generate }.to raise_error(Paygen::Error) { |e| expect(e.exit_code).to eq(4) }
    generator.generate(draft: true)
    expect(Dir[project.path('generated/*.rb')]).to be_empty
    expect(JSON.parse(File.read(project.path('generated/config.json')))).to include('draft' => true)
  end

  it 'keeps a prior source when update cannot resolve a contract' do
    before = File.read(project.path('source/openapi.json'))
    invalid = File.join(@directory, 'invalid.json')
    File.write(invalid, '{"openapi":"2.0","info":{}}')
    expect { project.update(invalid) }.to raise_error(Paygen::Error)
    expect(File.read(project.path('source/openapi.json'))).to eq(before)
  end

  it 'orders mixed JSON and YAML overlays globally during generation and update' do
    overlay = { 'overlay' => '1.1.0', 'info' => { 'title' => 'Version', 'version' => '1' },
                'actions' => [{ 'target' => '$.info', 'update' => { 'version' => '1.5.0' } }] }
    project.write('overlays/100-a.yaml', YAML.dump(overlay))
    overlay['actions'][0]['update']['version'] = '2.0.0'
    project.write('overlays/900-z.json', JSON.generate(overlay))
    expect(project.effective_document.dig('info', 'version')).to eq('2.0.0')
    source = File.join(@directory, 'updated.json')
    File.write(source, File.read(project.path('source/openapi.json')))
    project.update(source)
    expect(project.effective_document.dig('info', 'version')).to eq('2.0.0')
  end

  context 'replacement source identity' do
    let(:replacement) { File.join(@directory, 'replacement.json') }
    before do
      document = Paygen::Core::Input.read(project.path('source/openapi.json'))
      document['info']['version'] = '2.0.0'
      File.write(replacement, Paygen.json(document))
    end

    def source_overlay(identity)
      { 'overlay' => '1.1.0', 'info' => { 'title' => 'Identity', 'version' => '1' },
        'extends' => identity, 'actions' => [{ 'target' => '$.info', 'update' => { 'description' => 'Reviewed contract' } }] }
    end

    it 'rejects an overlay tied to the old source without changing source or lock' do
      project.write('overlays/900-identity.yaml', YAML.dump(source_overlay(source)))
      before_source = File.read(project.path('source/openapi.json'))
      before_lock = File.read(project.path('paygen.lock'))
      expect { project.update(replacement) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('OVERLAY_EXTENDS') }
      expect(File.read(project.path('source/openapi.json'))).to eq(before_source)
      expect(File.read(project.path('paygen.lock'))).to eq(before_lock)
    end

    it 'accepts the new identity and retains it and its hash through generation' do
      generator.generate
      generated_before = project.lock['generated']
      project.write('overlays/900-identity.yaml', YAML.dump(source_overlay(replacement)))
      result = project.update(replacement)
      expect(result).to include('source_uri' => replacement, 'source_sha256' => Digest::SHA256.file(replacement).hexdigest)
      expect(project.lock).to include(result.slice('source_uri', 'source_sha256'))
      expect(project.lock['generated']).to eq(generated_before)
      expect(project.effective_document.dig('info', 'description')).to eq('Reviewed contract')
      generator.generate
      expect(project.lock).to include(result.slice('source_uri', 'source_sha256'))
      expect(generator.diff).to be_empty
    end

    it 'uses a replacement URL as the persisted identity' do
      url = 'https://contracts.example.test/v2/openapi.json'
      document = Paygen::Core::Input.read(replacement)
      allow(Paygen::Core::Input).to receive(:read).and_call_original
      expect(Paygen::Core::Input).to receive(:read).with(url).and_return(document)
      project.write('overlays/900-identity.yaml', YAML.dump(source_overlay(url)))
      project.update(url)
      expect(project.lock['source_uri']).to eq(url)
      expect(project.effective_document.dig('info', 'version')).to eq('2.0.0')
    end

    it 'restores the source if persisting its new identity fails' do
      before_source = File.read(project.path('source/openapi.json'))
      before_lock = File.read(project.path('paygen.lock'))
      allow(project).to receive(:write).and_call_original
      expect(project).to receive(:write).with('paygen.lock', anything).and_raise(IOError, 'disk full')
      expect { project.update(replacement) }.to raise_error(IOError, 'disk full')
      expect(File.read(project.path('source/openapi.json'))).to eq(before_source)
      expect(File.read(project.path('paygen.lock'))).to eq(before_lock)
    end
  end

  it 'rejects forged manifests attempting to delete user-owned extensions' do
    generator.generate
    project.write('extensions/owned.rb', '# keep')
    lock = project.lock
    lock['generated']['../extensions/owned.rb'] = Digest::SHA256.hexdigest('# keep')
    project.write('paygen.lock', Paygen.json(lock))
    expect { generator.generate }.to raise_error(Paygen::Error) { |e| expect(e.code).to eq('INVALID_LOCK') }
    expect(File.read(project.path('extensions/owned.rb'))).to eq('# keep')
  end

  it 'preserves untracked hidden files by refusing regeneration' do
    generator.generate
    project.write('generated/.review-notes', 'manual review')
    project.write('generated/.notes/private.txt', 'nested review')
    expect(project.generated_drift.map { |entry| entry['path'] }).to include('.review-notes', '.notes/private.txt')
    expect { generator.generate }.to raise_error(Paygen::Error) { |e| expect(e.code).to eq('GENERATED_DRIFT') }
    expect(File.read(project.path('generated/.review-notes'))).to eq('manual review')
    expect(File.read(project.path('generated/.notes/private.txt'))).to eq('nested review')
  end

  it 'rejects malformed profile containers with a domain error even in draft mode' do
    profile = project.profile.merge('amount' => 'invalid')
    project.write('integration.yml', YAML.dump(profile))
    expect { generator.generate(draft: true) }.to raise_error(Paygen::Error) { |e| expect(e.code).to eq('INVALID_PROFILE') }
  end

  it 'exports detached runtime and refuses to merge into existing directories' do
    generator.generate
    project.write('extensions/essential.rb', '# essential hook')
    project.write('extensions/.settings.json', '{"enabled":true}')
    output = File.join(@directory, 'export')
    generator.export(output: output)
    expect(File).to exist(File.join(output, 'novapay_service.rb'))
    expect(File).to exist(File.join(output, 'lib/paygen/runtime/adapter.rb'))
    expect(File).to exist(File.join(output, 'DETACHED.md'))
    expect(File.read(File.join(output, 'extensions/essential.rb'))).to eq('# essential hook')
    expect(File.read(File.join(output, 'extensions/.settings.json'))).to eq('{"enabled":true}')
    expect { generator.export(output: output) }.to raise_error(Paygen::Error)
  end

  it 'loads and executes the detached export without the source repository on its load path' do
    generator.generate
    output = File.join(@directory, 'detached-runtime')
    generator.export(output: output)
    repository = File.expand_path('..', __dir__)
    script = <<~'RUBY'
      require 'json'
      exported, repository = ARGV
      $LOAD_PATH.reject! { |path| File.expand_path(path).start_with?(repository + '/') }
      # Bundler evaluates the source gemspec/version before this script, but no
      # executable runtime/helper from that gem may satisfy the detached load.
      source_runtime = -> { $LOADED_FEATURES.any? { |path| path.start_with?(repository + '/lib/paygen') && !path.end_with?('/paygen/version.rb') } }
      raise 'source runtime was already loaded' if source_runtime.call
      $LOAD_PATH.unshift(File.join(exported, 'lib'))
      module Provider
        class BaseService
          def initialize(**options) = configure_paygen(**options)
        end
      end
      load File.join(exported, 'novapay_service.rb')
      operation = JSON.parse(STDIN.read)
      requests = []
      transport = Object.new
      transport.define_singleton_method(:request) do |**request|
        requests << request
        { status: 201, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('id' => 'detached-1', 'external_id' => operation.fetch('id'),
                              'status' => 'pending', 'amount' => 100000, 'currency' => 'RUB') }
      end
      adapter = Provider::NovaPayService.new(transport: transport, credentials: { api_key: 'synthetic-key' })
      first = adapter.create_request(operation)
      cached = adapter.create_request(operation)
      raise 'source runtime leaked into detached execution' if source_runtime.call
      puts JSON.generate('success' => first['success'] && cached['success'], 'duplicate' => cached['duplicate'],
                         'requests' => requests.length, 'type' => JSON.parse(requests.first.fetch(:body)).dig('recipient', 'type'))
    RUBY
    card = JSON.parse(File.read(File.join(repository, 'fixtures/novapay/fixtures.json'))).fetch('card_operation')
    out, err, status = Open3.capture3(RbConfig.ruby, '-e', script, output, repository,
                                     stdin_data: JSON.generate(card), chdir: output)
    expect(status.success?).to be(true), err
    expect(JSON.parse(out)).to eq('success' => true, 'duplicate' => true, 'requests' => 1, 'type' => 'card')
    # Negative control: a missing exported dependency must not fall back to the
    # original repository or its installed source gem on this machine.
    File.rename(File.join(output, 'lib/paygen/mapping_rule.rb'), File.join(output, 'lib/paygen/mapping_rule.disabled'))
    _out, error, broken = Open3.capture3(RbConfig.ruby, '-e', script, output, repository,
                                        stdin_data: JSON.generate(card), chdir: output)
    expect(broken.success?).to be(false)
    expect(error).to include('cannot load such file', 'mapping_rule')
  end

  it 'rejects invalid workflows before generation or checking drift' do
    generator.generate
    project.write('workflows/payout.arazzo.yaml', 'arazzo: invalid')
    expect { generator.generate }.to raise_error(Paygen::Error)
    expect { generator.diff }.to raise_error(Paygen::Error)
  end

  it 'blocks incomplete monetary and callback semantics' do
    File.delete(project.path('recipes/selected.yml'))
    profile = project.profile.merge('amount' => { 'minimum' => 1 }, 'callback' => { 'signature' => {} })
    project.write('integration.yml', YAML.dump(profile))
    expect(project.ir.diagnostics.map { |d| d['code'] }).to include('AMOUNT_SCALE_REQUIRED', 'SIGNATURE_ALGORITHM_REQUIRED')
    expect { generator.generate }.to raise_error(Paygen::Error) { |e| expect(e.exit_code).to eq(4) }
  end

  it 'emits request fixtures satisfying every shipped create schema' do
    %w[novapay paypal stripe adyen].each do |name|
      source = File.expand_path("../fixtures/#{name}/openapi.yaml", __dir__)
      current = Paygen::Project.init(source, output: File.join(@directory, name))
      data = JSON.parse(Paygen::Generator.new(current).render.fetch('fixtures.json'))
      expect(JSONSchemer.schema(current.ir.config.dig('endpoints', 'create', 'request_schema')).valid?(data.dig('create', 'request'))).to be(true)
    end
  end

  it 'keeps previous output intact after an output destination collision' do
    generator.generate
    before = File.read(project.path('generated/config.json'))
    profile = project.profile.merge('provider' => 'renamed')
    project.write('integration.yml', YAML.dump(profile))
    Dir.mkdir(project.path('generated/renamed_service.rb'))
    expect { generator.generate }.to raise_error(Paygen::Error)
    expect(File.read(project.path('generated/config.json'))).to eq(before)
    expect(project.generated_drift).to be_empty
  end
end
