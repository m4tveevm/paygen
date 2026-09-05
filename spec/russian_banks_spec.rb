# frozen_string_literal: true

require 'spec_helper'
require_relative 'support/provider_harness'

RSpec.describe 'Russian bank native contracts and explicit integration boundaries' do
  let(:fixtures_root) { File.expand_path('../fixtures', __dir__) }

  def bank_file(bank, name)
    File.join(fixtures_root, bank, name)
  end

  def with_raiffeisen(response_names = %w[created])
    fixture = JSON.parse(File.read(bank_file('raiffeisen_payouts', 'fixtures.json')))
    requests = []
    responses = response_names.map { |name| fixture.fetch('responses').fetch(name) }
    transport = Object.new
    transport.define_singleton_method(:request) do |**request|
      requests << request
      response = responses.shift
      raise 'Unexpected bank HTTP request' unless response

      { status: response.fetch('status'), headers: response.fetch('headers'),
        body: JSON.generate(response.fetch('body')) }
    end
    Dir.mktmpdir('paygen-russian-bank-') do |directory|
      project = Paygen::Project.init(bank_file('raiffeisen_payouts', 'upstream/openapi.json'),
                                    output: File.join(directory, 'integration'))
      Paygen::Generator.new(project).generate
      Provider.send(:remove_const, :RaiffeisenPayoutsService) if Provider.const_defined?(:RaiffeisenPayoutsService, false)
      load project.path('generated/raiffeisen_payouts_service.rb')
      adapter = Provider::RaiffeisenPayoutsService.new(credentials: fixture.fetch('credentials'), transport: transport,
                                                      account: fixture.fetch('account'))
      yield adapter, fixture, requests, project, transport
    ensure
      Provider.send(:remove_const, :RaiffeisenPayoutsService) if Provider.const_defined?(:RaiffeisenPayoutsService, false)
    end
  end

  %w[tbank_payouts raiffeisen_payouts].each do |bank|
    it "loads the complete #{bank} native specification and verifies snapshot provenance" do
      provenance = JSON.parse(File.read(bank_file(bank, 'provenance.json')))
      expect(provenance.fetch('source_kind')).to eq('native_embedded_openapi')
      expect(provenance.fetch('source_page_sha256')).to match(/\A[0-9a-f]{64}\z/)
      provenance.fetch('files_sha256').each do |path, hash|
        expect(Digest::SHA256.file(bank_file(bank, path)).hexdigest).to eq(hash)
      end
      document = Paygen::Core::Input.load(bank_file(bank, 'upstream/openapi.json'))
      expect(document.fetch('paths').length).to eq(bank == 'tbank_payouts' ? 27 : 20)
    end
  end

  it 'sends exact ruble amounts and SBP member identifiers from an untouched native contract' do
    with_raiffeisen do |adapter, fixture, requests, project|
      expect(project.effective_document).to eq(Paygen::Core::Input.read(bank_file('raiffeisen_payouts', 'upstream/openapi.json')))
      result = adapter.create_request(fixture.fetch('operation'))
      expect(result).to include('success' => true, 'status' => 'in_progress', 'provider_id' => 'ru-demo-001')
      expected = fixture.fetch('expected_request')
      request = requests.fetch(0)
      expect(request).to include(method: expected.fetch('method'), url: expected.fetch('url'))
      expect(request.fetch(:headers)).to include(expected.fetch('headers'))
      expect(request.fetch(:headers)).not_to have_key('Idempotency-Key')
      expect(JSON.parse(request.fetch(:body))).to eq(expected.fetch('body'))
      expect(request.fetch(:body)).to include('"amount":1110.01')
      expect(request.fetch(:body)).not_to include('"amount":"1110.01"', '"amount":111001')
      expect(project.ir.config.fetch('endpoints').keys).to contain_exactly('create', 'status')
    end
  end

  it 'keeps confirmation pending and uses the PDF provider_operation_id when polling settlement' do
    with_raiffeisen(%w[created waiting completed]) do |adapter, fixture, requests|
      operation = fixture.fetch('operation')
      created = adapter.create_request(operation)
      identity = operation.merge('provider_operation_id' => created.fetch('provider_id'))
      expect(adapter.fetch_status(identity)).to include('provider_status' => 'WAITING_CONFIRMATION', 'status' => 'in_progress')
      expect(adapter.fetch_status(identity)).to include('provider_status' => 'COMPLETED', 'status' => 'approved')
      expect(requests.last).to include(method: 'GET', url: 'https://pay-test.raif.ru/api/payout/v2/payouts/ru-demo-001')
    end
  end

  it 'classifies an HTTP 200 declined payout as rejected' do
    with_raiffeisen(%w[created declined]) do |adapter, fixture|
      operation = fixture.fetch('operation')
      created = adapter.create_request(operation)
      expect(adapter.fetch_status(operation.merge('provider_operation_id' => created.fetch('provider_id'))))
        .to include('provider_status' => 'DECLINED', 'status' => 'rejected')
    end
  end

  it 'does not repeat a confirmed create request without a documented bank deduplication guarantee' do
    with_raiffeisen do |adapter, fixture, requests|
      operation = fixture.fetch('operation')
      expect(adapter.create_request(operation)).to include('success' => true)
      duplicate = adapter.create_request(operation)
      expect(duplicate).to include('success' => true, 'status' => 'in_progress', 'duplicate' => true)
      expect(requests.length).to eq(1)
    end
  end

  it 'requires reconciliation after a response timeout and never redispatches the ambiguous payout' do
    with_raiffeisen([]) do |adapter, fixture, requests, _project, transport|
      transport.define_singleton_method(:request) do |**request|
        requests << request
        raise Net::ReadTimeout
      end
      operation = fixture.fetch('operation')
      first = adapter.create_request(operation)
      expect(first.fetch('error')).to include('code' => 'transport_timeout', 'ambiguous' => true,
                                              'action' => 'reconcile_before_retry', 'retryable' => false)
      expect(adapter.create_request(operation).dig('error', 'code')).to eq('reconciliation_required')
      expect(requests.length).to eq(1)
    end
  end

  it 'rejects fractional kopecks and unsupported currencies before transport' do
    with_raiffeisen do |adapter, fixture, requests|
      operation = fixture.fetch('operation')
      expect(adapter.create_request(operation.merge('amount' => '1110.001')).dig('error', 'code')).to eq('validation_error')
      expect(adapter.create_request(operation.merge('currency' => 'EUR')).dig('error', 'code')).to eq('validation_error')
      expect(requests).to be_empty
    end
  end

  it 'preserves certificate signature requirements even though the T-Bank OpenAPI security array is empty' do
    document = Paygen::Core::Input.load(bank_file('tbank_payouts', 'upstream/openapi.json'))
    fixture = JSON.parse(File.read(bank_file('tbank_payouts', 'fixtures.json')))
    expect(document.dig('paths', '/e2c/v2/Init', 'post', 'security')).to eq([])
    schema = document.dig('components', 'schemas', 'InitRequestNONPCI')
    unsigned = fixture.fetch('unsigned_init_request')
    errors = JSONSchemer.schema(schema).validate(unsigned).to_a
    missing = errors.flat_map { |error| Array(error.dig('details', 'missing_keys')) }
    expect(missing).to include(*fixture.fetch('missing_signature_fields'))
    expect(document.dig('paths', '/e2c/v2/Payment', 'post', 'operationId')).to eq('Payment')
    expect(document.dig('paths', '/e2c/v2/GetState', 'post', 'operationId')).to eq('GetState')
  end

  it 'blocks generation for T-Bank until its signature and multistep semantics are configured' do
    Dir.mktmpdir('paygen-tbank-review-') do |directory|
      project = Paygen::Project.init(bank_file('tbank_payouts', 'upstream/openapi.json'), output: File.join(directory, 'integration'))
      expect { Paygen::Generator.new(project).generate }.to raise_error(Paygen::Error) { |error|
        expect(error.code).to eq('SEMANTIC_BLOCKERS')
      }
      expect(Dir[project.path('generated/*_service.rb')]).to be_empty
    end
  end
end
