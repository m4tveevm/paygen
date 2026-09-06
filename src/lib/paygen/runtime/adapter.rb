# frozen_string_literal: true

require 'base64'
require 'bigdecimal'
require 'json'
require 'json_schemer'
require 'time'
require 'timeout'
require_relative 'security'
require_relative 'result_codec'
require_relative '../mapping_rule'
require_relative '../response_bindings'

module Paygen
  module Runtime
    # Backend seam: generated classes include this module below BaseService.
    # Public results use string keys, exact routing identities and redacted data.
    module Adapter
      class ParameterValidationError < ArgumentError; end
      TRANSPORT_HEADERS = %w[host content-length transfer-encoding connection proxy-authorization proxy-connection te trailer upgrade expect].freeze

      DEFAULT_OPERATION_ATTRIBUTES = %w[
        id amount currency payout_requisite provider_operation_id provider_id
        provider_payment_id provider_item_id idempotency_key balance_account_id
      ].freeze

      def configure_paygen(credentials: {}, transport: nil, base_url: nil, mode: 'sandbox', account: nil,
                           token_provider: nil, state_store: nil, clock: nil, allow_local: false,
                           allowed_attributes: [], state_namespace: nil)
        @paygen_credentials = stringify(credentials)
        @paygen_sensitive_values = []
        @paygen_allow_local = allow_local
        @paygen_transport = transport || HTTPTransport.new(allow_local: allow_local)
        @paygen_mode = mode.to_s.dup.freeze
        @paygen_account = (account || @paygen_credentials['account'])&.to_s&.dup&.freeze
        # A shared store cannot infer merchant identity from rotating secrets.
        # Hosts must supply a stable, non-secret account or integration namespace.
        @paygen_external_store = !state_store.nil?
        @paygen_state_namespace = (state_namespace || @paygen_account)&.to_s&.dup&.freeze
        @paygen_token_provider = token_provider
        @paygen_store = state_store || MemoryStateStore.new
        @paygen_clock = clock || -> { Time.now }
        # Only trusted application code may extend object attribute access.
        # Profile mappings can never opt into invoking arbitrary model methods.
        @paygen_operation_attributes = (DEFAULT_OPERATION_ATTRIBUTES + Array(allowed_attributes).map(&:to_s)).uniq.freeze
        @paygen_base_url_override = base_url
        @paygen_configured = true
        self
      end

      def paygen_config
        self.class::PAYGEN_CONFIG
      end

      def check_conditions(operation, request_method = 'create')
        ensure_configured
        base_result = super(operation, request_method) if defined?(super)
        return base_result if paygen_result_failed?(base_result)

        body = build_body(operation, request_method.to_s)
        problems = []
        if request_method.to_s == 'create'
          amount = paygen_config.fetch('amount', {})
          value = minor_amount(read_path(operation, 'amount'))
          problems << 'amount must be positive' unless value.positive?
          problems << 'amount is below minimum' if amount['minimum'] && value < amount['minimum'].to_i
          problems << 'amount exceeds maximum' if amount['maximum'] && value > amount['maximum'].to_i
          currency = read_path(operation, 'currency').to_s.upcase
          currencies = Array(amount['currencies']).map(&:upcase)
          problems << 'currency is unsupported' if !currencies.empty? && !currencies.include?(currency)
          problems << 'operation id is required' if read_path(operation, 'id').to_s.empty?
        end
        schema = endpoint(request_method.to_s)['request_schema']
        if schema && !schema.empty?
          JSONSchemer.schema(validation_schema(schema)).validate(body).each do |error|
            problems << "#{error['data_pointer']}: #{error['type']}"
          end
        end
        problems.concat(Array(paygen_validate(operation, request_method.to_s, body)))
        return paygen_failure('validation_error', details: { 'violations' => problems }) unless problems.empty?

        { 'success' => true, 'status' => 'valid' }
      rescue ArgumentError, TypeError => e
        paygen_failure('validation_error', details: { 'reason' => e.message })
      end

      def create_request(operation, request_method = 'create')
        execute(request_method.to_s, operation)
      end

      def fetch_status(operation)
        execute('status', operation)
      end

      def cancel(operation)
        execute('cancel', operation)
      end

      def balance
        execute('balance', {})
      end

      def process_callback(payload, raw_body: nil, headers: {})
        ensure_configured
        return paygen_failure('state_namespace_required') unless state_namespace_valid?

        config = paygen_config.fetch('callback', {})
        return paygen_failure('callback_not_configured') if config.empty?
        return paygen_failure('missing_raw_body') unless raw_body.is_a?(String)
        return paygen_failure('payload_too_large') if raw_body.bytesize > 1_048_576

        parsed = JSON.parse(raw_body)
        return paygen_failure('payload_mismatch') unless stringify(payload) == parsed
        return paygen_failure('invalid_signature') unless verify_callback(parsed, raw_body, stringify(headers))
        schema = endpoint('callback')['request_schema']
        return paygen_failure('invalid_callback') if schema && !JSONSchemer.schema(validation_schema(schema)).valid?(parsed)

        mismatch = identity_mismatch(parsed, config)
        return paygen_failure(mismatch) if mismatch
        constraints = config.fetch('constraints', {})
        return paygen_failure('callback_scope_mismatch') unless constraints.all? { |path, value| read_path(parsed, path) == value }

        provider_id = read_path(parsed, config.fetch('id', 'id'))
        return paygen_failure('missing_provider_id') if provider_id.to_s.empty?
        return state_migration_failure if legacy_state?(provider_id: provider_id)

        provider_status = read_path(parsed, config.fetch('status', 'status'))
        event = read_path(parsed, config.fetch('event', 'event'))
        events = config.fetch('events', {})
        return paygen_failure('unsupported_event') if !events.empty? && !events.key?(event)

        expected = events[event]
        return paygen_failure('event_status_mismatch') if expected && provider_status && expected != provider_status

        provider_status ||= expected
        result = status_result(provider_status, provider_id, parsed)
        return result unless result['success']

        # A signature authenticates bytes; replay identity describes the event.
        # JSON whitespace and object-key order must not create a second event.
        event_id = read_path(parsed, config['event_id'])
        event_id = Digest::SHA256.hexdigest(JSON.generate(canonical_json(parsed))) if event_id.to_s.empty?
        ordering = callback_order(parsed, config)
        @paygen_store.synchronize do |state|
          key = lifecycle_key(provider_id)
          previous = state[key] || { 'events' => [], 'status' => nil, 'provider_status' => nil, 'order' => nil }
          if previous['events'].include?(event_id.to_s)
            retained_result(previous, 'duplicate')
          elsif callback_out_of_order?(ordering, previous['order'])
            retained_result(previous, 'out_of_order')
          elsif !allowed_transition?(previous, result)
            retained_result(previous, 'invalid_transition')
          else
            result['external_id'] = read_path(parsed, config['external_id']) if config['external_id']
            # Event delivery and terminal effects are different identities:
            # pending -> processing may both map to in_progress, but must still
            # deliver the new evidence. A new terminal event updates metadata
            # without invoking an already applied terminal effect twice.
            same_terminal_outcome = %w[approved rejected reversed].include?(result['status']) &&
                                    previous['callback_status'] == result['status']
            applied = if same_terminal_outcome
                        result.merge('effect_ignored' => 'duplicate_terminal_outcome')
                      else
                        paygen_callback_result(result, parsed)
                      end
            next applied if paygen_result_failed?(applied)

            state[key] = previous.merge('events' => (previous['events'] + [event_id.to_s]).last(10_000),
                                        'status' => result['status'], 'provider_status' => provider_status.to_s,
                                        'result' => ResultCodec.dump(result), 'callback_status' => result['status'],
                                        'order' => ordering || previous['order'])
            applied
          end
        end
      rescue JSON::ParserError, ArgumentError, TypeError
        paygen_failure('invalid_callback')
      rescue SecurityError
        paygen_failure('security_denial')
      end

      # Override these methods in extensions. No Ruby code is loaded from YAML.
      def paygen_validate(_operation, _role, _body) = []
      def paygen_request(request, _role, _operation) = request
      def paygen_response(response, _role, _operation) = response
      def paygen_status(status, _payload) = status
      # Opt in from trusted extension code by calling paygen_backend_callback_result.
      # The backend must make these operations durable and idempotent itself.
      def paygen_callback_result(result, _payload) = result

      def paygen_backend_callback_result(result, payload)
        return result unless result['success'] && !result['ignored']

        method = { 'approved' => :approve_operation, 'rejected' => :reject_operation }[result['status']]
        return result unless method
        return paygen_failure('backend_callback_not_configured') unless respond_to?(method, true)

        arguments = [read_path(payload, paygen_config.fetch('callback', {}).fetch('id', 'id'))]
        error_path = paygen_config.fetch('callback', {}).fetch('error', 'error.code')
        arguments << read_path(payload, error_path) if method == :reject_operation
        outcome = __send__(method, *arguments)
        paygen_result_failed?(outcome) ? outcome : result.merge('backend_applied' => true)
      end
      # Override with (_payload, raw_body:, headers:) to verify provider evidence.
      def paygen_verify_callback(_payload, **_verification) = false
      def paygen_classify_error(error, _role, _response) = error
      def paygen_retry_decision(error, _role) = error['retryable']

      private

      def paygen_result_failed?(result)
        return result.failed? if result.respond_to?(:failed?)

        result.is_a?(Hash) && (result['success'] == false || result[:success] == false)
      end

      def ensure_configured
        configure_paygen unless @paygen_configured
      end

      def stringify(value)
        case value
        when Hash then value.to_h { |key, child| [key.to_s, stringify(child)] }
        when Array then value.map { |child| stringify(child) }
        else value
        end
      end

      def canonical_json(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical_json(value[key])] }
        when Array then value.map { |child| canonical_json(child) }
        else value
        end
      end

      def read_path(value, path)
        return nil if path.nil?
        return value if path.to_s == '$' || path.to_s.empty?

        parts = path.to_s.delete_prefix('$.').gsub(/\[(\d+)\]/, '.\1').split('.')
        parts.reduce(value) do |object, part|
          if object.is_a?(Hash)
            object.key?(part) ? object[part] : object[part.to_sym]
          elsif object.is_a?(Array) && part.match?(/\A\d+\z/)
            object[part.to_i]
          elsif object && part.match?(/\A[a-zA-Z_]\w*\z/) &&
                @paygen_operation_attributes.include?(part) &&
                !Object.instance_methods.include?(part.to_sym) && object.respond_to?(part)
            object.public_send(part)
          end
        end
      end

      def write_path(object, path, value)
        parts = path.to_s.gsub(/\[(\d+)\]/, '.\1').split('.')
        raise ArgumentError, 'mapping path exceeds limits' if parts.length > 32 || path.to_s.bytesize > 512
        if parts.any? { |part| part.match?(/\A\d+\z/) && part.to_i > 1000 }
          raise ArgumentError, 'mapping array index exceeds limit'
        end
        cursor = object
        parts.each_with_index do |part, index|
          key = cursor.is_a?(Array) ? Integer(part, 10) : part
          if index == parts.length - 1
            cursor[key] = value
          else
            cursor[key] ||= parts[index + 1].match?(/\A\d+\z/) ? [] : {}
            cursor = cursor[key]
          end
        end
      end

      def endpoint(role)
        paygen_config.fetch('endpoints', {}).fetch(role, {})
      end

      # OAS 3.0's nullable and boolean exclusive bounds predate the JSON Schema
      # dialect used by OAS 3.1. Normalize those keywords without mutating source.
      def validation_schema(value)
        return value if paygen_config.fetch('openapi', '').start_with?('3.1.')
        return value unless value.is_a?(Hash)

        schema = value.dup
        %w[properties patternProperties $defs definitions dependentSchemas].each do |key|
          next unless schema[key].is_a?(Hash)

          schema[key] = schema[key].to_h { |name, child| [name, validation_schema(child)] }
        end
        %w[additionalProperties unevaluatedProperties items contains propertyNames not if then else].each do |key|
          schema[key] = validation_schema(schema[key]) if schema.key?(key)
        end
        %w[allOf anyOf oneOf prefixItems].each do |key|
          schema[key] = schema[key].map { |child| validation_schema(child) } if schema[key].is_a?(Array)
        end
        if schema.delete('nullable') == true && schema['type']
          schema['type'] = (Array(schema['type']) + ['null']).uniq
        end
        %w[Minimum Maximum].each do |suffix|
          key = "exclusive#{suffix}"
          next unless [true, false].include?(schema[key])

          exclusive = schema.delete(key)
          bound = suffix.downcase
          schema[key] = schema.delete(bound) if exclusive && schema.key?(bound)
        end
        schema
      end

      def server_for(role)
        return @paygen_base_url_override unless @paygen_base_url_override.nil?

        servers = Array(endpoint(role)['servers'])
        servers = Array(paygen_config['servers']) if servers.empty?
        raise ArgumentError, "no server configured for #{role}" if servers.empty?

        annotated = servers.map { |item| [item, server_mode(item)] }
        server = annotated.find { |_item, mode| mode == @paygen_mode }&.first
        if server.nil? && annotated.any? { |_item, mode| mode }
          raise ArgumentError, "no #{@paygen_mode} server configured for #{role}"
        end
        server ||= servers.first
        server_url(server)
      end

      def server_mode(server)
        url = server_url(server)
        if server.is_a?(Hash)
          explicit = server['mode'] || server['x-paygen-mode']
          return explicit.to_s unless explicit.to_s.empty?

          description = server['description'].to_s
          return 'sandbox' if description.match?(/\b(?:sandbox|test|testing)\b/i)
          return 'production' if description.match?(/\b(?:production|prod|live)\b/i)
        end
        host = URI.parse(url.to_s).hostname.to_s
        return 'sandbox' if host.match?(/(?:\A|[.-])(?:sandbox|test|testing)(?:[.-]|\z)/i)
        return 'production' if host.match?(/(?:\A|[.-])(?:production|prod|live)(?:[.-]|\z)/i)

        nil
      rescue URI::InvalidURIError
        raise SecurityError, 'Invalid server URL'
      end

      def server_url(server)
        return server unless server.is_a?(Hash)

        server.fetch('url').gsub(/\{([^{}]+)\}/) do
          name = Regexp.last_match(1)
          variable = server.fetch('variables', {})[name]
          unless variable.is_a?(Hash) && variable['default'].is_a?(String)
            raise ArgumentError, "missing server variable default #{name}"
          end

          variable['default']
        end
      end

      def minor_amount(value)
        raise ArgumentError, 'amount must be a decimal string or Integer' if value.is_a?(Float) || value.nil?
        raise ArgumentError, 'amount exceeds precision limit' if value.to_s.length > 64
        raise ArgumentError, 'invalid decimal amount' unless value.to_s.match?(/\A-?\d+(?:\.\d+)?\z/)

        amount = BigDecimal(value.to_s)
        config = paygen_config.fetch('amount', {})
        scale = config.fetch('input_unit', 'major') == 'minor' ? 1 : Integer(config.fetch('scale', 100))
        raise ArgumentError, 'scale must be a positive power of ten' unless scale.positive? && scale.to_s.match?(/\A10*\z/)
        minor = amount * scale
        raise ArgumentError, 'amount exceeds currency precision' unless minor.frac.zero?

        minor.to_i
      end

      def transform(value, name)
        case name
        when nil then value
        when 'minor_units' then minor_amount(value)
        when 'decimal_number' then BigDecimal(transform(value, 'decimal_string'))
        when 'major_units', 'decimal_string'
          minor = minor_amount(value)
          scale = Integer(paygen_config.fetch('amount', {}).fetch('scale', 100))
          raise ArgumentError, 'scale must be a positive power of ten' unless scale.positive? && scale.to_s.match?(/\A10*\z/)

          digits = scale.to_s.length - 1
          sign = minor.negative? ? '-' : ''
          whole, fraction = minor.abs.divmod(scale)
          digits.zero? ? "#{sign}#{whole}" : "#{sign}#{whole}.#{fraction.to_s.rjust(digits, '0')}"
        when 'lowercase' then value.to_s.downcase
        when 'uppercase' then value.to_s.upcase
        when 'string' then value.to_s
        else raise ArgumentError, "unknown request transform: #{name}"
        end
      end

      def build_body(operation, role)
        mappings = paygen_config.fetch('request_mapping', {})
        mappings = paygen_config.fetch('request_mappings', {}).fetch(role, mappings) if role != 'create'
        return nil if mappings.empty? || (role != 'create' && !paygen_config.fetch('request_mappings', {}).key?(role))

        mappings.each_with_object({}) do |(target, rule), body|
          rule = { 'from' => rule } if rule.is_a?(String)
          raise ArgumentError, "invalid mapping rule for #{target}" unless MappingRule.valid?(rule)
          next unless MappingRule.applies?(rule) { |path| read_path(operation, path) }

          value = MappingRule.value(rule) { |path| read_path(operation, path) }
          next if value.nil? && !rule.key?('value')

          write_path(body, target, transform(value, rule['transform']))
        end
      end

      def execute(role, operation)
        ensure_configured
        return paygen_failure('state_namespace_required') unless state_namespace_valid?
        return state_migration_failure if legacy_state?(operation: operation, provider_id: operation_provider_id(operation))

        return paygen_failure('operation_not_supported') if endpoint(role).empty?
        if paygen_config['mode'] && @paygen_mode != paygen_config['mode']
          return paygen_failure('mode_mismatch')
        end
        if role == 'create'
          validation = check_conditions(operation, role)
          return validation if paygen_result_failed?(validation)
        end
        binding_failure = response_binding_preflight(role, operation)
        return binding_failure if binding_failure

        return paygen_failure('operation_identity_mismatch') if cached_identity_mismatch?(role, operation)

        request = build_request(role, operation)
        request = paygen_request(request, role, operation)
        validate_request_destination!(request, role)
        if role == 'create'
          decision = reserve_create_request(request, operation, role)
          return decision if decision

          reserved = true
        end
        response = stringify(@paygen_transport.request(**request))
        response = stringify(paygen_response(response, role, operation))
        result = interpret_response(response, role, operation)
        if role == 'create' && !result['success'] && (200..299).cover?(response['status'].to_i)
          result['error'].merge!('ambiguous' => true, 'retryable' => false, 'action' => 'reconcile_before_retry')
        end
        result = reduce_lifecycle(result) if %w[create status cancel].include?(role)
        remember_request_result(role, operation, result)
      rescue Timeout::Error, EOFError, Errno::ECONNRESET
        paygen_failure('transport_timeout', retryable: role != 'create', ambiguous: role == 'create',
                details: role == 'create' ? { 'action' => 'reconcile_before_retry', 'idempotency_key' => idempotency_key(operation) } : {})
      rescue ResponseSizeError
        paygen_failure('security_denial', ambiguous: role == 'create',
                details: role == 'create' ? { 'action' => 'reconcile_before_retry', 'idempotency_key' => idempotency_key(operation) } : {})
      rescue SecurityError
        paygen_failure('security_denial')
      rescue ParameterValidationError => e
        paygen_failure('validation_error', details: { 'reason' => e.message })
      rescue ArgumentError, TypeError, KeyError => e
        paygen_failure('configuration_error', details: { 'reason' => e.message })
      rescue SocketError, SystemCallError
        paygen_failure('transport_error', retryable: role != 'create', ambiguous: role == 'create')
      ensure
        release_inflight_request(operation) if reserved
      end

      def build_request(role, operation)
        spec = endpoint(role)
        raise SecurityError, 'Unsupported HTTP method' unless %w[get post put patch delete head options].include?(spec.fetch('method').to_s.downcase)
        path = spec.fetch('path')
        raise SecurityError, 'Endpoint path must be relative to its server' unless path.start_with?('/') && !path.start_with?('//')
        raise SecurityError, 'Unsafe endpoint path' if path.include?('..') || path.include?('\\') || path.include?('?') || path.include?('#')

        parameters = request_parameters(role)
        path = path.gsub(/\{([^}]+)\}/) do
          name = Regexp.last_match(1)
          definition = parameters.find { |item| item['in'] == 'path' && item['name'] == name } ||
                       { 'name' => name, 'in' => 'path', 'required' => true }
          value = parameter_value(operation, role, definition)
          validate_parameter!(definition, value)
          raise ParameterValidationError, "missing path parameter #{name}" if value.to_s.empty?

          serialize_simple_parameter(value, path: true)
        end
        base = Security.uri(server_for(role), allow_local: @paygen_allow_local)
        url = "#{base.to_s.sub(%r{/$}, '')}#{path}"
        headers = { 'Accept' => 'application/json' }
        idempotency_header = paygen_config.fetch('idempotency', {})['header']
        headers[idempotency_header] = idempotency_key(operation) if role == 'create' && idempotency_header
        query = []
        mapped_headers = []
        parameters.reject { |item| item['in'] == 'path' }.each do |definition|
          value = parameter_value(operation, role, definition)
          next if value.nil?

          validate_parameter!(definition, value)
          if definition['in'] == 'query'
            query.concat(serialize_query_parameter(definition, value))
          else
            mapped_headers << definition.fetch('name')
            headers[definition.fetch('name')] = serialize_simple_parameter(value)
          end
        end
        unless query.empty?
          target = URI.parse(url)
          target.query = URI.encode_www_form(query)
          url = target.to_s
        end
        reject_auth_parameter_collisions!(mapped_headers, query, role)
        url = apply_auth(headers, url)
        body = build_body(operation, role)
        if body
          encoding = spec['request_encoding'] || paygen_config['request_encoding'] || 'json'
          if encoding == 'form'
            set_content_type!(headers, 'application/x-www-form-urlencoded')
            body = URI.encode_www_form(form_pairs(body))
          elsif encoding == 'json'
            set_content_type!(headers, 'application/json')
            body = JSON.generate(json_decimal_numbers(body))
          else
            raise ArgumentError, 'unsupported request encoding'
          end
        end
        parameters.each do |definition|
          next if definition['in'] == 'path'

          value = parameter_value(operation, role, definition)
          if value.nil?
            value = if definition['in'] == 'header'
                      header(headers, definition.fetch('name'))
                    else
                      pairs = URI.decode_www_form(URI.parse(url).query.to_s).select { |key, _| key == definition['name'] }
                      pairs.first&.last
                    end
          end
          validate_parameter!(definition, value)
        end
        { method: spec.fetch('method').to_s.upcase, url: url, headers: headers, body: body }
      end

      def set_content_type!(headers, expected)
        explicit = header(headers, 'Content-Type')
        unless explicit
          headers['Content-Type'] = expected
          return
        end
        media_type, *parameters = explicit.split(';').map(&:strip)
        unless media_type.casecmp?(expected) && parameters.all? { |item| item.match?(/\Acharset="?UTF-8"?\z/i) }
          raise ArgumentError, 'Content-Type parameter does not match the UTF-8 request encoding'
        end
      end

      def json_decimal_numbers(value)
        case value
        when BigDecimal then JSON::Fragment.new(value.to_s('F'))
        when Hash then value.transform_values { |child| json_decimal_numbers(child) }
        when Array then value.map { |child| json_decimal_numbers(child) }
        else value
        end
      end

      def request_state_key(operation)
        merchant_id = read_path(operation, 'id')
        raise ArgumentError, 'operation id is required for stable idempotency' if merchant_id.to_s.empty?

        state_key('request', Digest::SHA256.hexdigest(merchant_id.to_s))
      end

      def reconcile_before_retry?
        config = paygen_config.fetch('idempotency', {})
        !(config['strategy'] == 'provider_key' && config['ttl_seconds'].is_a?(Integer) &&
          config['ttl_seconds'].positive? && [config['header'], config['body']].any? { |key| key.is_a?(String) && !key.empty? })
      end

      def reserve_create_request(request, operation, role)
        @paygen_store.synchronize do |state|
          key = request_state_key(operation)
          fingerprint = request_fingerprint(request, role)
          provider_key = idempotency_key(operation)
          wire_identities = sent_idempotency_identities(request)
          now = @paygen_clock.call.to_f
          ownership_key = state_key('idempotency', provider_key)
          ownership_keys = [ownership_key] + wire_identities.map do |identity|
            state_key('provider-identity', identity)
          end
          next paygen_failure('idempotency_conflict') if ownership_keys.any? { |owner| state[owner] && state[owner] != key }

          previous = state[key]
          previous_fingerprint = previous.is_a?(Hash) ? previous['fingerprint'] : previous
          if previous && (previous_fingerprint != fingerprint || (previous.is_a?(Hash) &&
              (previous['provider_key'] != provider_key || previous['wire_identities'] != wire_identities)))
            next paygen_failure('idempotency_conflict')
          end
          if previous
            if previous.is_a?(Hash) && previous['result']
              latest = state[lifecycle_key(ResultCodec.load(previous['result'])['provider_id'])]
              next copy_result(latest&.fetch('result', nil) || previous['result']).merge('duplicate' => true)
            end
            expired = previous.is_a?(Hash) && previous['expires_at'] && now >= previous['expires_at']
            previous['expired'] = true if expired
            if reconcile_before_retry? || !previous.is_a?(Hash) || previous['inflight'] ||
               !previous['retry_supported'] || previous['expired'] ||
               now - previous['first_attempt_at'] >= paygen_config.dig('idempotency', 'ttl_seconds') ||
               now < previous['last_attempt_at']
              next paygen_failure('reconciliation_required', ambiguous: true,
                                  details: { 'action' => 'fetch_status', 'idempotency_key' => idempotency_key(operation) })
            end
          end
          retry_supported = !reconcile_before_retry? && !wire_identities.empty?
          state[key] ||= { 'fingerprint' => fingerprint, 'provider_key' => provider_key, 'wire_identities' => wire_identities,
                          'first_attempt_at' => now, 'retry_supported' => retry_supported,
                          'expires_at' => retry_supported ? now + paygen_config.dig('idempotency', 'ttl_seconds') : nil }
          ownership_keys.each { |owner| state[owner] = key }
          state[key]['inflight'] = true
          state[key]['last_attempt_at'] = now
          nil
        end
      end

      def sent_idempotency_identities(request)
        config = paygen_config.fetch('idempotency', {})
        values = {}
        values['header'] = header(request.fetch(:headers), config['header']) if config['header'].is_a?(String)
        if config['body'].is_a?(String) && request[:body].is_a?(String)
          if header(request.fetch(:headers), 'Content-Type').to_s.start_with?('application/x-www-form-urlencoded')
            parts = config['body'].gsub(/\[(\d+)\]/, '.\1').split('.')
            name = parts.first + parts.drop(1).map { |part| "[#{part}]" }.join
            values['body'] = URI.decode_www_form(request[:body]).to_h[name]
          else
            values['body'] = read_path(JSON.parse(request[:body]), config['body'])
          end
        end
        values.filter_map do |kind, value|
          next unless (value.is_a?(String) || value.is_a?(Numeric)) && !value.to_s.empty?

          "#{kind}:#{Digest::SHA256.hexdigest(value.to_s)}"
        end
      rescue JSON::ParserError, ArgumentError
        []
      end

      def release_inflight_request(operation)
        @paygen_store.synchronize do |state|
          entry = state[request_state_key(operation)]
          entry['inflight'] = false if entry.is_a?(Hash)
        end
      end

      def remember_request_result(role, operation, result)
        return result unless %w[create status cancel].include?(role) && result['success']
        # Reconciliation must refer to the original merchant operation identity;
        # a provider id alone does not establish that relationship for all APIs.
        key = request_state_key(operation)
        @paygen_store.synchronize do |state|
          entry = state[key]
          if entry.is_a?(Hash)
            known_id = entry['result'] && ResultCodec.load(entry['result'])['provider_id']
            if known_id && result['provider_id'] != known_id
              next paygen_failure('operation_identity_mismatch')
            end
            entry['result'] = ResultCodec.dump(result)
          end
          result
        end
      rescue ArgumentError
        result
      end

      def cached_identity_mismatch?(role, operation)
        return false unless %w[status cancel].include?(role)

        supplied_id = operation_provider_id(operation)
        return false unless supplied_id

        key = request_state_key(operation)
        @paygen_store.synchronize do |state|
          stored = state[key].is_a?(Hash) && state[key]['result']
          known_id = stored && ResultCodec.load(stored)['provider_id']
          known_id && known_id.to_s != supplied_id.to_s
        end
      rescue ArgumentError
        false
      end

      def request_parameters(role)
        header_names = []
        Array(endpoint(role)['parameters']).each do |definition|
          unless definition.is_a?(Hash) && definition['name'].is_a?(String)
            raise ArgumentError, 'invalid request parameter definition'
          end
          location = definition['in']
          if location == 'header'
            normalized = definition.fetch('name').downcase
            raise ArgumentError, 'duplicate case-insensitive header parameter' if header_names.include?(normalized)
            raise ArgumentError, 'transport-controlled header parameter is not supported' if TRANSPORT_HEADERS.include?(normalized)

            header_names << normalized
          end
          raise ArgumentError, "unsupported parameter location #{location}" unless %w[path query header].include?(location)
          expected_style = location == 'query' ? 'form' : 'simple'
          unless definition.fetch('style', expected_style) == expected_style
            raise ArgumentError, "unsupported #{location} parameter style #{definition['style']}"
          end
          if definition.key?('content') || definition['allowReserved'] == true
            raise ArgumentError, "unsupported parameter serialization for #{location} #{definition['name']}"
          end
        end
      end

      def parameter_value(operation, role, definition)
        name, location = definition.values_at('name', 'in')
        mappings = paygen_config.fetch('parameter_mapping', {}).fetch(role, {})
        local = mappings.fetch(location, {})
        raise ArgumentError, "parameter_mapping.#{role}.#{location} must be an object" unless local.is_a?(Hash)

        rule = local[name]
        rule = mappings[name] if rule.nil? && location == 'path'
        if rule.nil?
          value = read_path(operation, name)
          if location == 'path' && value.nil? && name.match?(/(?:\Aid\z|(?:_id|Id)\z)/)
            value = operation_provider_id(operation)
          end
          return value
        end
        rule = { 'from' => rule } if rule.is_a?(String)
        unless rule.is_a?(Hash) && (rule.keys & %w[from value credential]).length == 1
          raise ArgumentError, "invalid parameter mapping for #{location} #{name}"
        end
        value = if rule.key?('value')
                  rule['value']
                elsif rule.key?('credential')
                  credential(rule['credential'])
                else
                  found = read_path(operation, rule['from'])
                  if found.nil? && %w[provider_id provider_operation_id provider_payment_id].include?(rule['from'])
                    found = operation_provider_id(operation)
                  end
                  found
                end
        return nil if value.nil?

        value = transform(value, rule['transform'])
        @paygen_sensitive_values << value if rule.key?('credential')
        value
      end

      def operation_provider_id(operation)
        %w[provider_operation_id provider_id provider_payment_id].each do |name|
          value = read_path(operation, name)
          return value unless value.nil? || value.to_s.empty?
        end
        nil
      end

      def validate_parameter!(definition, value)
        name, location = definition.values_at('name', 'in')
        if value.nil?
          raise ParameterValidationError, "missing #{location} parameter #{name}" if definition['required'] || location == 'path'

          return
        end
        values = value.is_a?(Array) ? value : [value]
        if values.empty? && definition['required']
          raise ParameterValidationError, "empty required #{location} parameter #{name}"
        end
        scalar = lambda do |item|
          number = item.is_a?(Integer) || ((item.is_a?(Float) || item.is_a?(BigDecimal)) && item.finite?)
          item.is_a?(String) || number || [true, false].include?(item)
        end
        unless values.length <= 1000 && values.all?(&scalar)
          raise ArgumentError, "unsupported object or nested parameter serialization for #{location} #{name}"
        end
        schema = definition.fetch('schema', {})
        errors = JSONSchemer.schema(validation_schema(schema)).validate(value).to_a
        return if errors.empty?

        kinds = errors.map { |error| error['type'] }.uniq.join(', ')
        raise ParameterValidationError, "invalid #{location} parameter #{name}: #{kinds}"
      end

      def serialize_simple_parameter(value, path: false)
        values = value.is_a?(Array) ? value : [value]
        values.map do |item|
          next(item.is_a?(BigDecimal) ? item.to_s('F') : item.to_s) unless path
          raise SecurityError, 'Unsafe path parameter' if %w[. ..].include?(item.to_s)

          URI.encode_www_form_component(item.to_s).gsub('+', '%20')
        end.join(',')
      end

      def serialize_query_parameter(definition, value)
        if value.is_a?(Array) && definition.fetch('explode', true)
          value.map { |item| [definition.fetch('name'), item.to_s] }
        else
          [[definition.fetch('name'), serialize_simple_parameter(value)]]
        end
      end

      def auth_header_names
        auth = paygen_config.fetch('auth', {})
        names = auth.fetch('headers', {}).keys
        names += [auth.fetch('name', 'X-API-Key')] if auth['type'] == 'apiKey' && auth.fetch('in', 'header') == 'header'
        names += ['Authorization'] if %w[bearer oauth2 OAuth2 basic].include?(auth['type'])
        names.map(&:downcase)
      end

      def reject_auth_parameter_collisions!(headers, query, role)
        protected_headers = auth_header_names
        protected_headers += [paygen_config.fetch('idempotency', {})['header'].to_s.downcase] if role == 'create'
        if headers.any? { |name| protected_headers.include?(name.downcase) }
          raise ArgumentError, 'parameter mapping conflicts with authentication or idempotency header'
        end
        auth = paygen_config.fetch('auth', {})
        if auth['type'] == 'apiKey' && auth['in'] == 'query' && query.any? { |name, _| name == auth['name'] }
          raise ArgumentError, 'parameter mapping conflicts with authentication query parameter'
        end
      end

      def request_fingerprint(request, role)
        url = URI.parse(request.fetch(:url))
        auth = paygen_config.fetch('auth', {})
        if auth['type'] == 'apiKey' && auth['in'] == 'query'
          pairs = URI.decode_www_form(url.query.to_s).reject { |name, _| name == auth['name'] }
          url.query = pairs.empty? ? nil : URI.encode_www_form(pairs)
        end
        headers = request_parameters(role).filter_map do |definition|
          next unless definition['in'] == 'header'
          next if auth_header_names.include?(definition['name'].downcase)
          next if definition['name'].casecmp?(paygen_config.fetch('idempotency', {})['header'].to_s)

          [definition['name'].downcase, header(request.fetch(:headers), definition['name'])]
        end.sort
        Digest::SHA256.hexdigest(JSON.generate([request.fetch(:method), url.to_s, headers, request[:body]]))
      end

      def form_pairs(value, prefix = nil)
        case value
        when Hash then value.flat_map { |key, child| form_pairs(child, prefix ? "#{prefix}[#{key}]" : key) }
        when Array then value.each_with_index.flat_map { |child, index| form_pairs(child, "#{prefix}[#{index}]") }
        when BigDecimal then [[prefix, value.to_s('F')]]
        else [[prefix, value]]
        end
      end

      def idempotency_key(operation)
        config = paygen_config.fetch('idempotency', {})
        explicit = read_path(operation, config.fetch('from', 'idempotency_key'))
        return explicit.to_s unless explicit.to_s.empty?

        id = read_path(operation, 'id')
        raise ArgumentError, 'operation id is required for stable idempotency' if id.to_s.empty?

        hex = Digest::SHA256.hexdigest(state_key('provider-key', id.to_s))[0, 32]
        hex[12] = '5'
        hex[16] = ((hex[16].to_i(16) & 3) | 8).to_s(16)
        [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join('-')
      end

      def credential(name)
        value = @paygen_credentials[name.to_s]
        raise ArgumentError, "missing credential #{name}" if value.to_s.empty?
        raise SecurityError, 'Credential contains control characters' if value.to_s.match?(/[\r\n\x00]/)

        value
      end

      def apply_auth(headers, url)
        auth = paygen_config.fetch('auth', {})
        case auth['type']
        when nil, 'none' then nil
        when 'apiKey'
          value = credential(auth.fetch('credential', 'api_key'))
          if auth.fetch('in', 'header') == 'header'
            headers[auth.fetch('name', 'X-API-Key')] = value
          elsif auth['in'] == 'query'
            target = URI.parse(url)
            target.query = URI.encode_www_form(URI.decode_www_form(target.query.to_s) + [[auth.fetch('name'), value]])
            url = target.to_s
          else
            raise ArgumentError, 'unsupported API key location'
          end
        when 'bearer', 'oauth2', 'OAuth2'
          token = if auth['type'].downcase == 'oauth2' && @paygen_token_provider
                    @paygen_token_provider.call(scopes: auth.fetch('scopes', []), account: @paygen_account)
                  else
                    credential(auth.fetch('credential', 'access_token'))
                  end
          raise SecurityError, 'Invalid bearer token' if token.to_s.empty? || token.to_s.match?(/[\r\n\x00]/)

          headers['Authorization'] = "Bearer #{token}"
          @paygen_sensitive_values << token
        when 'basic'
          user = credential(auth.fetch('username', 'username'))
          password = credential(auth.fetch('password', 'password'))
          headers['Authorization'] = "Basic #{Base64.strict_encode64("#{user}:#{password}")}"
          @paygen_sensitive_values << headers['Authorization']
        else raise ArgumentError, 'unsupported authentication type'
        end
        auth.fetch('headers', {}).each do |name, source|
          if source.is_a?(Hash)
            headers[name] = if source.key?('value')
                              source['value'].to_s
                            elsif source['credential'] == 'account'
                              @paygen_account || credential('account')
                            else
                              credential(source.fetch('credential'))
                            end
          else
            headers[name] = source == 'account' ? @paygen_account.to_s : credential(source)
          end
        end
        url
      end

      def validate_request_destination!(request, role)
        unless %w[GET POST PUT PATCH DELETE HEAD OPTIONS].include?(request.fetch(:method).to_s.upcase)
          raise SecurityError, 'Unsupported HTTP method'
        end
        target = Security.uri(request.fetch(:url), allow_local: @paygen_allow_local)
        base = Security.uri(server_for(role), allow_local: @paygen_allow_local)
        unless [target.scheme, target.hostname, target.port] == [base.scheme, base.hostname, base.port]
          raise SecurityError, 'Request hook changed destination origin'
        end
        if base.query || base.fragment
          raise SecurityError, 'Server URL cannot contain query or fragment'
        end
        names = request.fetch(:headers).keys.map { |name| name.to_s.downcase }
        raise SecurityError, 'Duplicate HTTP header names' unless names.uniq.length == names.length
        raise SecurityError, 'Transport-controlled HTTP header' if names.any? { |name| TRANSPORT_HEADERS.include?(name) }

        request.fetch(:headers).each do |key, value|
          raise SecurityError, 'Invalid HTTP header' if key.to_s.match?(/[\r\n:\x00]/) || value.to_s.match?(/[\r\n\x00]/)
        end
      end

      def response_config(role)
        config = paygen_config.fetch('response', {})
        config.merge(config.fetch('roles', {}).fetch(role, {}))
      end

      def response_binding_preflight(role, operation)
        bindings = paygen_config.fetch('response_bindings', {})
        unless bindings.is_a?(Hash) && bindings.all? { |name, rule| ResponseBindings.valid?(name, rule) }
          raise ArgumentError, 'invalid response bindings configuration'
        end
        bindings.each do |name, rule|
          next unless rule['roles'].include?(role) && rule['required']

          expected = read_path(operation, rule['operation_path'])
          if expected.nil?
            return paygen_failure('response_binding_input_missing', details: { 'binding' => name })
          end
          valid = correlation_input_valid?(name, expected)
          return paygen_failure('response_binding_input_invalid', details: { 'binding' => name }) unless valid
        end
        nil
      end

      def response_binding_failure(payload, role, operation)
        paygen_config.fetch('response_bindings', {}).each do |name, rule|
          next unless rule['roles'].include?(role)

          actual = read_path(payload, rule['response_path'])
          next if actual.nil? && !rule['required']

          expected = read_path(operation, rule['operation_path'])
          code = if actual.nil?
                   'missing_response_evidence'
                 elsif expected.nil?
                   'response_binding_input_missing'
                 elsif !correlation_equal?(name, actual, expected, rule)
                   'response_binding_mismatch'
                 end
          next unless code

          details = { 'binding' => name }
          details['action'] = 'reconcile_before_retry' if role == 'create'
          return paygen_failure(code, ambiguous: role == 'create', details: details)
        end
        nil
      end

      def correlation_scalar?(name, value)
        name == 'currency' ? value.is_a?(String) && !value.empty? :
          (value.is_a?(String) && !value.empty?) || value.is_a?(Integer)
      end

      def correlation_input_valid?(name, value)
        return correlation_scalar?(name, value) unless name == 'amount'

        minor_amount(value)
        true
      rescue ArgumentError, TypeError
        false
      end

      def correlation_equal?(name, actual, expected, rule)
        if name == 'amount'
          response_minor_amount(actual, rule.fetch('response_unit')) == minor_amount(expected)
        else
          correlation_scalar?(name, actual) && correlation_scalar?(name, expected) && actual == expected
        end
      rescue ArgumentError, TypeError
        false
      end

      def response_minor_amount(value, unit)
        unless value.is_a?(Integer) || value.is_a?(BigDecimal) ||
               (value.is_a?(String) && value.match?(/\A-?\d+(?:\.\d+)?\z/))
          raise ArgumentError, 'response amount must be an exact decimal or integer'
        end
        decimal = BigDecimal(value.to_s)
        raise ArgumentError, 'response amount must be finite' unless decimal.finite?

        scale = paygen_config.fetch('amount', {}).fetch('scale', 100)
        unless scale.is_a?(Integer) && scale.positive? && scale.to_s.match?(/\A10*\z/)
          raise ArgumentError, 'invalid response amount scale'
        end
        minor = unit == 'major' ? decimal * scale : decimal
        raise ArgumentError, 'response amount exceeds currency precision' unless minor.frac.zero?

        minor.to_i
      end

      def interpret_response(response, role, operation)
        status = Integer(response.fetch('status'))
        raw = response['body']
        payload = raw.is_a?(String) ? JSON.parse(raw, decimal_class: BigDecimal) : stringify(raw || {})
        mapping = response_config(role)
        duplicate = status == 409 && role == 'create' && read_path(payload, mapping.fetch('id', 'id')) &&
                    read_path(payload, mapping.fetch('status', 'status')) && !read_path(payload, mapping.fetch('error', 'error.code'))
        return classify_error(status, response, payload, role) unless (200..299).cover?(status) || duplicate

        contract_failure = response_contract_failure(response, role, status, payload)
        return contract_failure if contract_failure
        binding_failure = response_binding_failure(payload, role, operation)
        return binding_failure if binding_failure

        mismatch = identity_mismatch(payload, mapping)
        return paygen_failure(mismatch) if mismatch
        return { 'success' => true, 'status' => 'available', 'data' => safe(payload) } if role == 'balance'

        response_id = read_path(payload, mapping.fetch('id', 'id'))
        expected_id = operation_provider_id(operation)
        if %w[status cancel].include?(role) && expected_id && response_id && response_id.to_s != expected_id.to_s
          return paygen_failure('provider_id_mismatch')
        end
        provider_id = response_id || expected_id
        return paygen_failure('missing_provider_id') if provider_id.to_s.empty?

        provider_status = read_path(payload, mapping.fetch('status', 'status'))
        if mapping['items']
          items = read_path(payload, mapping['items'])
          return paygen_failure('missing_item_evidence') unless items.is_a?(Array) && !items.empty?

          matching = if mapping['item_external_id']
                       items.select { |item| read_path(item, mapping['item_external_id']).to_s == read_path(operation, 'id').to_s }
                     else
                       items
                     end
          return paygen_failure('ambiguous_item_evidence') unless matching.length == 1

          provider_status = read_path(matching.first, mapping.fetch('item_status', 'status'))
        end
        result = status_result(provider_status, provider_id, payload)
        result['provider_item_id'] = read_path(matching.first, mapping['item_id']) if mapping['items'] && mapping['item_id']
        # Batch acceptance never proves that a recipient received money.
        if mapping['scope'] == 'batch' && !mapping['items'] && result['status'] == 'approved'
          result['status'] = 'in_progress'
        end
        result['duplicate'] = true if duplicate
        result
      rescue JSON::ParserError
        return classify_error(status, response, {}, role) unless (200..299).cover?(status)

        paygen_failure('invalid_provider_response', ambiguous: role == 'create',
                       details: role == 'create' ? { 'action' => 'reconcile_before_retry' } : {})
      end

      def response_contract_failure(response, role, status, payload)
        definitions = endpoint(role).fetch('responses', {})
        return if definitions.empty?

        definition = definitions[status.to_s] || definitions["#{status.to_s[0]}XX"] || definitions['default']
        problems = []
        if !definition
          problems << 'HTTP status is not declared by the response contract'
        else
          content = definition.fetch('content', {})
          unless content.empty?
            content_type = header(response.fetch('headers', {}), 'Content-Type')&.split(';')&.first&.strip&.downcase
            content_type ||= content.key?('application/json') ? 'application/json' : (content.keys.first if content.length == 1)
            media = content[content_type] || content["#{content_type.to_s.split('/').first}/*"] || content['*/*']
            if !media
              problems << 'Content-Type is not declared by the response contract'
            elsif media.key?('schema')
              JSONSchemer.schema(validation_schema(media['schema'])).validate(payload).take(10).each do |error|
                problems << "#{error['data_pointer']}: #{error['type']}"
              end
            end
          end
        end
        return if problems.empty?

        details = { 'violations' => problems, 'http_status' => status }
        details['action'] = 'reconcile_before_retry' if role == 'create'
        paygen_failure('invalid_provider_response', ambiguous: role == 'create', details: details)
      end

      def status_result(provider_status, provider_id, payload)
        mapped = paygen_config.fetch('status_mapping', {})[provider_status.to_s]
        unless mapped
          return paygen_failure('unknown_status', details: { 'provider_status' => provider_status,
                                                      'action' => 'reconcile' }).merge('provider_id' => provider_id.to_s)
        end

        mapped = paygen_status(mapped, payload)
        # Routing identities are opaque contract values. Redact untrusted payload
        # data separately, never an ID that the next status/cancel request uses.
        { 'success' => true, 'status' => mapped, 'provider_id' => provider_id.to_s,
          'provider_status' => provider_status.to_s, 'data' => safe(payload) }
      end

      def identity_mismatch(payload, mapping)
        account_path = mapping['account_field'] || paygen_config['account_field']
        mode_path = mapping['mode_field'] || paygen_config['mode_field']
        return 'account_not_configured' if account_path && @paygen_account.to_s.empty?
        if account_path && @paygen_account && read_path(payload, account_path).to_s != @paygen_account.to_s
          return 'account_mismatch'
        end
        expected = mapping.fetch('mode_values', paygen_config.fetch('mode_values', {})).fetch(@paygen_mode, @paygen_mode)
        return 'mode_mismatch' if mode_path && read_path(payload, mode_path) != expected

        nil
      end

      def classify_error(status, response, payload, role)
        defaults = case status
                   when 401, 403 then ['authentication_error', false]
                   when 404 then ['not_found', false]
                   when 409 then ['state_conflict', false]
                   when 429 then ['rate_limit', true]
                   when 500..599 then ['provider_unavailable', role != 'create']
                   when 300..399 then ['redirect_denied', false]
                   else ['provider_rejected', false]
                   end
        overrides = paygen_config.fetch('errors', {})
        rule = overrides.fetch(status.to_s, {}).merge(overrides.fetch('roles', {}).fetch(role, {}).fetch(status.to_s, {}))
        retryable = rule.key?('action') ? rule['action'] == 'retry' : defaults[1]
        error = { 'code' => rule.fetch('code', defaults[0]), 'retryable' => retryable,
                  'http_status' => status, 'provider_code' => read_path(payload, response_config(role).fetch('error', 'error.code')) }
        if status == 429
          value = header(response['headers'] || {}, 'Retry-After')
          error['retry_after'] = retry_after(value) if value
        end
        error['ambiguous'] = true if role == 'create' && status >= 500
        error = paygen_classify_error(error, role, response)
        error['retryable'] = !!paygen_retry_decision(error, role)
        error['retryable'] = false if error['ambiguous']
        if role == 'create' && reconcile_before_retry?
          error['retryable'] = false
          error['action'] = 'reconcile_before_retry'
        end
        { 'success' => false, 'status' => 'error', 'error' => safe(error.compact) }
      end

      def retry_after(value)
        return [[Integer(value), 0].max, 86_400].min if value.to_s.match?(/\A\d+\z/)

        [[(Time.httpdate(value.to_s) - @paygen_clock.call).ceil, 0].max, 86_400].min
      rescue ArgumentError
        1
      end

      def header(headers, name)
        pair = headers.find { |key, _| key.to_s.casecmp?(name) }
        pair && Array(pair[1]).first
      end

      def verify_callback(payload, raw_body, headers)
        signature = paygen_config.fetch('callback', {}).fetch('signature', {})
        algorithm = signature.fetch('algorithm', '')
        return !!paygen_verify_callback(payload, raw_body: raw_body, headers: headers) if algorithm == 'provider_verification'
        return false unless %w[hmac-sha256 stripe-v1].include?(algorithm)

        provided = header(headers, signature.fetch('header', 'X-Signature')).to_s
        secrets = signature.fetch('credentials', [signature.fetch('credential', 'callback_secret')])
        return false unless secrets.is_a?(Array) && %w[hex base64].include?(signature.fetch('encoding', 'hex'))
        signed = raw_body
        candidates = [provided.delete_prefix(signature.fetch('prefix', ''))]
        if algorithm == 'stripe-v1'
          components = provided.split(',').map { |part| part.strip.split('=', 2) }
          timestamp = components.find { |key, _| key == 't' }&.last
          return false unless timestamp&.match?(/\A\d+\z/)
          return false if (@paygen_clock.call.to_i - timestamp.to_i).abs > signature.fetch('tolerance', 300)

          signed = "#{timestamp}.#{raw_body}"
          candidates = components.filter_map { |key, value| value if key == 'v1' }
        end
        secrets.map do |name|
          secret = @paygen_credentials[name.to_s]
          next false if secret.to_s.empty?
          if signature['key_encoding'] == 'hex'
            next false unless secret.is_a?(String) && secret.match?(/\A(?:[0-9a-fA-F]{2})+\z/)

            secret = [secret].pack('H*')
          end
          digest = OpenSSL::HMAC.digest('SHA256', secret, signed)
          expected = signature.fetch('encoding', 'hex') == 'base64' ? Base64.strict_encode64(digest) : digest.unpack1('H*')
          candidates.map { |candidate| Security.secure_compare(expected, candidate) }.any?
        end.any?
      end

      def callback_order(payload, config)
        sequence = read_path(payload, config['sequence'])
        value = read_path(payload, config['timestamp'])
        order = {}
        order['sequence'] = Integer(sequence) unless sequence.nil?
        order['timestamp'] = value.is_a?(Numeric) ? value : Time.iso8601(value).to_f unless value.nil?
        order unless order.empty?
      end

      def callback_out_of_order?(current, previous)
        return false unless current.is_a?(Hash) && previous.is_a?(Hash)

        # Sequence numbers and Unix timestamps have unrelated units. Compare
        # the same evidence on both events, preferring the provider sequence.
        field = %w[sequence timestamp].find { |name| current.key?(name) && previous.key?(name) }
        field && current[field] < previous[field]
      end

      def lifecycle_key(provider_id)
        state_key('lifecycle', provider_id.to_s)
      end

      def state_namespace_valid?
        !@paygen_external_store || !@paygen_state_namespace.to_s.strip.empty?
      end

      def legacy_state?(operation: nil, provider_id: nil)
        return false unless @paygen_external_store

        keys = []
        merchant_id = read_path(operation, 'id') if operation
        # Adding a required account must not silently bypass reservations made
        # by the old unscoped implementation. Their ownership is ambiguous and
        # can only be resolved by reviewed migration, not an inferred new owner.
        [@paygen_account, nil].uniq.each do |old_account|
          prefix = [paygen_config['provider'], @paygen_mode, old_account].join(':')
          if merchant_id && !merchant_id.to_s.empty?
            keys << "request:#{prefix}:#{Digest::SHA256.hexdigest(merchant_id.to_s)}"
            explicit_key = read_path(operation, paygen_config.fetch('idempotency', {}).fetch('from', 'idempotency_key'))
            keys << "idempotency:#{prefix}:#{explicit_key}" unless explicit_key.to_s.empty?
          end
          keys << "lifecycle:#{prefix}:#{provider_id}" unless provider_id.to_s.empty?
        end
        @paygen_store.synchronize { |state| keys.any? { |key| state.key?(key) } }
      end

      def state_migration_failure
        paygen_failure('state_migration_required', ambiguous: true,
                       details: { 'action' => 'reconcile_and_migrate_state' })
      end

      def state_key(kind, *identity)
        # JSON tuples are unambiguous even when an identity contains separators.
        JSON.generate([kind, paygen_config['provider'].to_s, @paygen_mode,
                       @paygen_account&.to_s, @paygen_state_namespace, *identity])
      end

      def copy_result(result)
        ResultCodec.load(result)
      end

      def retained_result(previous, reason)
        copy_result(previous.fetch('result')).merge('ignored' => reason)
      end

      def reduce_lifecycle(result)
        return result unless result['success']

        @paygen_store.synchronize do |state|
          key = lifecycle_key(result.fetch('provider_id'))
          previous = state[key] || { 'events' => [], 'status' => nil, 'provider_status' => nil, 'order' => nil }
          next retained_result(previous, 'invalid_transition') unless allowed_transition?(previous, result)

          state[key] = previous.merge('status' => result['status'], 'provider_status' => result['provider_status'],
                                      'result' => ResultCodec.dump(result))
          result
        end
      end

      def allowed_transition?(previous, result)
        previous_status = previous['status']
        current_status = result['status']
        return true if previous_status.nil?

        terminal = %w[approved rejected reversed]
        return false if terminal.include?(previous_status) && !terminal.include?(current_status)

        previous_provider = previous['provider_status']
        current_provider = result['provider_status']
        return true if previous_provider == current_provider && previous_status == current_status
        # Batch acceptance can report SUCCESS while the recipient remains in
        # progress. Its aggregate label must not constrain later item evidence.
        mappings = paygen_config.fetch('status_mapping', {})
        return true if previous_status == 'in_progress' && mappings[previous_provider] != previous_status

        rules = paygen_config['status_transitions']
        return Array(rules[previous_provider]).include?(current_provider) if rules && rules.key?(previous_provider)
        # An explicit reversed mapping carries reversal semantics. Other changes
        # between terminal outcomes require provider-specific transition rules.
        return true if previous_status == 'approved' && current_status == 'reversed'
        return false if terminal.include?(previous_status) && previous_status != current_status

        order = paygen_config['status_order']
        if order && order.include?(previous_provider) && order.include?(current_provider)
          return order.index(current_provider) >= order.index(previous_provider)
        end

        true
      end

      def safe(value)
        Security.redact(value, secrets: (@paygen_credentials&.values || []) + (@paygen_sensitive_values || []))
      end

      def paygen_failure(code, retryable: false, ambiguous: false, details: {})
        { 'success' => false, 'status' => 'error', 'error' => safe({ 'code' => code, 'retryable' => retryable,
                                                                'ambiguous' => ambiguous }.merge(details)) }
      end
    end
  end
end
