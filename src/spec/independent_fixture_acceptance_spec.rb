# frozen_string_literal: true
require 'spec_helper'

RSpec.describe 'Independent fixture acceptance counterexamples' do
  around do |example|
    Dir.mktmpdir do |root|
      @project = Paygen::Project.init(File.expand_path('../../fixtures/novapay/openapi.yaml', __dir__), output: File.join(root, 'project'))
      example.run
    end
  end

  it 'requires executable positive terminal callbacks, not schema-valid adapter rejection cases' do
    events = @project.profile.fetch('callback').fetch('events').transform_values { 'pending' }
    @project.configure('callback' => { 'events' => events })
    generator = Paygen::Generator.new(@project)
    expect { generator.render }.to raise_error(Paygen::Error) do |error|
      expect(error.code).to eq('SEMANTIC_BLOCKERS')
      expect(error.details.fetch('diagnostics')).to include(hash_including('code' => 'FIXTURE_UNRESOLVED', 'severity' => 'blocker'))
    end
    files = generator.render(draft: true)
    expect(files.keys.grep(/_service\.rb\z/)).to be_empty
    cases = JSON.parse(files.fetch('fixtures.json')).dig('callback', 'cases')
    expect(cases).not_to be_empty
    expect(cases).to all(include('suitability' => 'negative', 'adapter_validation' => include('success' => false)))
    expect(cases.map { |item| item['mapped_operation_status'] }.uniq).to contain_exactly('approved', 'rejected')
  end

  it 'retains an invalid XML example without blocking or selecting it over a supported JSON response' do
    @project.write('overlays/900-mixed.yaml', YAML.dump({
      'overlay' => '1.1.0', 'info' => { 'title' => 'Synthetic alternate response', 'version' => '1' },
      'actions' => [{ 'target' => "$.paths['/payouts'].post.responses['201'].content", 'update' => {
        'application/xml' => { 'schema' => { 'type' => 'string', 'pattern' => '^xml-alternative-not-supported$' },
                               'example' => '<upstream-invalid-payout />' }
      } }]
    }))
    @project.configure(@project.profile)
    expect(@project.ir.diagnostics.select { |item| item['severity'] == 'blocker' }).to be_empty
    files = Paygen::Generator.new(@project).render
    expect(files).to have_key('novapay_service.rb')
    create = JSON.parse(files.fetch('fixtures.json')).fetch('create')
    expect(create['response_201']).to be_a(Hash)
    expect(create['response_201']).to include('status' => 'pending', 'currency' => 'RUB')
    alternate = create.fetch('response_examples').fetch('201').find { |item| item['origin'] == 'openapi-example' && item['content_type'] == 'application/xml' }
    expect(alternate).to include('value' => '<upstream-invalid-payout />', 'suitability' => 'unresolved', 'schema_validation' => include('valid' => false))
    diagnostics = JSON.parse(files.fetch('diagnostics.json')).fetch('diagnostics')
    expect(diagnostics).to include(hash_including('code' => 'FIXTURE_SCHEMA_INVALID', 'severity' => 'warning', 'path' => alternate['source_pointer']))
    expect(diagnostics.none? { |item| item['severity'] == 'blocker' }).to be(true)
  end
end
