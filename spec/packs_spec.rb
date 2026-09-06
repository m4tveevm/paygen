# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'json'
require 'uri'
require_relative 'support/provider_harness'

RSpec.describe 'Offline provider golden packs' do
  let(:packs_root) { File.expand_path('../fixtures', __dir__) }

  def pack_data(provider)
    JSON.parse(File.read(File.join(packs_root, provider, 'fixtures.json')))
  end

  def with_adapter(provider, response_names = ['created'])
    fixture = pack_data(provider)
    requests = []
    responses = response_names.map { |name| fixture.fetch('responses').fetch(name) }
    transport = Object.new
    transport.define_singleton_method(:request) do |**request|
      requests << request
      response = responses.shift
      raise 'Unexpected provider HTTP request' unless response

      { status: response.fetch('status'), headers: response.fetch('headers'),
        body: JSON.generate(response.fetch('body')) }
    end
    Dir.mktmpdir('paygen-pack-') do |directory|
      project = Paygen::Project.init(File.join(packs_root, provider, 'openapi.yaml'),
                                    output: File.join(directory, 'integration'))
      generator = Paygen::Generator.new(project)
      result = generator.generate
      expect(result.fetch('status')).to eq('generated')
      class_name = project.profile.fetch('class_name')
      Provider.send(:remove_const, class_name) if Provider.const_defined?(class_name, false)
      load project.path("generated/#{provider}_service.rb")
      adapter = Provider.const_get(class_name).new(
        credentials: fixture.fetch('credentials'), transport: transport,
        account: fixture['account'], clock: -> { Time.at(fixture.fetch('clock')) }
      )
      yield adapter, fixture, requests, project, generator, transport
    ensure
      Provider.send(:remove_const, class_name) if class_name && Provider.const_defined?(class_name, false)
    end
  end

  %w[novapay paypal stripe adyen].each do |provider|
    context provider do
      it 'pins every distributed contract, profile, and fixture digest' do
        folder = File.join(packs_root, provider)
        provenance = JSON.parse(File.read(File.join(folder, 'provenance.json')))
        expect(provenance.fetch('files_sha256')).to include('openapi.yaml', 'integration.yml', 'fixtures.json')
        provenance.fetch('files_sha256').each do |relative, checksum|
          expect(Digest::SHA256.file(File.join(folder, relative)).hexdigest).to eq(checksum)
        end
        next if provider == 'novapay'

        expect(provenance.fetch('source_kind')).to eq('authored_curated_subset')
        expect(provenance.fetch('upstream_commit')).to match(/\A[0-9a-f]{40}\z/)
        expect(provenance.fetch('source_url')).to start_with('https://github.com/')
        expect(provenance.fetch('upstream_license')).not_to be_empty
      end

      it 'generates, loads, and sends its declared request representation' do
        with_adapter(provider) do |adapter, fixture, requests|
          operation = fixture.fetch('operation')
          expect(adapter.check_conditions(operation)).to include('success' => true)
          result = adapter.create_request(operation)
          expect(result).to include('success' => true, 'status' => 'in_progress')
          request = requests.fetch(0)
          expect(request.fetch(:method)).to eq('POST')
          if provider == 'stripe'
            form = URI.decode_www_form(request.fetch(:body)).to_h
            expect(form).to include('amount' => '1234', 'currency' => 'eur',
                                   'metadata[operation_id]' => operation.fetch('id'))
            expect(request.fetch(:headers)).to include('Stripe-Account' => 'acct_fixture_001',
                                                      'Stripe-Version' => '2026-08-26.dahlia')
          else
            body = JSON.parse(request.fetch(:body))
            case provider
            when 'novapay'
              expect(body).to include('amount' => 1_500_000, 'external_id' => operation.fetch('id'))
              expect(body.fetch('recipient')).to include('type' => 'sbp', 'bank_code' => '044525225')
            when 'paypal'
              expect(body.fetch('items').size).to eq(1)
              expect(body.dig('items', 0, 'amount')).to eq('value' => '12.34', 'currency' => 'EUR')
              expect(body.dig('sender_batch_header', 'sender_batch_id')).to eq(operation.fetch('id'))
            when 'adyen'
              expect(body).to include('category' => 'bank', 'type' => 'bankTransfer', 'priority' => 'regular')
              expect(body.fetch('amount')).to eq('value' => 1234, 'currency' => 'EUR')
            end
          end
        end
      end

      it 'regenerates byte-identically and preserves user extensions' do
        with_adapter(provider) do |_adapter, _fixture, _requests, project, generator|
          project.write('extensions/owned.rb', "# User-owned hook\n")
          before = project.lock.fetch('generated').dup
          generator.generate
          expect(project.lock.fetch('generated')).to eq(before)
          expect(File.read(project.path('extensions/owned.rb'))).to eq("# User-owned hook\n")
          expect(generator.diff).to be_empty
        end
      end

      it 'rejects fractional minor units and unsupported currency before sending' do
        with_adapter(provider) do |adapter, fixture, requests|
          operation = fixture.fetch('operation')
          invalid = operation.merge('amount' => '1000.001')
          expect(adapter.create_request(invalid).dig('error', 'code')).to eq('validation_error')
          expect(adapter.create_request(operation.merge('currency' => 'JPY')).dig('error', 'code')).to eq('validation_error')
          expect(requests).to be_empty
        end
      end

      it 'preserves 429 timing without assuming provider key retention' do
        with_adapter(provider, ['rate_limited']) do |adapter, fixture, requests|
          result = adapter.create_request(fixture.fetch('operation'))
          expect(result.fetch('error')).to include('retryable' => false, 'retry_after' => 60)
          repeated = adapter.create_request(fixture.fetch('operation'))
          expect(repeated.dig('error', 'code')).to eq('reconciliation_required')
          expect(requests.size).to eq(1)
        end
      end

      it 'imports, exports, and replays its Arazzo create/status workflow' do
        expected = pack_data(provider).fetch('workflow')
        with_adapter(provider, expected.fetch('response_names')) do |_adapter, fixture, requests, project, _generator, transport|
          document = Paygen::Core::Input.read(File.join(packs_root, provider, 'workflows/payout.arazzo.yaml'))
          workflow = Paygen::Core::Workflow.new(document, sources: { 'provider' => project.effective_document }, transport: transport)
          expect(JSON.parse(workflow.export(format: :json))).to eq(document)
          result = workflow.run('payout', inputs: fixture.dig('workflow', 'inputs'), seed: 42)
          expect(result).to include('success' => true, 'seed' => 42)
          expect(result.dig('outputs', 'provider_status')).to eq(expected.fetch('expected_provider_status'))
          expect(result.fetch('trace').map { |step| step.fetch('stepId') }).to eq(%w[create status])
          expect(requests.map { |request| request.fetch(:method) }).to eq(%w[POST GET])
          expect(requests.last.fetch(:url)).to end_with('/' + result.dig('outputs', 'provider_id'))
          if provider == 'stripe'
            expect(URI.decode_www_form(requests.first.fetch(:body)).to_h).to include(
              'metadata[operation_id]' => fixture.dig('operation', 'id')
            )
          else
            expect(JSON.parse(requests.first.fetch(:body))).to eq(fixture.dig('workflow', 'inputs', 'request_body'))
          end
        end
      end

      it 'ends its workflow when creation fails instead of polling a missing payout' do
        with_adapter(provider, ['rate_limited']) do |_adapter, fixture, requests, project, _generator, transport|
          document = Paygen::Core::Input.read(File.join(packs_root, provider, 'workflows/payout.arazzo.yaml'))
          workflow = Paygen::Core::Workflow.new(document, sources: { 'provider' => project.effective_document }, transport: transport)
          result = workflow.run('payout', inputs: fixture.dig('workflow', 'inputs'))
          expect(result.fetch('success')).to be(false)
          expect(result.fetch('outputs')).to be_empty
          expect(requests.length).to eq(1)
        end
      end
    end
  end

  it 'applies the NovaPay conditional recipient correction without modifying the pinned source' do
    with_adapter('novapay') do |adapter, fixture, _requests, project|
      recipient = project.effective_document.dig('components', 'schemas', 'Recipient')
      expect(recipient.fetch('oneOf').map { |branch| branch.fetch('required') }).to eq([['bank_code'], ['card_number']])
      expect(recipient.dig('properties', 'type', 'enum')).to eq(%w[sbp card])
      operation = Marshal.load(Marshal.dump(fixture.fetch('operation')))
      operation.fetch('payout_requisite').fetch('sbp').delete('bank_code')
      expect(adapter.create_request(operation).dig('error', 'code')).to eq('validation_error')
      original = Paygen::Core::Input.read(File.join(packs_root, 'novapay', 'openapi.yaml'))
      expect(original.dig('components', 'schemas', 'Recipient', 'required')).not_to include('bank_code')
    end
  end

  it 'generates a card adapter request at exactly 1000 RUB without SBP-only fields' do
    with_adapter('novapay') do |adapter, fixture, requests, project|
      original = File.binread(File.join(packs_root, 'novapay', 'openapi.yaml'))
      operation = fixture.fetch('card_operation')
      expect(adapter.check_conditions(operation)['success']).to be(true)
      expect(adapter.create_request(operation)['success']).to be(true)
      payload = JSON.parse(requests.fetch(0).fetch(:body))
      expect(payload).to include('amount' => 100_000, 'currency' => 'RUB', 'external_id' => 'op_nova_card_001')
      expect(payload.fetch('recipient')).to eq('type' => 'card', 'phone' => '79001234567',
                                               'card_number' => operation.dig('payout_requisite', 'card', 'card_number'))
      expect(File.binread(File.join(packs_root, 'novapay', 'openapi.yaml'))).to eq(original)
      expect(project.ir.diagnostics).to be_empty
    end
  end

  it 'rejects missing conditional data, unknown types and subminimum money without HTTP' do
    with_adapter('novapay') do |adapter, fixture, requests|
      valid_card = fixture.fetch('card_operation')
      valid_sbp = fixture.fetch('operation')
      missing_card = Marshal.load(Marshal.dump(valid_card))
      missing_card.fetch('payout_requisite').fetch('card').delete('card_number')
      missing_bank = Marshal.load(Marshal.dump(valid_sbp))
      missing_bank.fetch('payout_requisite').fetch('sbp').delete('bank_code')
      unknown = valid_card.merge('payout_requisite' => valid_card.fetch('payout_requisite').merge('type' => 'crypto'))
      [missing_card, missing_bank, unknown, valid_card.merge('amount' => '999.99'),
       valid_sbp.merge('amount' => '999.99')].each do |operation|
        expect(adapter.check_conditions(operation).dig('error', 'code')).to eq('validation_error')
        expect(adapter.create_request(operation).dig('error', 'code')).to eq('validation_error')
      end
      expect(requests).to be_empty
    end
  end

  it 'rejects empty conditional recipient values and does not leak the inactive branch onto the wire' do
    with_adapter('novapay') do |adapter, fixture, requests|
      empty = Marshal.load(Marshal.dump(fixture.fetch('card_operation')))
      empty.fetch('payout_requisite').fetch('card')['card_number'] = ''
      expect(adapter.create_request(empty).dig('error', 'code')).to eq('validation_error')
      both = Marshal.load(Marshal.dump(fixture.fetch('operation')))
      both.fetch('payout_requisite')['card'] = fixture.dig('card_operation', 'payout_requisite', 'card')
      expect(adapter.create_request(both)['success']).to be(true)
      expect(JSON.parse(requests.fetch(0).fetch(:body)).fetch('recipient').keys).to contain_exactly('type', 'phone', 'bank_code')
    end
  end

  it 'never approves a PayPal item from a successful batch header' do
    with_adapter('paypal', %w[batch_success batch_success_item_failed]) do |adapter, fixture|
      operation = fixture.fetch('operation')
      created = adapter.create_request(operation)
      expect(created).to include('success' => true, 'status' => 'in_progress')
      result = adapter.fetch_status(operation.merge('provider_id' => created.fetch('provider_id')))
      expect(result).to include('success' => true, 'status' => 'rejected', 'provider_status' => 'FAILED')
      expect(result.fetch('provider_item_id')).to eq('ITEM_FIXTURE_001')
    end
  end

  it 'fails closed at the PayPal callback verification boundary' do
    with_adapter('paypal') do |adapter, fixture|
      message = fixture.fetch('webhooks').fetch('success')
      result = adapter.process_callback(message.fetch('payload'), raw_body: message.fetch('raw_body'), headers: message.fetch('headers'))
      expect(result.dig('error', 'code')).to eq('invalid_signature')
      # This substitutes an external verification result, not a cryptographic signature.
      allow(adapter).to receive(:paygen_verify_callback).and_return(true)
      verified = adapter.process_callback(message.fetch('payload'), raw_body: message.fetch('raw_body'), headers: message.fetch('headers'))
      expect(verified).to include('success' => true, 'status' => 'approved')
    end
  end

  { 'stripe' => [%w[paid failed], %w[approved rejected]],
    'adyen' => [%w[booked returned], %w[in_progress rejected]],
    'novapay' => [%w[processing completed], %w[in_progress approved]] }.each do |provider, (names, states)|
    it "handles #{provider} callback progression, replay, and stale delivery" do
      with_adapter(provider) do |adapter, fixture|
        messages = names.map { |name| fixture.fetch('webhooks').fetch(name) }
        results = messages.map do |message|
          adapter.process_callback(message.fetch('payload'), raw_body: message.fetch('raw_body'), headers: message.fetch('headers'))
        end
        expect(results.map { |result| result.fetch('status') }).to eq(states)
        message = messages.last
        replay = adapter.process_callback(message.fetch('payload'), raw_body: message.fetch('raw_body'), headers: message.fetch('headers'))
        expect(replay).to include('status' => states.last, 'ignored' => 'duplicate')
        old = messages.first
        stale = adapter.process_callback(old.fetch('payload'), raw_body: old.fetch('raw_body'), headers: old.fetch('headers'))
        expect(stale.fetch('status')).to eq(states.last)
      end
    end

    it "checks #{provider} signatures against the original bytes" do
      with_adapter(provider) do |adapter, fixture|
        message = fixture.fetch('webhooks').fetch(names.last)
        # The JSON value is unchanged but a whitespace byte invalidates the HMAC.
        result = adapter.process_callback(message.fetch('payload'), raw_body: message.fetch('raw_body') + ' ', headers: message.fetch('headers'))
        expect(result.dig('error', 'code')).to eq('invalid_signature')
      end
    end
  end

  it 'keeps Adyen booking distinct from settlement when polling' do
    with_adapter('adyen', %w[created booked returned]) do |adapter, fixture|
      operation = fixture.fetch('operation')
      created = adapter.create_request(operation)
      identity = operation.merge('provider_id' => created.fetch('provider_id'))
      expect(adapter.fetch_status(identity)).to include('provider_status' => 'booked', 'status' => 'in_progress')
      expect(adapter.fetch_status(identity)).to include('provider_status' => 'returned', 'status' => 'rejected')
    end
  end
end
