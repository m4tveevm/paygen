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

  it 'retains internal refs until overlays correct their shared schema' do
    pinned = Paygen::Core::Input.read(project.path('source/openapi.json'))
    expect(pinned.dig('paths', '/payouts', 'post', 'requestBody', 'content', 'application/json', 'schema')).to have_key('$ref')
    expect(project.ir.config.dig('endpoints', 'create', 'request_schema', 'properties', 'recipient', 'required')).to include('bank_code')
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
