# frozen_string_literal: true

require 'spec_helper'
require 'paygen/runtime/adapter'

# Regression controls from an independent comparison of PR #10 (101bd1b) with
# the integrated runtime. These observe public results and outbound effects,
# not the adapter's private state-key encoding or lifecycle implementation.
RSpec.describe 'State scope boundary regressions' do
  let(:store) { Paygen::Runtime::MemoryStateStore.new }
  let(:requests) { [] }
  let(:operation) { { 'id' => 'same-merchant-operation', 'amount' => '12.34', 'currency' => 'RUB' } }
  let(:adapter_class) do
    Class.new do
      include Paygen::Runtime::Adapter

      def initialize(**configuration) = configure_paygen(**configuration)
    end.tap do |klass|
      klass.const_set(:PAYGEN_CONFIG, {
        'provider' => 'independent-scope-probe', 'mode' => 'sandbox',
        'servers' => ['https://scope-provider.example.test'],
        'amount' => { 'scale' => 100, 'currencies' => ['RUB'] },
        'request_mapping' => {
          'reference' => { 'from' => 'id' },
          'amount' => { 'from' => 'amount', 'transform' => 'minor_units' }
        },
        'idempotency' => { 'strategy' => 'provider_key', 'header' => 'Idempotency-Key', 'ttl_seconds' => 60 },
        'response' => { 'id' => 'id', 'status' => 'status' },
        'status_mapping' => { 'pending' => 'in_progress', 'cancelled' => 'rejected' },
        'endpoints' => {
          'create' => { 'method' => 'post', 'path' => '/payouts' },
          'cancel' => { 'method' => 'post', 'path' => '/payouts/{id}/cancel' }
        }
      })
    end
  end

  let(:transport) do
    recorded = requests
    Object.new.tap do |provider|
      provider.define_singleton_method(:request) do |**request|
        recorded << request
        cancellation = request[:url].end_with?('/cancel')
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('id' => cancellation ? 'existing-payout' : "provider-#{recorded.length}",
                              'status' => cancellation ? 'cancelled' : 'pending') }
      end
    end
  end

  it 'separates a literal colon from its percent-encoded spelling without changing same-scope replay' do
    adapters = ['integration:a', 'integration%3Aa'].map do |namespace|
      adapter_class.new(state_store: store, state_namespace: namespace, transport: transport)
    end
    first = adapters[0].create_request(operation)
    second = adapters[1].create_request(operation)
    expect(first).to include('success' => true, 'provider_id' => 'provider-1')
    expect(second).to include('success' => true, 'provider_id' => 'provider-2')
    expect(requests.length).to eq(2)
    expect(requests.map { |request| request[:headers].fetch('Idempotency-Key') }.uniq.length).to eq(2)

    repeated = adapter_class.new(state_store: store, state_namespace: 'integration:a', transport: transport)
                            .create_request(operation)
    expect(repeated).to include('success' => true, 'provider_id' => 'provider-1', 'duplicate' => true)
    expect(requests.length).to eq(2)
  end

  it 'refuses an unscoped cancellation before the provider or shared store can observe any effect' do
    expect(store).not_to receive(:synchronize)
    adapter = adapter_class.new(state_store: store, transport: transport)
    result = adapter.cancel(operation.merge('provider_id' => 'existing-payout'))

    expect(result.dig('error')).to include('code' => 'state_namespace_required', 'retryable' => false)
    expect(requests).to be_empty
  end
end
