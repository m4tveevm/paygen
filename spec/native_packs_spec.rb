# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'paygen/runtime/adapter'
require_relative 'support/provider_harness'

RSpec.describe 'Full native API integrations with independent HTTP oracles' do
  %w[paystack paypal].each do |provider|
    context provider do
      before(:context) do
        @native_root = File.expand_path("../fixtures/native-#{provider}", __dir__)
        @temporary = Dir.mktmpdir("paygen-native-#{provider}-")
        @source = Dir[File.join(@native_root, 'openapi.*')].fetch(0)
        @native_document = Paygen::Core::Input.read(@source)
        @oracle = JSON.parse(File.read(File.join(@native_root, 'oracle.json')))
        @project = Paygen::Project.init(@source, output: File.join(@temporary, 'project'),
                                      profile: File.join(@native_root, 'profile.yml'))
        Paygen::Generator.new(@project).generate
        @class_name = @project.profile.fetch('class_name')
        load @project.path("generated/native_#{provider}_service.rb")
        @service_class = Provider.const_get(@class_name, false)
      end

      after(:context) do
        Provider.send(:remove_const, @class_name) if @class_name && Provider.const_defined?(@class_name, false)
        FileUtils.remove_entry(@temporary) if @temporary && File.directory?(@temporary)
      end

      before do
        # The production HTTP transport still performs its DNS and URL checks.
        # WebMock intercepts all network requests; no provider receives a call.
        host = URI.parse(@oracle.fetch('create_url')).hostname
        allow(Resolv).to receive(:getaddresses).with(host).and_return(['93.184.216.34'])
      end

      let(:adapter) { @service_class.new(credentials: @oracle.fetch('credentials')) }
      let(:operation) { Marshal.load(Marshal.dump(@oracle.fetch('operation'))) }

      def native_response(body, status: 200)
        { status: status, headers: { 'Content-Type' => 'application/json' }, body: JSON.generate(body) }
      end

      def native_status_operation
        operation.merge('provider_operation_id' => @oracle.fetch('provider_id'))
      end

      def stub_native_status(body)
        stub_request(:get, @oracle.fetch('status_url'))
          .with(headers: { 'Authorization' => @oracle.fetch('authorization') })
          .to_return(native_response(body))
      end

      it 'generates from the whole unchanged pinned document without recipes, overlays or missing roles' do
        provenance = JSON.parse(File.read(File.join(@native_root, 'provenance.json')))
        provenance.fetch('files_sha256').each do |relative, checksum|
          expect(Digest::SHA256.file(File.join(@native_root, relative)).hexdigest).to eq(checksum)
        end
        expect(@project.effective_document).to eq(@native_document)
        expect(File).not_to exist(@project.path('recipes/selected.yml'))
        expect(Dir[@project.path('overlays/*')]).to be_empty
        config = JSON.parse(File.read(@project.path('generated/config.json')))
        expect(config.fetch('endpoints').keys.sort).to eq(%w[create status])
        expect(JSON.parse(File.read(@project.path('generated/diagnostics.json')))['diagnostics']).to be_empty
        expect(File.read(@project.path('generated/INTEGRATION.md'))).not_to be_empty
        expect(Paygen::Generator.new(@project).diff).to be_empty
      end

      it 'checks independently authored wire examples against the untouched native request and response schemas' do
        config = @project.ir.config
        request_schema = config.dig('endpoints', 'create', 'request_schema')
        expect(JSONSchemer.schema(request_schema, meta_schema: JSONSchemer.openapi30)
                         .valid?(@oracle.fetch('expected_request'))).to be(true)
        { 'create' => @oracle.fetch('create_http_status').to_s, 'status' => '200' }.each do |role, status|
          schema = config.dig('endpoints', role, 'responses', status, 'content', 'application/json', 'schema')
          errors = JSONSchemer.schema(schema, meta_schema: JSONSchemer.openapi30)
                              .validate(@oracle.fetch("#{role}_response")).to_a
          expect(errors).to be_empty
        end
      end

      it 'sends exact native requests through the generated adapter and retains identity and amount on retry' do
        requests = []
        create = stub_request(:post, @oracle.fetch('create_url'))
                 .with(headers: { 'Authorization' => @oracle.fetch('authorization'), 'Content-Type' => 'application/json' }) do |request|
          JSON.parse(request.body) == @oracle.fetch('expected_request')
        end.to_return do |request|
          requests << request
          native_response(@oracle.fetch('create_response'), status: @oracle.fetch('create_http_status'))
        end
        status = stub_native_status(@oracle.fetch('status_response'))
        expected = { 'success' => true, 'status' => 'in_progress', 'provider_id' => @oracle.fetch('provider_id') }
        expect(adapter.create_request(operation)).to include(expected)
        expect(adapter.create_request(operation)).to include(expected)
        expect(adapter.fetch_status(native_status_operation)).to include('success' => true, 'status' => 'approved',
                                                                        'provider_id' => @oracle.fetch('provider_id'))
        expect(create).to have_been_requested.once
        expect(status).to have_been_requested.once
        expect(requests.map(&:body).uniq.length).to eq(1)
        if provider == 'paystack'
          expect(requests.map { |request| request.headers['Idempotency-Key'] }).to eq([nil])
          expect(JSON.parse(requests.first.body)['reference']).to match(/\A[a-z0-9_-]{16,50}\z/)
        else
          keys = requests.map { |request| request.headers['Paypal-Request-Id'] }
          expect(keys.uniq.length).to eq(1)
          expect(keys.first).to match(/\A[\da-f]{8}-[\da-f]{4}-5[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}\z/)
        end
        expect(adapter.create_request(operation.merge('amount' => '123.46')).dig('error', 'code')).to eq('idempotency_conflict')
        expect(create).to have_been_requested.once
      end

      it 'fails on missing native required recipient data and excess precision before HTTP' do
        bad_recipient = operation.merge('payout_requisite' => {})
        expect(adapter.create_request(bad_recipient).dig('error', 'code')).to eq('validation_error')
        expect(adapter.create_request(operation.merge('amount' => '123.456')).dig('error', 'code')).to eq('validation_error')
        expect(WebMock).not_to have_requested(:any, @oracle.fetch('create_url'))
      end

      it 'does not promote an unknown transfer state and reports rejected credentials' do
        unknown = Marshal.load(Marshal.dump(@oracle.fetch('status_response')))
        if provider == 'paystack'
          unknown['data']['status'] = 'new_provider_state'
        else
          unknown['items'][0]['transaction_status'] = 'NEW_PROVIDER_STATE'
        end
        stub_native_status(unknown)
        expected_error = provider == 'paypal' ? 'invalid_provider_response' : 'unknown_status'
        expect(adapter.fetch_status(native_status_operation).dig('error', 'code')).to eq(expected_error)
        stub_request(:get, @oracle.fetch('status_url')).to_return(native_response({}, status: 401))
        expect(adapter.fetch_status(native_status_operation).dig('error', 'code')).to eq('unauthorized')
      end

      it 'binds status evidence to the provider operation that was requested' do
        wrong_identity = Marshal.load(Marshal.dump(@oracle.fetch('status_response')))
        if provider == 'paystack'
          wrong_identity['data']['transfer_code'] = 'TRF_other00000001'
        else
          wrong_identity['batch_header']['payout_batch_id'] = 'BATCHOTHER001'
        end
        stub_native_status(wrong_identity)
        expect(adapter.fetch_status(native_status_operation).dig('error', 'code')).to eq('provider_id_mismatch')
      end

      if provider == 'paystack'
        it 'uses data.status rather than the successful HTTP-envelope boolean for failures, OTP and reversals' do
          { 'failed' => 'rejected', 'otp' => 'in_progress', 'reversed' => 'reversed' }.each do |state, expected|
            body = Marshal.load(Marshal.dump(@oracle.fetch('status_response')))
            body['data']['status'] = state
            stub_native_status(body)
            fresh_adapter = @service_class.new(credentials: @oracle.fetch('credentials'))
            expect(fresh_adapter.fetch_status(native_status_operation)).to include('success' => true, 'status' => expected)
          end
        end
      else
        it 'does not approve a processed batch containing a failed, missing or unrelated payout item' do
          body = Marshal.load(Marshal.dump(@oracle.fetch('status_response')))
          body['items'][0]['transaction_status'] = 'FAILED'
          stub_native_status(body)
          expect(adapter.fetch_status(native_status_operation)).to include('status' => 'rejected')
          body['items'][0]['payout_item']['sender_item_id'] = 'different_merchant_operation'
          stub_native_status(body)
          expect(adapter.fetch_status(native_status_operation).dig('error', 'code')).to eq('ambiguous_item_evidence')
          body.delete('items')
          stub_native_status(body)
          expect(adapter.fetch_status(native_status_operation).dig('error', 'code')).to eq('missing_item_evidence')
        end
      end
    end
  end
end
