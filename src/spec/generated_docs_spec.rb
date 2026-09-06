# frozen_string_literal: true

require 'spec_helper'
require 'paygen/runtime/adapter'

RSpec.describe Paygen::Documentation do
  def with_project(provider = 'novapay')
    Dir.mktmpdir('paygen-documentation-') do |directory|
      source = File.expand_path("../../fixtures/#{provider}/openapi.yaml", __dir__)
      project = Paygen::Project.init(source, output: File.join(directory, 'project'))
      yield project, directory
    end
  end

  def fixture_adapter(config, credentials, clock, account: nil)
    klass = Class.new do
      const_set(:PAYGEN_CONFIG, config)
      include Paygen::Runtime::Adapter
    end
    klass.new.configure_paygen(credentials: credentials, clock: -> { Time.at(clock) }, account: account)
  end

  it 'documents concrete credentials, URLs and separate role-specific conflicts' do
    with_project do |project|
      guide = Paygen::Generator.new(project).render.fetch('INTEGRATION.md')
      expect(guide).to include('X-API-Key', 'PAYGEN_API_KEY', 'X-NovaPay-Signature', 'hmac-sha256', 'hex')
      expect(guide).to include('https://', '/payouts/{payout_id}', 'provider_operation_id', 'paygen_backend_callback_result')
      expect(guide).to include('| create | 409 | duplicate | reconcile |', '| cancel | 409 | invalid_status | reject |')
      expect(guide).not_to include('| roles |')
      expect(guide).to include('No gateway configuration is declared')
      expect(guide).to include('state_namespace_required', 'state_migration_required', 'credential rotation', 'Never clear the store')
      overridden = Paygen::Generator.new(project).render(overrides: { 'servers' => ['https://sandbox.example.test'] }).fetch('INTEGRATION.md')
      expect(overridden).to include('https://sandbox.example.test/payouts')
    end
  end

  it 'preserves every named callback and signs success and failure raw bytes reproducibly' do
    with_project do |project|
      generator = Paygen::Generator.new(project)
      files = generator.render
      expect(files).to eq(generator.render)
      callback = JSON.parse(files.fetch('fixtures.json')).fetch('callback')
      expect(callback.fetch('request_examples').map { |item| item['name'] }).to include('completed', 'failed')
      expect(callback.fetch('cases').map { |item| item['expected_operation_status'] }).to include('approved', 'rejected')
      callback.fetch('cases').each do |example|
        expect(JSON.parse(example.fetch('raw_body'))).to eq(example.fetch('payload'))
        expect(example).to include('signature_generated' => true, 'provider_acceptance_verified' => false)
        adapter = fixture_adapter(project.ir.config, callback.fetch('fixture_credentials'), callback.fetch('fixture_clock_unix'))
        result = adapter.process_callback(example.fetch('payload'), raw_body: example.fetch('raw_body'), headers: example.fetch('headers'))
        expect(result).to include('success' => true, 'status' => example.fetch('expected_operation_status'))
        altered = example.fetch('raw_body') + ' '
        result = adapter.process_callback(example.fetch('payload'), raw_body: altered, headers: example.fetch('headers'))
        expect(result).to include('success' => false)
      end
    end
  end

  it 'generates timestamped webhook signatures with an explicit fixture clock' do
    with_project('stripe') do |project|
      callback = JSON.parse(Paygen::Generator.new(project).render.fetch('fixtures.json')).fetch('callback')
      example = callback.fetch('cases').find { |item| item['expected_operation_status'] == 'rejected' }
      expect(example).not_to be_nil
      expect(example.dig('headers', 'Stripe-Signature')).to start_with("t=#{callback.fetch('fixture_clock_unix')},v1=")
      adapter = fixture_adapter(project.ir.config, callback.fetch('fixture_credentials'), callback.fetch('fixture_clock_unix'), account: example.dig('adapter_context', 'account'))
      expect(adapter.process_callback(example.fetch('payload'), raw_body: example.fetch('raw_body'), headers: example.fetch('headers')))
        .to include('success' => true, 'status' => 'rejected')
    end
  end

  it 'does not fabricate evidence for callbacks requiring provider verification' do
    with_project('paypal') do |project|
      callback = JSON.parse(Paygen::Generator.new(project).render.fetch('fixtures.json')).fetch('callback')
      expect(callback.fetch('fixture_credentials')).to eq({})
      expect(callback.fetch('cases')).not_to be_empty
      callback.fetch('cases').each do |example|
        expect(example).to include('signature_generated' => false, 'requires_provider_verification' => true, 'headers' => {})
      end
    end
  end

  it 'preserves all named response examples and reports invalid source evidence without rewriting it' do
    with_project do |project|
      project.write('overlays/700-examples.yaml', YAML.dump({
        'overlay' => '1.1.0', 'info' => { 'title' => 'Named examples', 'version' => '1' },
        'actions' => [{ 'target' => "$.paths['/payouts'].post.responses['201'].content['application/json'].example", 'remove' => true },
                      { 'target' => "$.paths['/payouts'].post.responses['201'].content['application/json']", 'update' => {
          'examples' => { 'first' => { 'value' => { 'status' => 'pending' } },
                          'second' => { 'value' => { 'status' => 'completed' } },
                          'external' => { 'externalValue' => 'https://example.test/sample.json' } }
        } }]
      }))
      project.configure(project.profile) # Explicitly review this authored contract variant.
      cases = JSON.parse(Paygen::Generator.new(project).render.fetch('fixtures.json')).dig('create', 'response_examples', '201')
      expect(cases.map { |item| item['name'] }).to include('first', 'second', 'external')
      expect(cases.find { |item| item['name'] == 'first' }).to include('value' => { 'status' => 'pending' })
      expect(cases.find { |item| item['name'] == 'first' }.dig('schema_validation', 'valid')).to be(false)
      expect(cases.find { |item| item['name'] == 'external' }).to include('available' => false, 'origin' => 'openapi-external-example')
    end
  end

  it 'exports the full effective graph and portable escaped HTML without publishing' do
    with_project do |project, directory|
      generator = Paygen::Generator.new(project)
      generator.generate
      output = File.join(directory, 'docs')
      result = generator.docs(format: 'html', output: output)
      expect(result).to include('status' => 'documented', 'format' => 'html')
      expect(JSON.parse(File.read(File.join(output, 'effective-openapi.json')))).to eq(project.effective_document)
      html = File.read(File.join(output, 'index.html'))
      expect(html).to include('<!doctype html>', 'Content-Security-Policy', 'X-NovaPay-Signature')
      expect(html).not_to include('<script', 'src="https://')
      expect(described_class.html("# <img src=x onerror=alert(1)>\n\n<script>alert(1)</script>\n")).to include('&lt;img', '&lt;script&gt;')
      expect { generator.docs(format: 'html', output: output) }.to raise_error(Paygen::Error, /already exists/)
      project.write('generated/INTEGRATION.md', 'modified')
      expect { generator.docs(format: 'md', output: File.join(directory, 'changed')) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('GENERATED_DRIFT') }
    end
  end

  it 'documents declared OAuth scopes and gateway configuration without inferring backend constants' do
    with_project('paypal') do |project|
      profile = project.profile.merge('gateway' => { 'name' => 'REVIEWED_GATEWAY', 'external_method' => 'payout' },
                                      'auth' => { 'type' => 'oauth2', 'credential' => 'access_token', 'scopes' => ['payouts'] })
      project.write('integration.yml', YAML.dump(profile))
      guide = Paygen::Generator.new(project).render.fetch('INTEGRATION.md')
      expect(guide).to include('Required scopes:', 'PAYGEN_ACCESS_TOKEN', 'REVIEWED_GATEWAY', 'external_method')
    end
  end

  it 'keeps additional request media examples while retaining the selected media request' do
    with_project do |project|
      project.write('overlays/700-media.yaml', YAML.dump({
        'overlay' => '1.1.0', 'info' => { 'title' => 'Another media type', 'version' => '1' },
        'actions' => [{ 'target' => "$.paths['/payouts'].post.requestBody.content", 'update' => {
          'application/vnd.example+json' => { 'schema' => { 'type' => 'boolean' }, 'examples' => { 'disabled' => { 'value' => false } } }
        } }]
      }))
      project.configure(project.profile) # Explicitly review this authored contract variant.
      create = JSON.parse(Paygen::Generator.new(project).render.fetch('fixtures.json')).fetch('create')
      expect(create.fetch('request')).to be_a(Hash)
      expect(create.fetch('request_examples').find { |item| item['name'] == 'disabled' })
        .to include('value' => false, 'content_type' => 'application/vnd.example+json', 'origin' => 'openapi-example')
    end
  end

  it 'serializes exact decimal fixture numbers as JSON numbers without precision loss' do
    with_project do |project|
      project.write('integration.yml', YAML.dump(project.profile.merge(
        'amount' => { 'minimum' => 9_007_199_254_740_993 },
        'request_mapping' => { 'amount' => { 'from' => 'amount', 'transform' => 'decimal_number' } }
      )))
      project.write('overlays/700-decimal.yaml', YAML.dump({
        'overlay' => '1.1.0', 'info' => { 'title' => 'Decimal amount contract', 'version' => '1' },
        'actions' => [
          { 'target' => "$.paths['/payouts'].post.requestBody.content['application/json'].examples", 'remove' => true },
          { 'target' => '$.components.schemas.CreatePayoutRequest.properties.amount', 'update' => { 'type' => 'number', 'minimum' => 0 } }
        ]
      }))
      project.configure(project.ir(review: false).profile) # Explicitly review this authored contract variant.
      json = Paygen::Generator.new(project).render.fetch('fixtures.json')
      value = JSON.parse(json, decimal_class: BigDecimal).dig('create', 'request', 'amount')
      expect(value).to eq(BigDecimal('90071992547409.93'))
      expect(json).to include('"amount": 90071992547409.93')
      expect(JSON.parse(json).dig('create', 'request_examples', 0, 'schema_validation', 'valid')).to be(true)
    end
  end

  it 'records actual negative callback evidence separately from the declared status mapping' do
    with_project do |project|
      project.write('overlays/700-negative-callback.yaml', YAML.dump({
        'overlay' => '1.1.0', 'info' => { 'title' => 'Wrong event identity', 'version' => '1' },
        'actions' => [{ 'target' => "$.paths['/webhooks/payout'].post.requestBody.content['application/json'].examples", 'update' => {
          'mismatch' => { 'value' => { 'payout_id' => 'fixture-mismatch', 'external_id' => 'fixture', 'status' => 'completed', 'event' => 'payout.failed' } }
        } }]
      }))
      project.configure(project.profile) # Explicitly review this authored contract variant.
      callback = JSON.parse(Paygen::Generator.new(project).render.fetch('fixtures.json')).fetch('callback')
      example = callback.fetch('cases').find { |item| item['name'] == 'mismatch' }
      expect(example).to include('signature_generated' => true, 'mapped_operation_status' => 'approved', 'expected_operation_status' => 'error')
      expect(example.dig('adapter_validation', 'success')).to be(false)
      expect(example.dig('expected_adapter_result', 'error', 'code')).to eq('event_status_mismatch')
    end
  end

  it 'preserves nested generated artifacts and exact-number dependencies in detached exports' do
    with_project do |project, directory|
      generator = Paygen::Generator.new(project)
      allow(generator).to receive(:render).and_wrap_original do |original, **arguments|
        original.call(**arguments).merge('examples/readme.txt' => 'Nested generated artifact')
      end
      generator.generate
      target = File.join(directory, 'detached')
      generator.export(output: target)
      expect(File.read(File.join(target, 'examples/readme.txt'))).to eq('Nested generated artifact')
      expect(File.read(File.join(target, 'Gemfile'))).to include("gem 'json', '~> 2.21'")
    end
  end
end
