# frozen_string_literal: true
require 'spec_helper'
require 'open3'

RSpec.describe 'Validation of effective profile layers' do
  around do |example|
    Dir.mktmpdir do |root|
      @project = Paygen::Project.init(File.expand_path('../../fixtures/novapay/openapi.yaml', __dir__), output: File.join(root, 'project'))
      example.run
    end
  end

  %w[overrides recipe vendor].each do |layer|
    it "validates nested error rules introduced through #{layer}, with a valid control" do
      document = @project.ir.document
      profile = @project.profile
      profile.delete('errors')
      build = lambda do |rule|
        settings = { 'errors' => { '400' => rule } }
        options = { profile: profile }
        if layer == 'vendor'
          document['x-paygen'] = settings
        else
          options[layer.to_sym] = settings
        end
        Paygen::Core::IR.new(document, **options)
      end

      invalid = build.call('validation_error')
      expect(invalid.profile.dig('errors', '400')).to eq('validation_error')
      expect(invalid.diagnostics).to include(hash_including('code' => 'INVALID_PROFILE', 'severity' => 'blocker', 'path' => 'errors.400'))
      expect(Paygen::Core::Onboarding.new(invalid).report['ready']).to be(false)

      valid = build.call('code' => 'validation_error', 'action' => 'reject')
      expect(valid.profile.dig('errors', '400')).to eq('code' => 'validation_error', 'action' => 'reject')
      expect(valid.diagnostics.select { |item| item['severity'] == 'blocker' }).to be_empty
    end
  end

  it 'refuses malformed generate --set before creating a runnable artifact, and accepts a valid replacement' do
    runner = File.expand_path('../run', __dir__)
    _output, error, status = Open3.capture3(runner, 'cli', 'generate', @project.root, '--set', 'errors.400=validation_error')
    expect(status.exitstatus).to eq(4)
    expect(JSON.parse(error).dig('error', 'details', 'diagnostics')).to include(hash_including('code' => 'INVALID_PROFILE', 'path' => 'errors.400'))
    expect(Dir[@project.path('generated/*.rb')]).to be_empty

    output, error, status = Open3.capture3(runner, 'cli', 'generate', @project.root, '--set', 'errors.400={"code":"validation_error"}')
    expect(status.exitstatus).to eq(0), error
    expect(JSON.parse(output)).to include('ready' => true)
    expect(File).to exist(@project.path('generated/novapay_service.rb'))
  end

  it 'leaves unknown optional inferred roles unresolved without treating nil as a malformed operation name' do
    document = @project.ir.document
    profile = @project.profile
    profile['operations']['balance'] = nil
    ir = Paygen::Core::IR.new(document, profile: profile)
    expect(ir.profile.dig('operations', 'balance')).to be_nil
    expect(ir.diagnostics.select { |item| item['code'] == 'INVALID_PROFILE' }).to be_empty
  end
end
