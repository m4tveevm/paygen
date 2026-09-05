# frozen_string_literal: true

require_relative 'adapter'
require_relative 'simulator'

module Paygen
  module Runtime
    # Bounded, deterministic sequences run against the generated adapter. The
    # simulator supplies wire-shaped data; separate observers count commits and
    # callback applications and check returned identities and monotonic states.
    class StateFuzzer
      VERSION = 1
      MAX_CASES = 1_000
      MAX_STEPS = 100
      MAX_TOTAL_STEPS = 10_000
      MAX_SHRINK_ATTEMPTS = 100
      MODES = %w[normal lost_response expired_key numeric_id callback_order invalid_response].freeze
      ACTIONS = %w[create retry poll callback duplicate stale cancel advance].freeze
      TERMINAL = %w[approved rejected reversed cancelled].freeze

      # Only this transport's explicit provider-key contract deduplicates. An
      # unknown header has no meaning; retention expiration discards provider
      # keys independently of the adapter's reservation store.
      class AdversarialTransport < Simulator
        attr_reader :faults, :invalid_response, :wire_provider_id

        def initialize(config:, mode:, seed:, clock:)
          super(config: config, scenario: %w[lost_response expired_key].include?(mode) ? 'timeout_after_commit' : 'success',
                seed: seed, strict_auth: true)
          @mode, @clock = mode, clock
          @started_at = clock.call.to_i
          @faults = Hash.new(0)
          @commits = []
        end

        def start_step
          @invalid_response = false
          @wire_provider_id = nil
        end

        def committed_ids
          @commits.dup
        end

        def alternate_event(event)
          payload = event.fetch('payload')
          raw = JSON.pretty_generate(payload.to_a.reverse.to_h)
          event.merge('raw_body' => raw, 'headers' => sign(raw, callback_secret, 2))
        end

        private

        def idempotency_key(body, headers)
          policy = config.fetch('idempotency', {})
          unless policy['strategy'] == 'provider_key'
            @faults['unknown_idempotency_ignored'] += 1
            return nil
          end
          ttl = policy['ttl_seconds']
          if ttl.is_a?(Integer) && @clock.call.to_i - @started_at >= ttl
            @idempotency.clear
            @faults['provider_key_expired'] += 1
          end
          super
        end

        def create(body, headers)
          before = @records.length
          result = super
          return result unless result[:status].between?(200, 299)

          payload = JSON.parse(result.fetch(:body))
          mapping = config.fetch('response', {}).merge(config.dig('response', 'roles', 'create') || {})
          id_path = mapping.fetch('id', 'id')
          previous_id = get_path(payload, id_path)
          if @mode == 'numeric_id' && !config.dig('simulator', 'id_from_request')
            candidate = JSON.parse(JSON.generate(payload))
            injected_id = "sim_06ed5551082250661cad#{@commits.empty? ? '' : @commits.length}"
            set_path(candidate, id_path, injected_id)
            schema = response_schema('create', result[:status])
            if JSONSchemer.schema(schema).valid?(candidate) && @records.key?(previous_id)
              record = @records.delete(previous_id)
              record['id'] = injected_id
              @records[injected_id] = record
              @idempotency.each_value { |entry| entry['id'] = injected_id if entry['id'] == previous_id }
              payload = candidate
              @faults['numeric_provider_id'] += 1
            end
          end
          @wire_provider_id = get_path(payload, id_path)
          @commits << @wire_provider_id if @records.length > before
          if @mode == 'invalid_response'
            schema = response_schema('create', result[:status])
            candidate = invalid_payload(payload, schema)
            if candidate
              payload = candidate
              @invalid_response = true
              @faults['invalid_success_body'] += 1
            end
          end
          result.merge(body: JSON.generate(payload))
        end

        def invalid_payload(payload, schema)
          return nil if schema.empty?

          # Prefer a missing contract field, preserving otherwise plausible
          # payout status and identity. No adapter interpretation helpers run.
          Array(schema['required']).sort.each do |name|
            candidate = payload.reject { |key, _value| key == name }
            return candidate unless JSONSchemer.schema(schema).valid?(candidate)
          end
          [[], nil, 'invalid-response', {}].find { |candidate| !JSONSchemer.schema(schema).valid?(candidate) }
        end

        def status(parameters)
          if @mode == 'callback_order' && (record = record_for(parameters)) && (initial_status = mapped_status('in_progress'))
            @faults['stale_polling'] += 1
            return response(success_code('status', 200), operation_body(record.merge('status' => initial_status), 'status'))
          end
          super
        end
      end

      # Observe the public callback seam, before any application's persistence.
      # This deliberately does not inspect adapter replay keys or lifecycle data.
      module CallbackObserver
        def paygen_callback_result(result, payload)
          outcome = super
          failed = outcome.respond_to?(:failed?) ? outcome.failed? : outcome.is_a?(Hash) && (outcome['success'] == false || outcome[:success] == false)
          if !failed && StateFuzzer::TERMINAL.include?(result['status'])
            @paygen_fuzz_callback_calls << { 'provider_id' => result['provider_id'], 'status' => result['status'] }
          end
          outcome
        end
      end

      def initialize(adapter:, seed: 0)
        @adapter = adapter
        @config = adapter.paygen_config
        @seed = bounded_integer(seed, 'seed', 0, (2**63) - 1)
        @config_digest = Digest::SHA256.hexdigest(JSON.generate(canonical(@config)))
      end

      def run(cases: 100, steps: 30)
        cases = bounded_integer(cases, 'cases', 1, MAX_CASES)
        steps = bounded_integer(steps, 'steps', 1, MAX_STEPS)
        raise ArgumentError, "cases * steps must not exceed #{MAX_TOTAL_STEPS}" if cases * steps > MAX_TOTAL_STEPS

        totals = empty_coverage
        random = Random.new(@seed)
        cases.times do |index|
          trace = build_trace(index, steps, random)
          result = execute_trace(trace)
          add_coverage(totals, result.fetch('coverage'))
          next unless result['failure']

          shrunk, attempts = shrink(trace, result.fetch('failure').fetch('invariant'))
          return report(false, index + 1, totals).merge('requested_cases' => cases, 'steps_per_case' => steps,
            'failure' => result['failure'], 'trace' => trace, 'shrunk_trace' => shrunk,
            'shrink_attempts' => attempts)
        end
        report(true, cases, totals).merge('requested_cases' => cases, 'steps_per_case' => steps)
      end

      # Accept the saved report directly, favoring its minimized witness. Entire
      # trace validation precedes adapter configuration or provider interaction.
      def replay(document)
        trace = if document.is_a?(Hash) && document.key?('shrunk_trace')
                  document['shrunk_trace']
                elsif document.is_a?(Hash) && document.key?('trace')
                  document['trace']
                else
                  document
                end
        validate_trace!(trace)
        result = execute_trace(trace)
        report(!result['failure'], 1, result.fetch('coverage')).merge('seed' => trace['seed'],
          'replay' => true, 'trace' => trace, 'failure' => result['failure'])
      end

      private

      def report(success, cases, coverage)
        { 'success' => success, 'version' => VERSION, 'seed' => @seed, 'cases' => cases,
          'profile_sha256' => @config_digest, 'coverage' => coverage,
          'scope' => 'Offline state sequences against the generated adapter. Commit count, identity, terminal-state and callback-hook oracles are separate from adapter state. Wire samples are profile-derived; this is not live-provider or production-database certification.' }
      end

      def empty_coverage
        { 'actions' => {}, 'faults' => {}, 'invariants' => {}, 'skipped' => {}, 'executed_steps' => 0 }
      end

      def add_coverage(total, current)
        %w[actions faults invariants skipped].each do |section|
          current.fetch(section).each { |name, count| total[section][name] = total[section].fetch(name, 0) + count }
        end
        total['executed_steps'] += current['executed_steps']
      end

      def count(coverage, section, name)
        coverage[section][name] = coverage[section].fetch(name, 0) + 1
      end

      def build_trace(index, steps, random)
        mode = MODES[index % MODES.length]
        prefix = case mode
                 when 'lost_response' then %w[create retry poll retry]
                 when 'expired_key' then %w[create advance retry poll retry]
                 when 'numeric_id' then %w[create cancel retry]
                 when 'callback_order' then %w[create callback duplicate stale poll retry]
                 when 'invalid_response' then %w[create retry]
                 else %w[create retry poll cancel]
                 end
        actions = prefix.take(steps)
        actions << ACTIONS[random.rand(ACTIONS.length)] while actions.length < steps
        { 'version' => VERSION, 'seed' => @seed, 'case' => index, 'mode' => mode,
          'profile_sha256' => @config_digest, 'steps' => actions.map { |action| { 'action' => action } } }
      end

      def bounded_integer(value, name, minimum, maximum)
        # Float truncation and strings such as "1.0" must not alter a replay.
        unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\d+\z/))
          raise ArgumentError, "#{name} must be an integer"
        end
        number = Integer(value)
        raise ArgumentError, "#{name} must be between #{minimum} and #{maximum}" unless number.between?(minimum, maximum)

        number
      end

      def validate_trace!(trace)
        raise ArgumentError, 'Replay trace must be an object' unless trace.is_a?(Hash)
        raise ArgumentError, 'Unsupported replay version' unless trace['version'] == VERSION
        raise ArgumentError, 'Replay profile differs from this generated integration' unless trace['profile_sha256'] == @config_digest
        raise ArgumentError, 'Unknown replay mode' unless MODES.include?(trace['mode'])
        unless trace['seed'].is_a?(Integer) && trace['case'].is_a?(Integer)
          raise ArgumentError, 'Replay seed and case must be JSON integers'
        end
        bounded_integer(trace['seed'], 'trace seed', 0, (2**63) - 1)
        bounded_integer(trace['case'], 'trace case', 0, MAX_CASES - 1)
        steps = trace['steps']
        unless steps.is_a?(Array) && steps.length.between?(1, MAX_STEPS) && steps.all? do |step|
          step.is_a?(Hash) && step.keys == ['action'] && ACTIONS.include?(step['action'])
        end
          raise ArgumentError, 'Replay requires 1..100 known actions without additional arguments'
        end
      end

      def execute_trace(trace)
        coverage = empty_coverage
        now = Time.at(1_800_000_002)
        transport = AdversarialTransport.new(config: @config, mode: trace.fetch('mode'),
          seed: trace.fetch('seed') + trace.fetch('case'), clock: -> { now })
        adapter = @adapter.clone
        adapter.singleton_class.prepend(CallbackObserver)
        calls = []
        adapter.instance_variable_set(:@paygen_fuzz_callback_calls, calls)
        adapter.configure_paygen(credentials: transport.credentials, transport: transport,
          account: 'test-account', mode: @config.fetch('mode', 'sandbox'), state_store: MemoryStateStore.new,
          clock: -> { now })
        id = "fuzz-#{Digest::SHA256.hexdigest("#{trace['seed']}:#{trace['case']}")[0, 12]}"
        operation = transport.sample_operation(id: id)
        context = { 'operation' => operation, 'provider_id' => nil, 'terminal' => nil, 'callback_calls' => calls }
        failure = nil
        trace.fetch('steps').each_with_index do |step, index|
          action = step.fetch('action')
          transport.start_step
          if action == 'advance'
            now += [@config.dig('idempotency', 'ttl_seconds').to_i, 86_400].max + 1
            count(coverage, 'actions', action)
            coverage['executed_steps'] += 1
            next
          end
          result = perform(action, adapter, transport, context)
          unless result
            count(coverage, 'skipped', "#{action}_unavailable")
            next
          end
          count(coverage, 'actions', action)
          coverage['executed_steps'] += 1
          violation = observe(result, action, transport, context, coverage)
          if violation
            failure = violation.merge('step' => index, 'action' => action,
              'result' => result.slice('success', 'status', 'provider_id', 'ignored', 'error'),
              'committed_ids' => transport.committed_ids)
            break
          end
        end
        if !failure && transport.committed_ids.empty? && trace.fetch('steps').any? { |step| step['action'] == 'create' }
          failure = { 'invariant' => 'fixture_rejected', 'message' => 'No create reached the provider; these sequences do not establish payment coverage' }
        end
        coverage['faults'] = transport.faults.dup
        { 'failure' => failure, 'coverage' => coverage }
      rescue StandardError => e
        { 'failure' => { 'invariant' => 'unexpected_exception', 'message' => "#{e.class}: #{e.message}" },
          'coverage' => coverage || empty_coverage }
      end

      def perform(action, adapter, transport, context)
        operation = context.fetch('operation')
        identified = operation.merge('provider_operation_id' => context['provider_id'],
          'provider_id' => context['provider_id'], 'provider_item_id' => context['provider_id'])
        case action
        when 'create', 'retry' then adapter.create_request(operation.dup)
        when 'poll' then adapter.fetch_status(identified) if @config.dig('endpoints', 'status')
        when 'cancel' then adapter.cancel(identified) if @config.dig('endpoints', 'cancel')
        when 'callback', 'duplicate', 'stale'
          return nil unless @config['callback'] && @config.dig('callback', 'signature', 'algorithm') != 'provider_verification'

          events = transport.callback_events
          return nil if events.empty?

          event = action == 'stale' ? events.first : events.last
          event = transport.alternate_event(event) if action == 'duplicate'
          adapter.process_callback(event.fetch('payload'), raw_body: event.fetch('raw_body'), headers: event.fetch('headers'))
        end
      end

      def observe(result, action, transport, context, coverage)
        count(coverage, 'invariants', 'at_most_one_commit')
        return violation('duplicate_payout', 'One merchant operation committed more than one payout') if transport.committed_ids.length > 1

        if transport.invalid_response
          count(coverage, 'invariants', 'invalid_response_rejected')
          return violation('invalid_response_accepted', 'A response violating the declared schema was accepted') if result['success']
        end
        if result['success'] && result['provider_id'].to_s.empty?
          return violation('provider_identity_missing', 'A successful payment result omitted its provider identity')
        end
        if result['success'] && result['provider_id']
          count(coverage, 'invariants', 'provider_identity_preserved')
          unless transport.committed_ids.include?(result['provider_id'])
            return violation('provider_identity_changed', 'Returned provider identity differs from the committed provider identity')
          end
          if context['provider_id'] && result['provider_id'] != context['provider_id']
            return violation('provider_identity_changed', 'A stable operation changed its provider identity')
          end
          context['provider_id'] = result['provider_id']
        end
        if result['success']
          if context['terminal']
            count(coverage, 'invariants', 'terminal_never_pending')
            unless TERMINAL.include?(result['status'])
              return violation('terminal_rollback', 'A confirmed terminal operation returned to a nonterminal state')
            end
          end
          context['terminal'] = result['status'] if TERMINAL.include?(result['status'])
        end
        if %w[callback duplicate stale].include?(action)
          count(coverage, 'invariants', 'callback_outcome_applied_once')
          repeated = context.fetch('callback_calls').group_by { |entry| [entry['provider_id'], entry['status']] }.any? { |_key, entries| entries.length > 1 }
          return violation('duplicate_callback_application', 'The same terminal callback outcome invoked the backend seam twice') if repeated
        end
        nil
      end

      def violation(name, message)
        { 'invariant' => name, 'message' => message }
      end

      def shrink(trace, invariant)
        steps = trace.fetch('steps')
        attempts = 0
        chunk = [steps.length / 2, 1].max
        while chunk.positive? && attempts < MAX_SHRINK_ATTEMPTS
          changed = false
          start = 0
          while start < steps.length && attempts < MAX_SHRINK_ATTEMPTS
            candidate = steps.take(start) + steps.drop(start + chunk)
            break if candidate.empty?

            attempts += 1
            observed = execute_trace(trace.merge('steps' => candidate))
            if observed.dig('failure', 'invariant') == invariant
              steps = candidate
              changed = true
              break
            end
            start += chunk
          end
          chunk /= 2 unless changed
        end
        [trace.merge('steps' => steps), attempts]
      end

      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical(value[key])] }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end
    end
  end
end
