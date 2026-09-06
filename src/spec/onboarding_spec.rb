# frozen_string_literal: true
require 'spec_helper'
require 'open3'
require 'rbconfig'

RSpec.describe 'Unfamiliar API onboarding' do
  let(:source) { File.expand_path('../../fixtures/novapay/openapi.yaml', __dir__) }

  it 'retains a full recursive source while resolving only the selected operations' do
    document = Paygen::Core::Input.read(source)
    document['info']['title'] = 'Independent Payments'
    document['components']['schemas']['UnrelatedTree'] = {
      'type' => 'object', 'properties' => { 'child' => { '$ref' => '#/components/schemas/UnrelatedTree' } }
    }
    graph = Paygen::Core::Input.graph(document)
    profile = Paygen::Core::Input.read(File.expand_path('../recipes/novapay.yml', __dir__)).fetch('profile')
    ir = Paygen::Core::IR.new(graph, profile: profile)
    expect(ir.diagnostics).to be_empty
    expect(ir.config.dig('endpoints', 'create', 'request_schema')).to have_key('properties')
    expect(graph).to eq(document)
  end

  it 'discovers nested OpenAPI callbacks and excludes them from outgoing candidates' do
    document = Paygen::Core::Input.read(source)
    callback = document['paths'].delete('/webhooks/payout')
    callback ||= document['paths'].values.find { |item| item.dig('post', 'operationId') == 'payoutWebhook' }
    document['paths'].delete_if { |_path, item| item.dig('post', 'operationId') == 'payoutWebhook' }
    document['paths']['/payouts']['post']['callbacks'] = { 'payout' => { '{$request.body#/callback_url}' => callback } }
    ir = Paygen::Core::IR.new(document)
    incoming = ir.operations.find { |op| op['operation_id'] == 'payoutWebhook' }
    expect(incoming).to include('inbound' => true)
    expect(incoming['source_pointer']).to include('/callbacks/')
    expect(ir.candidates['callback'].map { |op| op['operation_id'] }).to include('payoutWebhook')
    expect(ir.candidates['create'].map { |op| op['operation_id'] }).not_to include('payoutWebhook')
  end

  it 'reports evidence without inferring settlement or monetary units from names' do
    document = Paygen::Core::Input.read(source)
    document['info']['title'] = 'Acme Payments'
    ir = Paygen::Core::IR.new(document)
    report = Paygen::Core::Onboarding.new(ir).report
    expect(report['ready']).to be(false)
    expect(report['candidates']['create'].first).to include('review_required' => true)
    expect(report['candidates']['create'].first['evidence']).to include('operationId')
    expect(report['profile']).not_to have_key('status_mapping')
    expect(report['profile']).not_to have_key('amount')
    expect(report['questions'].find { |q| q['path'] == 'operations' }).to include('review_required' => true)
  end

  it 'reports selected unsupported query serialization before generation' do
    document = Paygen::Core::Input.read(source)
    document['paths']['/payouts']['post']['parameters'] = [
      { 'name' => 'filter', 'in' => 'query', 'style' => 'deepObject', 'schema' => { 'type' => 'object' } }
    ]
    ir = Paygen::Core::IR.new(document)
    expect(ir.diagnostics.map { |item| item['code'] }).to include('PARAMETER_UNSUPPORTED')
  end

  it 'rejects malformed nested parameter and credential rules before declaring readiness' do
    document = Paygen::Core::Input.read(source)
    [{ 'parameter_mapping' => { 'status' => 'oops' } },
     { 'auth' => { 'headers' => { 'X-Test' => [] } } },
     { 'auth' => { 'headers' => { 'X-Test' => { 'credential' => [] } } } }].each do |profile|
      expect { Paygen::Core::IR.new(document, profile: profile) }.to raise_error(Paygen::Error) { |error|
        expect(error.code).to eq('INVALID_PROFILE')
      }
    end
  end

  it 'keeps outgoing webhook administration methods as candidates without declaring an inbound receiver' do
    document = Paygen::Core::Input.read(source)
    document['paths']['/webhooks/{id}/retries'] = { 'post' => { 'operationId' => 'retryWebhook', 'responses' => {} } }
    ir = Paygen::Core::IR.new(document)
    expect(ir.profile['operations']).not_to have_key('callback')
    expect(ir.candidates['callback'].map { |op| op['operation_id'] }).to include('retryWebhook')
  end

  it 'never persists inferred payment decisions as operator answers and blocks partial approval' do
    fixture = File.expand_path('../../fixtures/onboarding/ambiguous', __dir__)
    Dir.mktmpdir do |directory|
      project = Paygen::Project.init(File.join(fixture, 'openapi.json'), output: File.join(directory, 'project'))
      saved = Paygen::Core::Input.read(project.path('integration.yml'))
      expect(saved.keys & %w[operations auth]).to be_empty
      expect(saved['provider']).to eq('training_payout_api')
      before = File.binread(project.path('source/openapi.json'))
      partial = Paygen::Core::Input.read(File.join(fixture, 'partial-answers.yml'))
      File.write(project.path('integration.yml'), YAML.dump(partial))
      report = Paygen::Core::Onboarding.new(project.ir).report
      expect(report['ready']).to be(false)
      expect(report['questions'].find { |q| q['path'] == 'operations' }['review_required']).to be(true)
      expect(report['questions'].find { |q| q['path'] == 'auth' }['review_required']).to be(true)
      expect { Paygen::Generator.new(project).generate }.to raise_error(Paygen::Error) { |e| expect(e.exit_code).to eq(4) }
      Paygen::Generator.new(project).generate(draft: true)
      expect(Dir[project.path('generated/*_service.rb')]).to be_empty
      %w[verify demo serve].each do |command|
        _out, err, status = Open3.capture3(RbConfig.ruby, File.expand_path('../bin/paygen', __dir__), command, project.root)
        expect(status.exitstatus).to eq(4), err
        expect(err).to include('SEMANTIC_BLOCKERS')
      end
      answers = Paygen::Core::Input.read(File.join(fixture, 'answers.yml'))
      # Approving only create still leaves inferred status/auth settings blocked.
      File.write(project.path('integration.yml'), YAML.dump(partial.merge('operations' => { 'create' => 'createPayout' })))
      expect(project.ir.diagnostics.map { |d| d['path'] }).to include('operations.status', 'auth.type')
      File.write(project.path('integration.yml'), YAML.dump(answers))
      expect(Paygen::Core::Onboarding.new(project.ir).report['ready']).to be(true)
      expect(Paygen::Generator.new(project).generate['files']).to include('training_service.rb')
      expect(File.binread(project.path('source/openapi.json'))).to eq(before)
    end
  end

  it 'applies explicit answers through the CLI and retains the pinned unknown source' do
    Dir.mktmpdir do |directory|
      native = Paygen::Core::Input.read(source)
      native['info']['title'] = 'Acme Payments'
      input = File.join(directory, 'source.json')
      File.write(input, Paygen.json(native))
      project = Paygen::Project.init(input, output: File.join(directory, 'project'))
      before = File.binread(project.path('source/openapi.json'))
      answers = File.join(directory, 'answers.yml')
      recipe = Paygen::Core::Input.read(File.expand_path('../recipes/novapay.yml', __dir__))
      File.write(answers, YAML.dump(recipe.fetch('profile').merge('provider' => 'acme', 'class_name' => 'AcmeService')))
      out, err, status = Open3.capture3(RbConfig.ruby, File.expand_path('../bin/paygen', __dir__),
                                       'configure', project.root, '--answers', answers)
      expect(status.exitstatus).to eq(0), err
      expect(JSON.parse(out)).to include('ready' => true)
      expect(File.binread(project.path('source/openapi.json'))).to eq(before)
      expect(project.ir.provenance.dig('amount.scale', 'origin')).to eq('integration-profile')
      expect(Paygen::Generator.new(project).generate['files']).to include('acme_service.rb')
    end
  end
end
