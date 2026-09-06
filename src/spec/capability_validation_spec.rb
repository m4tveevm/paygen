# frozen_string_literal: true
require 'spec_helper'
require 'paygen/runtime/reference_provider'
require 'open3'

RSpec.describe 'Contract capabilities and nested profile validation' do
  let(:source) { File.expand_path('../../fixtures/novapay/openapi.yaml', __dir__) }
  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @project = Paygen::Project.init(source, output: File.join(directory, 'project'))
      example.run
    end
  end
  let(:document) { Paygen::Core::Input.read(@project.path('source/openapi.json')) }
  let(:profile) { @project.profile }
  def ir = Paygen::Core::IR.new(document, profile: profile)
  def blockers(value = ir) = value.diagnostics.select { |item| item['severity'] == 'blocker' }
  def change_media(media)
    request = document['paths']['/payouts']['post']['requestBody']
    request['content'] = { media => request['content'].fetch('application/json') }
  end
  def persisted
    @project.write('source/openapi.json', Paygen.json(document))
    @project.write('integration.yml', YAML.dump(profile))
    # Exercise the complete explicit profile, without recipe defaults filling deleted fields.
    selected = Paygen::Core::Input.read(@project.path('recipes/selected.yml'))
    @project.write('recipes/selected.yml', YAML.dump(selected.merge('profile' => {})))
    @project
  end

  %w[application/xml multipart/form-data].each do |media|
    it "rejects #{media} before emitting a service and reports the source location" do
      change_media(media)
      expect(blockers).to include(hash_including('code' => 'MEDIA_TYPE_UNSUPPORTED', 'path' => '/paths/~1payouts/post/requestBody/content'))
      expect { Paygen::Generator.new(persisted).generate }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('SEMANTIC_BLOCKERS') }
      expect(Dir[@project.path('generated/*.rb')]).to be_empty
      expect(Paygen::Core::Onboarding.new(@project.ir).report['ready']).to be(false)
    end
  end

  it 'chooses JSON before form independently of media declaration order and ignores adjacent XML' do
    request = document['paths']['/payouts']['post']['requestBody']
    schema = request['content']['application/json']
    request['content'] = { 'application/xml' => schema, 'application/x-www-form-urlencoded' => schema, 'application/json' => schema }
    expect(blockers).to be_empty
    expect(ir.config.dig('endpoints', 'create', 'content_type')).to eq('application/json')
    profile['request_encoding'] = 'form'
    expect(blockers).to be_empty
    expect(ir.config.dig('endpoints', 'create', 'content_type')).to eq('application/x-www-form-urlencoded')
  end

  it 'reports an unsupported unselected operation as a warning without blocking the selected plan' do
    document['paths']['/xml-only'] = { 'post' => { 'operationId' => 'unselectedXml', 'security' => [], 'responses' => {},
      'requestBody' => { 'content' => { 'application/xml' => { 'schema' => { 'type' => 'string' } } } } } }
    expect(blockers).to be_empty
    expect(ir.diagnostics).to include(hash_including('code' => 'MEDIA_TYPE_UNSUPPORTED', 'severity' => 'warning', 'path' => '/paths/~1xml-only/post/requestBody/content'))
  end

  it 'rejects non-JSON response contracts and accepts an adjacent JSON representation' do
    response = document['paths']['/payouts']['post']['responses']['201']
    schema = response['content'].fetch('application/json')
    response['content'] = { 'application/xml' => schema }
    expect(blockers).to include(hash_including('code' => 'RESPONSE_MEDIA_TYPE_UNSUPPORTED'))
    response['content']['application/json'] = schema
    expect(blockers).to be_empty
  end

  it 'retains prior artifacts while explicitly reporting that a failed regeneration did not update them' do
    generator = Paygen::Generator.new(@project)
    generator.generate
    previous = File.binread(@project.path('generated/novapay_service.rb'))
    change_media('application/xml')
    persisted
    expect { generator.generate }.to raise_error(Paygen::Error) do |error|
      expect(error.code).to eq('SEMANTIC_BLOCKERS')
      expect(error.details['previous_artifacts']).to eq('stale; generation not updated')
    end
    expect(File.binread(@project.path('generated/novapay_service.rb'))).to eq(previous)
  end

  it 'rejects a codec override that does not exist in the selected contract' do
    profile['request_encoding'] = 'form'
    expect(blockers).to include(hash_including('code' => 'MEDIA_TYPE_UNSUPPORTED'))
  end

  it 'rejects API key cookie auth at IR/configure/generation, before transport exists' do
    document['components']['securitySchemes'].values.first['in'] = 'cookie'
    profile['auth']['in'] = 'cookie'
    expect(blockers).to include(hash_including('code' => 'AUTH_LOCATION_UNSUPPORTED', 'path' => 'auth.in'))
    expect { Paygen::Generator.new(persisted).render }.to raise_error(Paygen::Error) { |error| expect(error.exit_code).to eq(4) }
  end

  it 'requires the correct named API key scheme and complete AND requirements while accepting OR alternatives' do
    security = document['paths']['/payouts']['post']
    name = document['components']['securitySchemes'].keys.first
    document['components']['securitySchemes']['Other'] = { 'type' => 'http', 'scheme' => 'basic' }
    security['security'] = [{ name => [], 'Other' => [] }]
    expect(blockers).to include(hash_including('code' => 'SECURITY_REQUIREMENT_UNSUPPORTED'))
    security['security'] = [{ 'Other' => [] }, { name => [] }]
    expect(blockers).to be_empty
    profile['auth']['name'] = 'Wrong-Key'
    expect(blockers).to include(hash_including('code' => 'SECURITY_REQUIREMENT_UNSUPPORTED'))
  end

  it 'requires all OAuth scopes of each selected operation without confusing bearer transport and authorization' do
    document['components']['securitySchemes'] = { 'OAuth' => { 'type' => 'oauth2', 'flows' => {
      'clientCredentials' => { 'tokenUrl' => 'https://example.test/token', 'scopes' => { 'payouts:write' => 'Create' } }
    } } }
    document['security'] = [{ 'OAuth' => ['payouts:write'] }]
    document['paths'].each_value do |item|
      item.each_value { |operation| operation.delete('security') if operation.is_a?(Hash) }
    end
    profile['auth'] = { 'type' => 'oauth2', 'credential' => 'token', 'scopes' => [] }
    expect(blockers).to include(hash_including('code' => 'SECURITY_REQUIREMENT_UNSUPPORTED'))
    profile['auth']['scopes'] = ['payouts:write']
    expect(blockers).to be_empty
  end

  it 'honors explicit anonymous operation overrides and anonymous OR alternatives' do
    document['paths'].each_value do |item|
      item.each_value { |operation| operation['security'] = [] if operation.is_a?(Hash) && operation.key?('responses') }
    end
    profile['auth'] = { 'type' => 'none' }
    expect(blockers).to be_empty
    document['paths']['/payouts']['post']['security'] = [{ 'MissingScheme' => [] }, {}]
    expect(blockers).to be_empty
    document['paths']['/payouts']['post']['security'] = [{ 'MissingScheme' => [] }]
    expect(blockers).to include(hash_including('code' => 'AUTH_REQUIRED'))
  end

  {
    'errors.400' => 'validation_error',
    'errors.401' => {},
    'errors.402.action' => 'ignore',
    'errors.roles.create.409' => false,
    'errors.roles.cancel.409.code' => [],
    'response.id' => [],
    'response.roles.status.status' => 123,
    'callback.signature.encoding' => 'rot13',
    'callback.signature.algorithm' => 'unimplemented',
    'callback.signature.credentials' => [],
    'callback.signature.tolerance' => '300',
    'callback.timestamp' => {},
    'operations.create' => 123,
    'auth.scopes' => 'secret-scopes-must-not-appear',
    'status_order' => 'pending',
    'status_transitions.pending' => true,
    'mode_values' => [],
    'response.roles.status.scope' => 'all',
    'action_mapping.sbp' => 'callback'
  }.each do |path, value|
    it "diagnoses #{path} safely before generating executable code" do
      keys = path.split('.')
      container = keys[0...-1].reduce(profile) { |memo, key| memo[key] ||= {} }
      container[keys.last] = value
      expect(blockers).to include(hash_including('code' => 'INVALID_PROFILE', 'path' => path))
      expect(Paygen.json(blockers)).not_to include('secret-scopes-must-not-appear')
      expect { Paygen::Generator.new(persisted).render }.to raise_error(Paygen::Error)
    end
  end

  it 'allows supported shared/role error overrides, response paths, rotation and host action aliases' do
    profile['errors']['400'] = { 'code' => 'validation_error', 'action' => 'reject' }
    profile['response']['roles'] = { 'status' => { 'id' => 'id' } }
    profile['callback']['signature']['credentials'] = %w[current previous]
    profile['action_mapping'] = { 'sbp' => 'create', 'check' => 'status' }
    expect(blockers).to be_empty
    expect(Paygen::Generator.new(persisted).render).to have_key('novapay_service.rb')
  end

  it 'rejects incompatible stripe signature options and attempts to remap canonical actions' do
    profile['callback']['signature'].merge!('algorithm' => 'stripe-v1', 'encoding' => 'base64')
    profile['action_mapping'] = { 'create' => 'status' }
    expect(blockers).to include(hash_including('path' => 'callback.signature.encoding'), hash_including('path' => 'action_mapping.create'))
  end

  it 'surfaces J2 and J5 through the public CLI without creating a runnable artifact' do
    change_media('application/xml')
    profile['errors']['400'] = 'validation_error'
    persisted
    _output, error, status = Open3.capture3(File.expand_path('../run', __dir__), 'cli', 'generate', @project.root)
    expect(status.exitstatus).to eq(4)
    result = JSON.parse(error)
    expect(result.dig('error', 'details', 'diagnostics')).to include(hash_including('path' => 'errors.400'), hash_including('code' => 'MEDIA_TYPE_UNSUPPORTED'))
    expect(Dir[@project.path('generated/*.rb')]).to be_empty
  end

  %w[application/json application/x-www-form-urlencoded].each do |media|
    it "generates and transports #{media} with independently checked headers and bytes" do
      # A tiny synthetic contract: assertions below are not produced by the generator.
      doc = { 'openapi' => '3.1.0', 'info' => { 'title' => 'Codec Example', 'version' => '1' },
        'servers' => [{ 'url' => 'https://codec.example.test' }], 'paths' => { '/payouts' => { 'post' => {
          'operationId' => 'submit', 'security' => [], 'responses' => { '201' => { 'description' => 'Accepted' } },
          'requestBody' => { 'content' => { media => { 'schema' => { 'type' => 'object', 'properties' => {
            'amount' => { 'type' => 'integer' }, 'reference' => { 'type' => 'string' } }, 'required' => %w[amount reference] } } } }
        } } } }
      answers = { 'operations' => { 'create' => 'submit' }, 'auth' => { 'type' => 'none' },
        'amount' => { 'scale' => 100, 'currencies' => ['USD'] }, 'idempotency' => {},
        'request_mapping' => { 'amount' => { 'from' => 'amount', 'transform' => 'minor_units' }, 'reference' => { 'from' => 'id' } },
        'status_mapping' => { 'pending' => 'in_progress' } }
      file = File.join(@directory, 'codec.json')
      File.write(file, Paygen.json(doc))
      path = File.join(@directory, 'codec-profile.yml')
      File.write(path, YAML.dump(answers))
      project = Paygen::Project.init(file, output: File.join(@directory, 'codec-project'), profile: path)
      rendered = Paygen::Generator.new(project).render
      klass = Paygen::Runtime::ReferenceProvider.load_service(source: rendered.fetch('codec_example_service.rb'), class_name: 'CodecExampleService')
      transport = double('independent transport')
      expect(transport).to receive(:request) do |**request|
        expect(request[:headers]['Content-Type']).to eq(media)
        if media == 'application/json'
          expect(JSON.parse(request[:body])).to eq('amount' => 1234, 'reference' => 'test +/&')
        else
          expect(URI.decode_www_form(request[:body]).to_h).to eq('amount' => '1234', 'reference' => 'test +/&')
          expect(request[:body]).to include('reference=test+%2B%2F%26')
        end
        { status: 201, headers: {}, body: '{"id":"p-1","status":"pending"}' }
      end
      expect(klass.new(transport: transport).create_request('id' => 'test +/&', 'amount' => '12.34', 'currency' => 'USD')['success']).to be(true)
    end
  end
end
