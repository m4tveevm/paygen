# frozen_string_literal: true
require 'spec_helper'
require 'open3'
require 'rbconfig'

RSpec.describe 'CLI process contract' do
  let(:executable) { File.expand_path('../bin/paygen', __dir__) }
  let(:source) { File.expand_path('../fixtures/novapay/openapi.yaml', __dir__) }
  def cli(*arguments, input: '')
    Open3.capture3(RbConfig.ruby, executable, *arguments, stdin_data: input)
  end

  def with_project
    Dir.mktmpdir('paygen-cli-') do |directory|
      project = Paygen::Project.init(source, output: File.join(directory, 'project'))
      yield project, directory
    end
  end

  it 'supports help and reports dependencies' do
    output, _error, status = cli('--help')
    expect(status.exitstatus).to eq(0)
    expect(output).to include('generate', 'verify')
    output, _error, status = cli('doctor')
    expect(status.exitstatus).to eq(0)
    diagnostics = JSON.parse(output)
    expect(diagnostics).to include('paygen' => Paygen::VERSION, 'ruby' => RUBY_VERSION)
    expect(diagnostics.fetch('gems')).to include('dry-cli' => Gem.loaded_specs.fetch('dry-cli').version.to_s)
  end

  it 'exports local HTML documentation and a Bruno collection through the CLI' do
    with_project do |project, directory|
      Paygen::Generator.new(project).generate
      docs = File.join(directory, 'docs')
      collection = File.join(directory, 'bruno')
      [%w[docs] + [project.root, '--format', 'html', '--output', docs],
       %w[collection] + [project.root, '--format', 'bruno', '--output', collection]].each do |arguments|
        _out, error, status = cli(*arguments)
        expect(status.exitstatus).to eq(0), error
      end
      expect(File).to exist(File.join(docs, 'index.html'))
      expect(File).to exist(File.join(docs, 'effective-openapi.json'))
      expect(File).to exist(File.join(collection, 'bruno.json'))
    end
  end

  it 'runs seeded sequences, saves a report and replays a validated trace' do
    with_project do |project, directory|
      Paygen::Generator.new(project).generate
      output = File.join(directory, 'fuzz.json')
      _out, error, status = cli('fuzz', project.root, '--seed', '42', '--cases', '6', '--steps', '8', '--output', output)
      expect(status.exitstatus).to eq(0), error
      report = JSON.parse(File.read(output))
      expect(report).to include('success' => true, 'seed' => 42, 'cases' => 6)
      trace = { 'version' => 1, 'seed' => 42, 'case' => 0, 'mode' => 'normal',
                'profile_sha256' => report.fetch('profile_sha256'),
                'steps' => %w[create retry poll].map { |action| { 'action' => action } } }
      replay = File.join(directory, 'replay.json')
      File.write(replay, JSON.generate(trace))
      result, error, status = cli('fuzz', project.root, '--replay', replay)
      expect(status.exitstatus).to eq(0), error
      expect(JSON.parse(result)).to include('success' => true, 'replay' => true)
      _out, _error, status = cli('fuzz', project.root, '--output', output)
      expect(status.exitstatus).to eq(2)
      expect(JSON.parse(File.read(output))).to eq(report)
    end
  end

  it 'accepts stdin and keeps JSON diagnostics machine-readable' do
    output, error, status = cli('inspect', '-', '--format', 'json', input: File.read(source))
    expect(status.exitstatus).to eq(0), error
    expect(JSON.parse(output).fetch('operations').size).to eq(5)
  end

  it 'returns documented invalid-spec and semantic exit codes' do
    _output, error, status = cli('inspect', '-', input: '{"openapi":"2.0"}')
    expect(status.exitstatus).to eq(3)
    expect(JSON.parse(error).dig('error', 'code')).to eq('OAS_VERSION')
    _output, _error, status = cli('inspect', source, '--strict')
    expect(status.exitstatus).to eq(4)
  end

  it 'runs init generate explain diff and architecture checks end to end' do
    Dir.mktmpdir do |directory|
      project = File.join(directory, 'example')
      [%w[init] + [source, '--output', project], ['generate', project],
       ['diff', project, '--check'], ['explain', project, 'amount'],
       ['architecture-check', project]].each do |arguments|
        output, error, status = cli(*arguments)
        expect(status.exitstatus).to eq(0), "#{arguments}: #{error}"
        expect { JSON.parse(output) }.not_to raise_error
      end
      profile = Paygen::Core::Input.read(File.join(project, 'integration.yml'))
      profile['amount']['minimum'] = 200000
      File.write(File.join(project, 'integration.yml'), YAML.dump(profile))
      _out, _err, status = cli('architecture-check', project)
      expect(status.exitstatus).to eq(1)
    end
  end

  it 'rejects incompatible recipes without changing selected defaults' do
    with_project do |project|
      before = File.read(project.path('recipes/selected.yml'))
      _output, error, status = cli('recipe', 'add', project.root, 'stripe')
      expect(status.exitstatus).to eq(4)
      expect(JSON.parse(error).dig('error', 'code')).to eq('RECIPE_MISMATCH')
      expect(File.read(project.path('recipes/selected.yml'))).to eq(before)
    end
  end

  it 'replaces array contents with ordered remove and parent update actions' do
    with_project do |project|
      output, error, status = cli('patch', 'replace', project.root,
                                 '$.components.schemas.CreatePayoutRequest.properties.currency.enum', '--value', '["USD"]')
      expect(status.exitstatus).to eq(0), error
      expect(JSON.parse(output).fetch('actions').first).to include('remove' => true)
      expect(project.effective_document.dig('components', 'schemas', 'CreatePayoutRequest', 'properties', 'currency', 'enum')).to eq(['USD'])
    end
  end

  it 'copies nodes added by an earlier overlay and rejects an invalid complete result' do
    with_project do |project|
      project.write('overlays/500-created.yaml', YAML.dump({
        'overlay' => '1.1.0', 'info' => { 'title' => 'Previous layer', 'version' => '1' },
        'actions' => [{ 'target' => '$', 'update' => { 'x-audit-source' => { 'x-copied-value' => 1 } } }]
      }))
      _output, error, status = cli('patch', 'copy', project.root, '$.info', '--from', "$['x-audit-source']", '--file', 'overlays/900-copy.yaml')
      expect(status.exitstatus).to eq(0), error
      expect(project.effective_document.dig('info', 'x-copied-value')).to eq(1)
      _output, _error, status = cli('patch', 'replace', project.root, '$.info.version', '--value', '123', '--file', 'overlays/950-invalid.yaml')
      expect(status.exitstatus).to eq(3)
      expect(File).not_to exist(project.path('overlays/950-invalid.yaml'))
    end
  end

  it 'rejects ambiguous replacement and array index shifting explicitly' do
    with_project do |project|
      _output, error, status = cli('patch', 'replace', project.root,
                                  '$.components.schemas.CreatePayoutRequest.properties.currency.enum[0]', '--value', '"USD"')
      expect(status.exitstatus).to eq(2)
      expect(JSON.parse(error).dig('error', 'code')).to eq('PATCH_REPLACE_TARGET')
      expect(File).not_to exist(project.path('overlays/999-user.yaml'))
    end
  end

  it 'protects source and extensions from save-profile writes' do
    with_project do |project|
      project.write('extensions/owned.rb', '# Keep user code')
      before = File.read(project.path('source/openapi.json'))
      %w[extensions/owned.rb source/openapi.json].each do |target|
        _output, error, status = cli('generate', project.root, '--save-profile', target)
        expect(status.exitstatus).to eq(5)
        expect(JSON.parse(error).dig('error', 'code')).to eq('PROFILE_PATH_DENIED')
      end
      expect(File.read(project.path('extensions/owned.rb'))).to eq('# Keep user code')
      expect(File.read(project.path('source/openapi.json'))).to eq(before)
    end
  end

  it 'validates overrides before writing a requested profile' do
    with_project do |project|
      project.write('profiles/review.json', '{"keep":true}')
      _output, _error, status = cli('generate', project.root, '--set', 'class_name=Invalid', '--save-profile', 'profiles/review.json')
      expect(status.exitstatus).to eq(4)
      expect(File.read(project.path('profiles/review.json'))).to eq('{"keep":true}')
    end
  end

  it 'persists a valid JSON profile and preserves the explicit integration source' do
    with_project do |project|
      original = File.read(project.path('integration.yml'))
      _output, error, status = cli('generate', project.root, '--set', 'amount.minimum=200000', '--save-profile', 'profiles/review.json')
      expect(status.exitstatus).to eq(0), error
      expect(JSON.parse(File.read(project.path('profiles/review.json'))).dig('amount', 'minimum')).to eq(200000)
      expect(JSON.parse(File.read(project.path('generated/config.json'))).dig('amount', 'minimum')).to eq(200000)
      expect(File.read(project.path('integration.yml'))).to eq(original)
    end
  end

  it 'requires generated bytes for verification and leaves extensions unexecuted' do
    with_project do |project, directory|
      _output, error, status = cli('verify', project.root)
      expect(status.exitstatus).to eq(1)
      expect(JSON.parse(error).dig('error', 'code')).to eq('GENERATED_DRIFT')
      Paygen::Generator.new(project).generate
      marker = File.join(directory, 'extension-executed')
      project.write('extensions/owned.rb', "File.write(#{marker.dump}, 'executed')\n")
      output, error, status = cli('verify', project.root, '--seed', '42')
      expect(status.exitstatus).to eq(0), error
      expect(JSON.parse(output)).to include('success' => true)
      expect(File).not_to exist(marker)
    end
  end

  it 'rejects changed generated code even if its manifest digest is forged' do
    with_project do |project, directory|
      Paygen::Generator.new(project).generate
      marker = File.join(directory, 'tampered-code-executed')
      path = project.path('generated/novapay_service.rb')
      File.open(path, 'a') { |file| file.write("\nFile.write(#{marker.dump}, 'executed')\n") }
      lock = project.lock
      lock.fetch('generated')['novapay_service.rb'] = Digest::SHA256.file(path).hexdigest
      project.write('paygen.lock', Paygen.json(lock))
      _output, error, status = cli('verify', project.root)
      expect(status.exitstatus).to eq(1)
      expect(JSON.parse(error).dig('error', 'code')).to eq('GENERATED_DRIFT')
      expect(File).not_to exist(marker)
    end
  end

  it 'loads the verified generated source through the isolated reference backend' do
    require 'paygen/cli'
    require 'paygen/runtime/reference_provider'
    with_project do |project|
      Paygen::Generator.new(project).generate
      trusted_bytes = File.binread(project.path('generated/novapay_service.rb'))
      expect(Paygen::Runtime::ReferenceProvider).to receive(:load_service)
        .with(source: trusted_bytes, class_name: 'NovaPayService').and_call_original
      expect { Paygen::CLI::Commands::Verify.new.call(project: project.root, seed: '42') }.to output(/"success": true/).to_stdout
    end
  end
end
