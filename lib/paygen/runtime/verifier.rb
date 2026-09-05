# frozen_string_literal: true

require_relative 'simulator'
require_relative 'adapter'

module Paygen
  module Runtime
    # Runs real adapter calls and records their observable outcomes. It does not
    # turn unavailable capabilities into passing checks.
    class Verifier
      PACKS = %w[default transport callbacks reversals].freeze

      def initialize(adapter:, simulator: nil, seed: 0, target: nil)
        @adapter = adapter
        @supplied_simulator = simulator
        @seed = Integer(seed)
        @target = target
        @config = if adapter.respond_to?(:paygen_config)
                    adapter.paygen_config
                  else
                    adapter.class.const_get(:PAYGEN_CONFIG)
                  end
      end

      def run(scenario_pack: 'default')
        raise ArgumentError, "Unknown scenario pack: #{scenario_pack}" unless PACKS.include?(scenario_pack)

        return run_remote(scenario_pack) if @target

        @checks = []
        if %w[default transport].include?(scenario_pack)
          verify_success
          verify_idempotency
          verify_timeout
          verify_rate_limit
          verify_unknown_status
          verify_cancel if @config.dig('endpoints', 'cancel')
        end
        verify_callbacks if %w[default callbacks].include?(scenario_pack) && @config['callback']
        if %w[default reversals].include?(scenario_pack)
          verify_reversal('paid_then_failed')
          verify_reversal('booked_then_returned')
          verify_batch if batch_profile?
        end
        if scenario_pack == 'default'
          verify_scope('account_mismatch') if scope_field?('account_field')
          verify_scope('mode_mismatch') if scope_field?('mode_field')
        end
        if @checks.empty?
          @checks << { 'name' => 'scenario_pack_capability', 'passed' => false,
                       'error' => 'The profile has no capabilities exercised by this scenario pack' }
        end
        failures = @checks.count { |check| !check['passed'] }
        { 'success' => failures.zero?, 'scenario_pack' => scenario_pack, 'seed' => @seed,
          'passed' => @checks.length - failures, 'failed' => failures,
          'checks' => @checks }
      end

      private

      def verify_success
        check('create_and_fetch_status', 'success') do |simulator, operation|
          created = @adapter.create_request(operation)
          assert_result(created, success: true)
          assert(!created['provider_id'].to_s.empty?, 'Create omitted provider id')
          status = final_status(with_provider_id(operation, created), 'success')
          assert_result(status, success: true, status: expected_final('success'))
          { 'created' => summary(created), 'fetched' => summary(status),
            'created_count' => simulator.evidence['created_count'] }
        end
      end

      def verify_idempotency
        check('stable_idempotency_and_payload_conflict', 'success') do |simulator, operation|
          first = @adapter.create_request(operation)
          repeated = @adapter.create_request(operation.dup)
          assert_result(first, success: true)
          assert_result(repeated, success: true)
          assert(first['provider_id'] == repeated['provider_id'], 'Retry changed provider id')
          assert(simulator.evidence['created_count'] == 1, 'Retry created another payout')
          changed_amount = (BigDecimal(operation.fetch('amount').to_s) + 1).to_s('F')
          changed_amount = changed_amount.to_i if @config.dig('amount', 'input_unit') == 'minor'
          altered = operation.merge('amount' => changed_amount)
          conflict = @adapter.create_request(altered)
          assert_result(conflict, success: false)
          assert(simulator.evidence['created_count'] == 1, 'Changed payload created another payout')
          { 'first' => summary(first), 'retry' => summary(repeated), 'conflict' => summary(conflict) }
        end
      end

      def verify_timeout
        check('timeout_after_commit_reuses_idempotency_key', 'timeout_after_commit') do |simulator, operation|
          first = @adapter.create_request(operation)
          assert_result(first, success: false)
          assert(first.dig('error', 'ambiguous') == true, 'Timeout was not classified as ambiguous')
          assert(simulator.evidence['created_count'] == 1, 'Timeout happened before commit')
          repeated = @adapter.create_request(operation)
          assert_result(repeated, success: true)
          assert(simulator.evidence['created_count'] == 1, 'Timeout retry duplicated payout')
          { 'timeout' => summary(first), 'retry' => summary(repeated) }
        end
      end

      def verify_rate_limit
        check('rate_limit_is_retryable', 'rate_limit') do |_simulator, operation|
          first = @adapter.create_request(operation)
          assert_result(first, success: false)
          assert(first.dig('error', 'retryable') == true, 'Rate limit was not retryable')
          assert(first.dig('error', 'retry_after').to_i == 1, 'Retry-After was not preserved')
          repeated = @adapter.create_request(operation)
          assert_result(repeated, success: true)
          { 'rate_limit' => summary(first), 'retry' => summary(repeated) }
        end
      end

      def verify_unknown_status
        check('unknown_status_fails_closed', 'unknown_status') do |_simulator, operation|
          result = @adapter.create_request(operation)
          assert_result(result, success: false)
          assert(result['status'] != 'approved', 'Unknown status approved a payout')
          { 'result' => summary(result) }
        end
      end

      def verify_cancel
        check('cancel_conflict_is_not_idempotent_success', 'success') do |_simulator, operation|
          first = @adapter.create_request(operation)
          assert_result(first, success: true)
          cancelled = @adapter.cancel(with_provider_id(operation, first))
          assert_result(cancelled, success: true)
          second_op = operation.merge('id' => "#{operation.fetch('id')}-terminal")
          second = @adapter.create_request(second_op)
          assert_result(second, success: true)
          identified = with_provider_id(second_op, second)
          terminal = final_status(identified, 'success')
          assert_result(terminal, success: true, status: expected_final('success'))
          conflict = @adapter.cancel(identified)
          assert_result(conflict, success: false)
          { 'cancelled' => summary(cancelled), 'terminal_conflict' => summary(conflict) }
        end
      end

      def verify_callbacks
        if @config.dig('callback', 'signature', 'algorithm') == 'provider_verification'
          check('provider_callback_fails_closed_without_verification', 'success') do |simulator, operation|
            created = @adapter.create_request(operation)
            assert_result(created, success: true)
            events = simulator.callback_events(provider_id: created['provider_id'])
            assert(!events.empty?, 'Simulator did not generate callback')
            result = deliver(events.last)
            assert_result(result, success: false)
            { 'unverified_callback' => summary(result),
              'capability' => 'Provider verification hook must verify callbacks before accepting them' }
          end
          return
        end

        check('signed_callback_duplicate_ordering_and_tampering', 'success') do |simulator, operation|
          created = @adapter.create_request(operation)
          assert_result(created, success: true)
          events = simulator.callback_events(provider_id: created['provider_id'])
          assert(events.length == 2, 'Simulator did not generate callback lifecycle')
          completed = deliver(events.last)
          expected = expected_final('success')
          assert_result(completed, success: true, status: expected)
          repeated = deliver(events.last)
          assert(repeated['status'] == expected, 'Duplicate callback rolled back payout')
          assert(repeated['ignored'] == 'duplicate', 'Duplicate callback was applied again')
          earlier = deliver(events.first)
          assert(earlier['status'] == expected, 'Earlier callback rolled back payout')
          assert(%w[out_of_order invalid_transition].include?(earlier['ignored']), 'Earlier callback was applied again')
          tampered = events.last.merge('raw_body' => "#{events.last.fetch('raw_body')} ")
          rejected = deliver(tampered)
          assert_result(rejected, success: false)
          { 'completed' => summary(completed), 'duplicate' => summary(repeated),
            'out_of_order' => summary(earlier), 'tampered' => summary(rejected) }
        end
      end

      def verify_reversal(scenario)
        check(scenario, scenario) do |_simulator, operation|
          created = @adapter.create_request(operation)
          assert_result(created, success: true)
          identified = with_provider_id(operation, created)
          approved = @adapter.fetch_status(identified)
          states = Array(@config.dig('simulator', 'scenarios', scenario, 'statuses'))
          before = states.empty? ? expected_final('success') : @config.fetch('status_mapping', {})[states.first]
          assert_result(approved, success: true, status: before)
          rejected = @adapter.fetch_status(identified)
          assert_result(rejected, success: true, status: 'rejected')
          { 'before' => summary(approved), 'after' => summary(rejected) }
        end
      end

      def verify_batch
        check('batch_success_item_failed', 'batch_success_item_failed') do |_simulator, operation|
          created = @adapter.create_request(operation)
          # A batch acknowledgement may be pending; it must never approve the
          # individual failed item merely from the enclosing batch status.
          assert(created['status'] != 'approved', 'Batch success hid a failed payout item')
          fetched = @adapter.fetch_status(with_provider_id(operation, created))
          assert(fetched['status'] == 'rejected' || fetched['success'] == false,
                 'Item failure was not reported')
          { 'created' => summary(created), 'fetched' => summary(fetched) }
        end
      end

      def verify_scope(scenario)
        check(scenario, scenario) do |simulator, operation|
          result = @adapter.create_request(operation)
          if @config.dig('callback', scenario == 'account_mismatch' ? 'account_field' : 'mode_field')
            assert_result(result, success: true)
            events = simulator.callback_events(provider_id: result['provider_id'])
            result = deliver(events.last)
          end
          assert_result(result, success: false)
          { 'result' => summary(result) }
        end
      end

      def check(name, scenario)
        simulator = if @supplied_simulator && @supplied_simulator.scenario == scenario && @checks.empty?
                      @supplied_simulator
                    else
                      Simulator.new(config: @config, scenario: scenario, seed: @seed)
                    end
        settings = { credentials: simulator.credentials, transport: simulator,
                     mode: @config.fetch('mode', 'sandbox'), account: 'test-account',
                     clock: -> { Time.at(1_800_000_002) }, state_store: MemoryStateStore.new }
        @adapter.configure_paygen(**settings)
        operation = simulator.sample_operation(id: "verify-#{Digest::SHA256.hexdigest("#{@seed}:#{name}")[0, 24]}")
        details = yield simulator, operation
        @checks << { 'name' => name, 'passed' => true, 'observed' => details,
                     'evidence' => simulator.evidence }
      rescue StandardError => e
        @checks << { 'name' => name, 'passed' => false,
                     'error' => "#{e.class}: #{e.message}",
                     'evidence' => simulator&.evidence }
      end

      def deliver(event)
        @adapter.process_callback(event.fetch('payload'), raw_body: event.fetch('raw_body'),
                                  headers: event.fetch('headers'))
      end

      def with_provider_id(operation, result)
        operation.merge('provider_id' => result['provider_id'],
                        'provider_item_id' => result['provider_item_id'] || result['provider_id'])
      end

      def batch_profile?
        @config.dig('response', 'items') || @config.dig('response', 'roles', 'status', 'items')
      end

      def expected_final(scenario)
        statuses = Array(@config.dig('simulator', 'scenarios', scenario, 'statuses'))
        mappings = @config.fetch('status_mapping', {})
        return mappings[statuses.last] if statuses.any?

        mappings.value?('approved') ? 'approved' : 'in_progress'
      end

      def final_status(operation, scenario)
        count = [Array(@config.dig('simulator', 'scenarios', scenario, 'statuses')).length, 1].max
        result = nil
        count.times { result = @adapter.fetch_status(operation) }
        result
      end

      def scope_field?(name)
        @config[name] || @config.dig('response', name) || @config.dig('callback', name)
      end

      def run_remote(scenario_pack)
        require_relative 'security'
        target = Security.uri(@target, allow_local: true)
        unless %w[127.0.0.1 ::1 localhost].include?(target.hostname) && !target.query
          raise SecurityError, 'Verification target must be an explicit loopback test server without a query'
        end
        target.hostname = '127.0.0.1' if target.hostname == 'localhost'
        unless scenario_pack == 'default'
          raise ArgumentError, 'Remote targets support the explicitly reported smoke verification only; fault packs run offline'
        end

        @checks = []
        simulator = Simulator.new(config: @config, seed: @seed)
        transport = HTTPTransport.new(allow_local: true)
        @adapter.configure_paygen(credentials: simulator.credentials, transport: transport,
                                  base_url: target.to_s, allow_local: true,
                                  account: 'test-account', mode: @config.fetch('mode', 'sandbox'))
        operation = simulator.sample_operation(id: "remote-#{Digest::SHA256.hexdigest(@seed.to_s)[0, 24]}")
        observed = {}
        begin
          observed['created'] = summary(@adapter.create_request(operation))
          assert_result(observed['created'], success: true)
          observed['retried'] = summary(@adapter.create_request(operation))
          assert_result(observed['retried'], success: true)
          assert(observed['created']['provider_id'] == observed['retried']['provider_id'], 'Remote retry changed provider id')
          observed['fetched'] = summary(final_status(with_provider_id(operation, observed['created']), 'success'))
          assert_result(observed['fetched'], success: true, status: expected_final('success'))
          @checks << { 'name' => 'remote_create_retry_and_fetch', 'passed' => true, 'observed' => observed }
        rescue StandardError => e
          @checks << { 'name' => 'remote_create_retry_and_fetch', 'passed' => false,
                       'observed' => observed, 'error' => "#{e.class}: #{e.message}" }
        end
        passed = @checks.count { |entry| entry['passed'] }
        { 'success' => passed == @checks.length, 'scenario_pack' => 'remote_smoke',
          'requested_scenario_pack' => scenario_pack, 'seed' => @seed, 'target' => target.to_s,
          'coverage' => 'Remote create, stable retry and status only. Offline fault scenarios were not executed.',
          'passed' => passed, 'failed' => @checks.length - passed, 'checks' => @checks }
      end

      def summary(result)
        result.select { |key, _value| %w[success status provider_id error duplicate ignored].include?(key) }
      end

      def assert_result(result, success:, status: nil)
        assert(result.is_a?(Hash), 'Adapter returned a non-object result')
        assert(result['success'] == success, "Expected success=#{success}; observed #{summary(result)}")
        assert(result['status'] == status, "Expected status=#{status}; observed #{summary(result)}") if status
      end

      def assert(condition, message)
        raise Paygen::Error.new(message, code: 'VERIFICATION_FAILED', exit_code: 1) unless condition
      end
    end
  end
end
