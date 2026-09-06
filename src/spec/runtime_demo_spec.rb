# frozen_string_literal: true

require 'spec_helper'
require 'rack/mock'
require 'paygen/runtime/demo'

RSpec.describe Paygen::Runtime::Demo do
  around do |example|
    Dir.mktmpdir do |directory|
      project = Paygen::Project.init(File.expand_path('../../fixtures/novapay/openapi.yaml', __dir__), output: File.join(directory, 'project'))
      files = Paygen::Generator.new(project).render
      @app = described_class.new(source: files.fetch('novapay_service.rb'), config: JSON.parse(files.fetch('config.json')))
      @client = Rack::MockRequest.new(@app)
      example.run
    end
  end

  def post(path, body = {}, headers = {})
    @client.post(path, { 'CONTENT_TYPE' => 'application/json', input: body.is_a?(String) ? body : JSON.generate(body) }.merge(headers))
  end

  def create(id = 'demo-operation')
    post('/operations', @app.simulator.sample_operation(id: id))
  end

  it 'runs a generated adapter through HTTP, retries without a second payout and polls its status' do
    expect(JSON.parse(@client.get('/health').body)).to include('offline' => true)
    response = create
    expect(response.status).to eq(200), response.body
    first = JSON.parse(response.body)
    expect(first).to include('status' => 'in_progress')
    retried = JSON.parse(post('/operations/demo-operation/retry').body)
    expect(retried['provider_id']).to eq(first['provider_id'])
    expect(@app.simulator.evidence['created_count']).to eq(1)
    result = JSON.parse(@client.get('/operations/demo-operation').body)
    expect(result['success']).to be(true)
  end

  it 'serves a same-origin panel and identifies the generated service by digest' do
    page = @client.get('/')
    expect(page.status).to eq(200)
    expect(page['content-security-policy']).to include("connect-src 'self'")
    expect(page.body).to include('Generated adapter evidence')
    expect(@client.get('/demo.js').status).to eq(200)
    expect(@client.get('/demo.css').status).to eq(200)
    artifacts = JSON.parse(@client.get('/artifacts').body)
    expect(artifacts).to include('generated_service' => 'novapay_service.rb', 'offline' => true)
    expect(artifacts.fetch('generated_service_sha256')).to match(/\A[0-9a-f]{64}\z/)
  end

  it 'rejects bad signatures and persists a verified callback once across duplicate delivery' do
    expect(create.status).to eq(200)
    event = JSON.parse(@client.get('/events/demo-operation').body).fetch('events').last
    expect(post('/callbacks', event.fetch('raw_body')).status).to eq(422)
    expect(JSON.parse(@client.get('/evidence').body)['backend_events']).to be_empty
    headers = event.fetch('headers').to_h { |name, value| ["HTTP_#{name.upcase.tr('-', '_')}", value] }
    accepted = post('/callbacks', event.fetch('raw_body'), headers)
    expect(accepted.status).to eq(200), accepted.body
    expect(JSON.parse(accepted.body)['status']).to eq('approved')
    expect(post('/callbacks', event.fetch('raw_body'), headers).status).to eq(200)
    expect(JSON.parse(@client.get('/evidence').body)['backend_events'].size).to eq(1)
  end

  it 'exercises outbound credential rejection in the strict provider simulator' do
    result = post('/checks/invalid-auth')
    expect(result.status).to eq(422)
    expect(JSON.parse(result.body).dig('error', 'code')).to eq('unauthorized')
    expect(@app.simulator.evidence['created_count']).to eq(0)
  end

  it 'cancels a separately created pending operation and rejects invalid money without a payout' do
    expect(create('cancel-operation').status).to eq(200)
    cancelled = post('/operations/cancel-operation/cancel')
    expect(cancelled.status).to eq(200), cancelled.body
    expect(JSON.parse(cancelled.body)['status']).to eq('rejected')
    invalid = @app.simulator.sample_operation(id: 'invalid').merge('amount' => 0.1)
    expect(post('/operations', invalid).status).to eq(422)
    expect(@app.simulator.evidence['created_count']).to eq(1)
  end

  it 'bounds requests and requires JSON content type' do
    expect(@client.post('/operations', input: '{}').status).to eq(415)
    expect(post('/operations', 'x' * 1_048_577).status).to eq(413)
    expect(post('/operations', '[]').status).to eq(400)
  end

  it 'supplies a synthetic operation for the loaded provider instead of a NovaPay-only browser body' do
    sample = @client.get('/sample')
    expect(sample.status).to eq(200)
    operation = JSON.parse(sample.body)
    expect(operation.fetch('id')).to eq('synthetic-demo-operation')
    expect(post('/operations', operation).status).to eq(200)
    expect(@client.get('/').body).to include('operation-json')
    expect(@client.get('/demo.js').body).not_to include("amount:'1500.00'")
  end

  it 'makes the unverified PayPal boundary explicit and returns a usable provider-specific sample' do
    Dir.mktmpdir do |directory|
      project = Paygen::Project.init(File.expand_path('../../fixtures/paypal/openapi.yaml', __dir__), output: File.join(directory, 'project'))
      files = Paygen::Generator.new(project).render
      app = described_class.new(source: files.fetch('paypal_service.rb'), config: JSON.parse(files.fetch('config.json')))
      client = Rack::MockRequest.new(app)
      expect(JSON.parse(client.get('/artifacts').body)['callback_verification']).to eq('provider_verification')
      operation = JSON.parse(client.get('/sample').body)
      response = client.post('/operations', 'CONTENT_TYPE' => 'application/json', input: JSON.generate(operation))
      expect(response.status).to eq(200), response.body
    end
  end

  it 'reconciles a bank timeout by the merchant ID without sending another create' do
    Dir.mktmpdir do |directory|
      project = Paygen::Project.init(File.expand_path('../../fixtures/raiffeisen_payouts/upstream/openapi.json', __dir__), output: File.join(directory, 'project'))
      files = Paygen::Generator.new(project).render
      @app = described_class.new(source: files.fetch('raiffeisen_payouts_service.rb'), config: JSON.parse(files.fetch('config.json')),
                                scenario: 'timeout_after_commit')
      @client = Rack::MockRequest.new(@app)
      fixture = JSON.parse(File.read(File.expand_path('../../fixtures/raiffeisen_payouts/fixtures.json', __dir__)))
      first = post('/operations', fixture.fetch('operation'))
      expect(first.status).to eq(422)
      expect(JSON.parse(first.body).dig('error', 'ambiguous')).to be(true)
      expect(post('/operations/ru-demo-001/retry').status).to eq(422)
      status = @client.get('/operations/ru-demo-001')
      expect(status.status).to eq(200), status.body
      expect(JSON.parse(status.body)['provider_id']).to eq('ru-demo-001')
      expect(post('/operations/ru-demo-001/retry').status).to eq(200)
      evidence = @app.simulator.evidence
      expect(evidence['created_count']).to eq(1)
      expect(evidence['requests'].count { |request| request['role'] == 'create' }).to eq(1)
    end
  end
end
