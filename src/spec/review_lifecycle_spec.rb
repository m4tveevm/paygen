# frozen_string_literal: true
require 'spec_helper'

RSpec.describe 'Persistent integration decision review' do
  let(:novapay) { File.expand_path('../../fixtures/novapay/openapi.yaml', __dir__) }
  let(:paystack) { File.expand_path('../../fixtures/native-paystack/openapi.yaml', __dir__) }

  def with_project(source = novapay, **options)
    Dir.mktmpdir do |directory|
      yield Paygen::Project.init(source, output: File.join(directory, 'project'), **options)
    end
  end

  def pending_paths(project)
    project.ir.provenance.select { |_, fact| fact['review_required'] }.keys
  end

  def change_source(project)
    document = Paygen::Core::Input.read(project.path('source/openapi.json'))
    yield document
    project.write('source/openapi.json', Paygen.json(document))
  end

  it 'keeps untouched native Paystack suggestions inferred through repeated loads and partial answers' do
    with_project(paystack) do |project|
      2.times do
        ir = Paygen::Project.new(project.root).ir
        question = Paygen::Core::Onboarding.new(ir).report['questions'].find { |item| item['path'] == 'operations' }
        expect(question).to include('origins' => ['inference'], 'review_required' => true)
        expect(ir.provenance.dig('operations.create', 'review_state')).to eq('inferred')
      end
      project.configure('provider' => 'paystack_custom')
      expect(pending_paths(project)).to include('operations.create', 'auth.type')
      project.configure('operations' => { 'create' => project.ir.profile.dig('operations', 'create') })
      expect(pending_paths(project)).not_to include('operations.create')
      expect(pending_paths(project)).to include('auth.type')
    end
  end

  it 'retains explicit fixture decisions across init, generation, reload and deterministic regeneration' do
    with_project do |project|
      expect(pending_paths(project)).to be_empty
      first = Paygen::Generator.new(project).render
      Paygen::Generator.new(project).generate
      expect(Paygen::Generator.new(Paygen::Project.new(project.root)).render).to eq(first)
      expect(project.input_hashes).to have_key('review.json')
      expect(project.ir.provenance.dig('amount.scale', 'review_state')).to eq('confirmed')
    end
  end

  it 'accepts manual YAML values without treating unrelated edits as blanket confirmation' do
    with_project(paystack) do |project|
      profile = project.profile.merge('operations' => { 'create' => project.ir.profile.dig('operations', 'create') })
      project.write('integration.yml', YAML.dump(profile))
      expect(project.ir.provenance.dig('operations.create', 'review_state')).to eq('explicit-edit')
      expect(pending_paths(project)).to include('auth.type')
      expect(Paygen::Project.new(project.root).ir.provenance.dig('operations.create', 'review_state')).to eq('explicit-edit')
    end
  end

  it 'invalidates changed create constraints but preserves independent callback and status decisions' do
    with_project do |project|
      change_source(project) do |document|
        document['paths']['/payouts']['post']['requestBody']['required'] = false
      end
      expect(pending_paths(project)).to include('operations.create', 'amount.scale')
      expect(pending_paths(project)).not_to include('operations.status', 'callback.signature.algorithm', 'auth.type')
      expect { Paygen::Generator.new(project).generate }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('SEMANTIC_BLOCKERS') }
      project.configure('operations' => { 'create' => 'createPayout' })
      expect(pending_paths(project)).not_to include('operations.create')
      expect(pending_paths(project)).to include('amount.scale')
      project.configure(project.profile)
      expect(pending_paths(project)).to be_empty
    end
  end

  it 'does not reset review when title, unrelated endpoints or unreferenced security schemes change' do
    with_project do |project|
      change_source(project) do |document|
        document['info']['title'] = 'New display title'
        document['paths']['/health'] = { 'get' => { 'operationId' => 'health', 'responses' => { '200' => { 'description' => 'Healthy' } } } }
        document['components']['securitySchemes']['Unrelated'] = { 'type' => 'apiKey', 'in' => 'header', 'name' => 'Unused' }
      end
      expect(pending_paths(project)).to be_empty
    end
  end

  it 'invalidates dependent mappings when a manually selected operation changes' do
    with_project do |project|
      project.write('integration.yml', YAML.dump(project.profile.merge('operations' => project.profile['operations'].merge('create' => 'getPayout'))))
      expect(pending_paths(project)).to include('request_mapping.amount.from', 'amount.scale')
    end
  end

  it 'does not upgrade legacy saved guesses by loading, renaming or confirming one setting' do
    with_project do |project|
      File.unlink(project.path('review.json'))
      expect(pending_paths(project)).to include('operations.create', 'auth.type', 'amount.scale')
      project.configure('provider' => 'renamed')
      expect(pending_paths(project)).to include('operations.create', 'auth.type', 'amount.scale')
      project.configure('operations' => { 'create' => 'createPayout' })
      expect(pending_paths(project)).not_to include('operations.create')
      expect(pending_paths(project)).to include('auth.type', 'amount.scale')
      project.configure(project.profile)
      expect(pending_paths(project)).to be_empty
      expect(Paygen::Generator.new(project).render.keys).to include('renamed_service.rb')
    end
  end

  it 'invalidates authentication when its security scheme changes, without guessing a new credential' do
    with_project do |project|
      change_source(project) do |document|
        scheme = document['components']['securitySchemes'].values.first
        scheme['name'] = 'X-Changed-Key'
      end
      expect(pending_paths(project)).to include('auth.type', 'auth.name')
      expect(project.ir.provenance.dig('auth.name', 'review_state')).to eq('stale')
    end
  end

  it 'preserves stale state through source update, reload and unrelated configuration' do
    with_project do |project|
      document = Paygen::Core::Input.read(novapay)
      document['paths']['/payouts']['post']['description'] = 'Revised payment conditions require review.'
      replacement = File.join(File.dirname(project.root), 'replacement.json')
      File.write(replacement, Paygen.json(document))
      project.update(replacement)
      project.configure('provider' => 'renamed')
      reloaded = Paygen::Project.new(project.root)
      expect(pending_paths(reloaded)).to include('operations.create', 'amount.scale')
      expect(pending_paths(reloaded)).not_to include('operations.status', 'auth.type')
    end
  end

  it 'rejects malformed review evidence with a controlled diagnostic' do
    with_project do |project|
      state = project.review_state
      state['decisions']['auth.type'] = 'confirmed'
      project.write('review.json', Paygen.json(state))
      expect { project.ir }.to raise_error(Paygen::Error) do |error|
        expect(error.code).to eq('INVALID_REVIEW')
        expect(error.details).to include('path' => 'review.decisions.auth.type')
      end
    end
  end

  it 'keeps review metadata read-only and excludes raw configured secrets from it' do
    with_project do |project|
      before = File.binread(project.path('review.json'))
      project.ir
      expect(File.binread(project.path('review.json'))).to eq(before)
      expect(JSON.parse(before)['decisions']['auth.credential'].keys).to contain_exactly('value_sha256', 'dependency_sha256')
    end
  end
end
