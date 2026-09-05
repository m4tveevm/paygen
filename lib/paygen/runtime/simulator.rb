# frozen_string_literal: true

require 'json'
require 'json_schemer'
require 'uri'
require 'digest'
require 'openssl'
require 'base64'
require 'timeout'
require 'stringio'
require 'time'
require 'bigdecimal'

module Paygen
  module Runtime
    # A stateful, deterministic provider transport that also implements Rack.
    # Its data model comes entirely from the generated integration profile.
    class Simulator
      SCENARIOS = %w[success timeout_after_commit rate_limit unknown_status
                     batch_success_item_failed paid_then_failed booked_then_returned
                     account_mismatch mode_mismatch].freeze
      class RequestContractError < ArgumentError
        attr_reader :status, :code

        def initialize(code, status = 400)
          @status, @code = status, code
          super(code)
        end
      end
      attr_reader :config, :scenario, :seed

      def initialize(config:, scenario: 'success', seed: 0, strict_auth: false)
        raise ArgumentError, "Unknown simulator scenario: #{scenario}" unless SCENARIOS.include?(scenario)

        @config = JSON.parse(JSON.generate(config))
        @scenario = scenario
        @seed = Integer(seed)
        @strict_auth = strict_auth
        @records = {}
        @idempotency = {}
        @requests = []
        @attempts = 0
        @mutex = Mutex.new
      end

      # In-process timeout_after_commit raises a real transport exception only
      # after the committed operation has been persisted.
      def request(method:, url:, headers: {}, body: nil)
        @mutex.synchronize do
          return response(413, error_body('payload_too_large')) if body.is_a?(String) && body.bytesize > 1_048_576

          uri = URI.parse(url)
          path = uri.path.empty? ? '/' : uri.path
          match = endpoint_match(method, path)
          return response(404, error_body('not_found')) unless match

          role, parameters = match
          reject_duplicate_headers!(headers)
          return response(401, error_body('unauthorized')) if @strict_auth && !authorized?(uri, headers)
          parameters, parsed = validate_request!(role, parameters, uri, headers, body)
          result = dispatch(role, parameters, parsed, headers)
          @requests << { 'method' => method.to_s.upcase, 'path' => path,
                         'role' => role, 'status' => result[:status],
                         'body_sha256' => Digest::SHA256.hexdigest(canonical(parsed)) }
          if result.delete(:transport_timeout)
            @requests.last['transport_timeout'] = true
            raise Timeout::Error, 'Simulated timeout after provider committed operation'
          end
          result
        end
      rescue RequestContractError => e
        response(e.status, error_body(e.code))
      rescue JSON::ParserError, URI::InvalidURIError, ArgumentError => e
        response(400, error_body('invalid_request', e.class.name))
      end

      # For an actual HTTP server the uncertainty is represented by a gateway
      # timeout. The persisted state is identical to the in-process transport.
      def call(env)
        headers = env.each_with_object({}) do |(key, value), memo|
          memo[key.delete_prefix('HTTP_').tr('_', '-')] = value if key.start_with?('HTTP_')
        end
        headers['Content-Type'] = env['CONTENT_TYPE'] if env['CONTENT_TYPE']
        path = "#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
        query = env['QUERY_STRING'].to_s
        result = request(method: env.fetch('REQUEST_METHOD'),
                         url: "http://simulator.local#{path}#{query.empty? ? '' : "?#{query}"}",
                         headers: headers, body: env.fetch('rack.input', StringIO.new).read(1_048_577))
        rack_response(result)
      rescue Timeout::Error
        rack_response(response(504, error_body('timeout_after_commit')))
      end

      def evidence
        @mutex.synchronize do
          { 'scenario' => scenario, 'seed' => seed, 'created_count' => @records.length,
            'requests' => JSON.parse(JSON.generate(@requests)) }
        end
      end

      def credentials
        auth = config.fetch('auth', {})
        signature = config.dig('callback', 'signature') || {}
        result = { auth.fetch('credential', 'api_key') => 'paygen-simulator-key',
                   signature.fetch('credential', 'callback_secret') => callback_secret }
        if auth['type'] == 'basic'
          result[auth.fetch('username', 'username')] = 'paygen-simulator-user'
          result[auth.fetch('password', 'password')] = 'paygen-simulator-password'
        end
        auth.fetch('headers', {}).each_value do |value|
          result[value['credential']] = 'test-account' if value.is_a?(Hash) && value['credential']
          result[value] = 'test-account' if value.is_a?(String)
        end
        Array(signature['credentials']).each { |name| result[name] = callback_secret }
        result
      end

      # Produces an operation from profile source mappings and schema examples,
      # so verification can work for integrations without provider-specific code.
      def sample_operation(id: 'verification-operation')
        amount = config.fetch('amount', {})
        scale = BigDecimal(amount.fetch('scale', 1).to_s)
        minimum = [Integer(amount.fetch('minimum', 1)), 1].max
        value = amount['input_unit'] == 'minor' ? minimum : (BigDecimal(minimum.to_s) / scale).to_s('F')
        op = { 'id' => id, 'amount' => value,
               'currency' => Array(amount['currencies']).first || 'USD',
               'payout_requisite' => { 'sbp' => { 'phone' => '79001234567',
                 'bank_code' => '044525225' }, 'bank_account' => 'test-account' } }
        sample = sample_schema(config.dig('endpoints', 'create', 'request_schema') || {})
        config.fetch('request_mapping', {}).each do |target, rule|
          next unless rule.is_a?(Hash) && rule['from']
          next unless get_path(op, rule['from']).nil?

          value = get_path(sample, target)
          set_path(op, rule['from'], value.nil? ? 'test-value' : value)
        end
        op
      end

      # Returns signed messages without sending them anywhere. A duplicate is a
      # byte-identical delivery, and reverse order exercises event ordering.
      def callback_events(provider_id: nil, duplicate: false, out_of_order: false,
                          secret: nil)
        @mutex.synchronize do
          record = provider_id ? @records[provider_id] : @records.values.last
          return [] unless record

          callbacks = callback_states.each_with_index.map do |status, index|
            callback_event(record, callback_status(status), index + 1, secret: secret)
          end
          callbacks.reverse! if out_of_order
          callbacks << JSON.parse(JSON.generate(callbacks.last)) if duplicate && callbacks.any?
          callbacks
        end
      end

      private

      # Validate the wire request against the selected OpenAPI operation before
      # dispatch can change provider state. Request mappings and adapter helpers
      # are deliberately not involved in this contract check.
      def validate_request!(role, path_parameters, uri, headers, body)
        endpoint = config.fetch('endpoints').fetch(role)
        query = URI.decode_www_form(uri.query.to_s).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
        parameters = path_parameters.transform_values { |value| URI.decode_www_form_component(value) }
        parameters = query.transform_values(&:last).merge(parameters)
        Array(endpoint['parameters']).each do |definition|
          name, location = definition.values_at('name', 'in')
          raw = case location
                when 'path' then path_parameters[name] && [path_parameters[name]]
                when 'query' then query[name]
                when 'header'
                  value = header(headers, name)
                  value.nil? ? nil : [value.to_s]
                else raise RequestContractError, 'unsupported_parameter_serialization'
                end
          if raw.nil?
            raise RequestContractError, 'missing_required_parameter' if definition['required'] || location == 'path'

            next
          end
          value = deserialize_parameter(definition, raw)
          validate_contract!(definition.fetch('schema', {}), value, 'invalid_parameter')
        end

        content = endpoint.fetch('request_content', {})
        present = !body.nil? && (!body.respond_to?(:empty?) || !body.empty?)
        raise RequestContractError, 'missing_required_body' if endpoint['request_required'] && !present

        schema = endpoint.fetch('request_schema', {})
        if present && content.any?
          media_type = header(headers, 'content-type').to_s.split(';').first.to_s.strip.downcase
          selected = content.keys.sort_by { |name| name.count('*') }.find { |name| media_type_matches?(name, media_type) }
          raise RequestContractError.new('unsupported_media_type', 415) unless selected

          schema = content.fetch(selected).fetch('schema', {})
        end
        parsed = parse_body(body, headers, schema: schema)
        if present || endpoint['request_required'] || !endpoint.key?('request_required')
          value = if header(headers, 'content-type').to_s.split(';').first.to_s.strip.casecmp?('application/x-www-form-urlencoded')
                    deserialize_form_value(parsed, schema)
                  else
                    parsed
                  end
          validate_contract!(schema, value, 'invalid_request_body')
        end
        [parameters, parsed]
      end

      def media_type_matches?(declared, actual)
        expected = declared.split(';').first.to_s.strip.downcase
        return false if actual.empty?
        return true if expected == actual || expected == '*/*'

        expected.end_with?('/*') && actual.start_with?(expected.delete_suffix('*'))
      end

      def reject_duplicate_headers!(headers)
        names = headers.keys.map { |name| name.to_s.downcase }
        raise RequestContractError, 'ambiguous_header' unless names.uniq.length == names.length
      end

      def deserialize_parameter(definition, raw)
        location = definition['in']
        style = location == 'query' ? 'form' : 'simple'
        unless definition.fetch('style', style) == style && !definition.key?('content') && !definition['allowReserved']
          raise RequestContractError, 'unsupported_parameter_serialization'
        end
        schema = definition.fetch('schema', {})
        array = schema.is_a?(Hash) && Array(schema['type']).include?('array')
        if array
          values = if location == 'query' && definition.fetch('explode', true)
                     raw
                   else
                     raise RequestContractError, 'ambiguous_parameter' unless raw.length == 1

                     raw.first.split(',', -1)
                   end
          values = values.map { |value| URI.decode_www_form_component(value) } if location == 'path'
          values.map { |value| deserialize_scalar(value, schema.fetch('items', {})) }
        else
          raise RequestContractError, 'ambiguous_parameter' unless raw.length == 1

          value = location == 'path' ? URI.decode_www_form_component(raw.first) : raw.first
          deserialize_scalar(value, schema)
        end
      end

      def deserialize_scalar(value, schema)
        return value unless schema.is_a?(Hash)

        types = Array(schema['type'])
        raise RequestContractError, 'unsupported_parameter_serialization' if (types & %w[object array]).any?
        return value if types.empty? || types.include?('string')
        return Integer(value, 10) if types.include?('integer') && value.match?(/\A-?(?:0|[1-9]\d*)\z/)
        return BigDecimal(value) if types.include?('number') && value.match?(/\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\z/)
        return value == 'true' if types.include?('boolean') && %w[true false].include?(value)

        value
      end

      def deserialize_form_value(value, schema)
        return value unless schema.is_a?(Hash)

        case value
        when Hash
          value.to_h { |name, child| [name, deserialize_form_value(child, schema.dig('properties', name) || {})] }
        when Array
          value.map { |child| deserialize_form_value(child, schema.fetch('items', {})) }
        when String then deserialize_scalar(value, schema)
        else value
        end
      end

      def validate_contract!(schema, value, code)
        @request_validators ||= {}
        validator = @request_validators[schema] ||= begin
          options = { ref_resolver: ->(_uri) { raise RequestContractError, 'unresolved_contract_reference' } }
          options[:meta_schema] = JSONSchemer.openapi30 if config.fetch('openapi', '').start_with?('3.0.')
          JSONSchemer.schema(schema, **options)
        end
        raise RequestContractError, code unless validator.valid?(value)
      end

      def authorized?(uri, headers)
        auth = config.fetch('auth', {})
        expected = credentials
        value = expected[auth.fetch('credential', 'api_key')]
        valid = case auth.fetch('type', 'none')
                when 'none' then true
                when 'apiKey'
                  actual = auth['in'] == 'query' ? URI.decode_www_form(uri.query.to_s).to_h[auth['name']] : header(headers, auth['name'])
                  actual == value
                when 'bearer', 'oauth2', 'OAuth2' then header(headers, 'Authorization') == "Bearer #{value}"
                when 'basic'
                  user = expected[auth.fetch('username', 'username')]
                  password = expected[auth.fetch('password', 'password')]
                  header(headers, 'Authorization') == "Basic #{Base64.strict_encode64("#{user}:#{password}")}"
                else false
                end
        valid && auth.fetch('headers', {}).all? do |name, rule|
          target = rule.is_a?(Hash) ? (rule['credential'] ? expected[rule['credential']] : rule['value']) : expected[rule]
          header(headers, name) == target.to_s
        end
      end

      def dispatch(role, parameters, body, headers)
        case role
        when 'create' then create(body, headers)
        when 'status' then status(parameters)
        when 'cancel' then cancel(parameters)
        when 'balance'
          data = sample_schema(response_schema('balance', 200))
          data = { 'balance' => 500_000_000, 'currency' => Array(config.dig('amount', 'currencies')).first || 'USD' } if data.empty?
          response(200, data)
        else response(405, error_body('unsupported_operation'))
        end
      end

      def create(body, headers)
        @attempts += 1
        return response(429, error_body('rate_limit'), 'retry-after' => '1') if scenario == 'rate_limit' && @attempts == 1

        identity = idempotency_key(body, headers)
        fingerprint = Digest::SHA256.hexdigest(canonical(body))
        if identity && (previous = @idempotency[identity])
          return response(409, error_body('idempotency_conflict')) unless previous['fingerprint'] == fingerprint

          return response(success_code('create', 201), operation_body(@records.fetch(previous['id']), 'create'))
        end

        return response(503, error_body('simulator_capacity')) if @records.length >= 10_000

        id_path = config.dig('simulator', 'id_from_request')
        id = id_path ? get_path(body, id_path).to_s : "sim_#{Digest::SHA256.hexdigest("#{seed}:#{@records.length}:#{identity}:#{fingerprint}")[0, 20]}"
        return response(400, error_body('missing_request_identity')) if id.empty?
        return response(409, error_body('duplicate_request_identity')) if @records.key?(id)
        record = { 'id' => id, 'request' => body, 'status' => initial_status,
                   'status_reads' => 0, 'fingerprint' => fingerprint }
        @records[id] = record
        @idempotency[identity] = { 'id' => id, 'fingerprint' => fingerprint } if identity
        result = response(success_code('create', 201), operation_body(record, 'create'))
        result[:transport_timeout] = true if scenario == 'timeout_after_commit' && @attempts == 1
        result
      end

      def status(parameters)
        record = record_for(parameters)
        return response(404, error_body('not_found')) unless record

        sequence = status_states
        record['status'] = sequence[[record['status_reads'], sequence.length - 1].min] unless record['cancelled']
        record['status_reads'] += 1
        response(success_code('status', 200), operation_body(record, 'status'))
      end

      def cancel(parameters)
        record = record_for(parameters)
        return response(404, error_body('not_found')) unless record
        return response(409, error_body('invalid_status')) if terminal_status?(record['status'])

        record['status'] = mapped_status('cancelled') || mapped_status('rejected') || 'cancelled'
        record['cancelled'] = true
        response(success_code('cancel', 200), operation_body(record, 'cancel'))
      end

      def record_for(parameters)
        parameters.each_value do |value|
          return @records[value] if @records.key?(value)
          record = @records.values.find do |entry|
            config.fetch('request_mapping', {}).any? do |target, rule|
              rule.is_a?(Hash) && rule['from'] == 'id' && get_path(entry['request'], target).to_s == value
            end
          end
          return record if record
        end
        nil
      end

      def endpoint_match(method, request_path)
        all_servers = Array(config['servers']) + config.fetch('endpoints', {}).values.flat_map { |item| Array(item['servers']) }
        prefixes = all_servers.filter_map do |server|
          URI.parse(server.is_a?(Hash) ? server.fetch('url') : server).path.sub(%r{/$}, '')
        rescue URI::InvalidURIError
          nil
        end
        paths = ([request_path] + prefixes.filter_map do |prefix|
          request_path.delete_prefix(prefix) if !prefix.empty? && request_path.start_with?("#{prefix}/")
        end).uniq
        config.fetch('endpoints', {}).each do |role, endpoint|
          next unless endpoint.fetch('method').casecmp?(method.to_s)

          names = []
          pieces = endpoint.fetch('path').split(/(\{[^}]+\})/).map do |part|
            if part.start_with?('{')
              names << part[1...-1]
              '([^/]+)'
            else
              Regexp.escape(part)
            end
          end
          pattern = Regexp.new("\\A#{pieces.join}\\z")
          paths.each do |path|
            match = pattern.match(path)
            return [role, names.zip(match.captures).to_h] if match
          end
        end
        nil
      end

      def idempotency_key(body, headers)
        setting = config.fetch('idempotency', {})
        return nil if setting['strategy'] == 'reconcile_before_retry'

        value = header(headers, setting['header']) if setting['header'].is_a?(String) && !setting['header'].empty?
        value ||= get_path(body, setting['body']) if setting['body']
        value.to_s.empty? ? nil : value.to_s
      end

      def operation_body(record, role)
        schema = response_schema(role, success_code(role, role == 'create' ? 201 : 200))
        data = sample_schema(schema)
        mapping = config.fetch('response', {}).merge(config.dig('response', 'roles', role) || {})
        fields = [mapping.fetch('id', 'id'), mapping.fetch('status', 'status')]
        config.fetch('request_mapping', {}).each_key do |target|
          value = get_path(record['request'], target)
          target_schema = schema_at_path(schema, target)
          next if value.nil? || target.match?(/card_number|pan|secret|password/i) || !target_schema
          value = Integer(value, 10) if target_schema['type'] == 'integer' && value.is_a?(String) && value.match?(/\A-?\d+\z/)
          set_path(data, target, value)
          fields << target
        end
        set_path(data, mapping.fetch('id', 'id'), record['id'])
        set_path(data, mapping.fetch('status', 'status'), response_status(record, mapping, schema))
        if mapping['items'] && mapping['item_status']
          item_schema = schema_at_path(schema, mapping['items']) || {}
          item = sample_schema(item_schema.fetch('items', {}))
          set_path(item, mapping['item_status'], scenario == 'batch_success_item_failed' ? rejected_status : record['status'])
          set_path(item, mapping.fetch('item_id', 'id'), record['id'])
          if mapping['item_external_id']
            source = config.fetch('request_mapping', {}).find { |_key, rule| rule.is_a?(Hash) && rule['from'] == 'id' }
            set_path(item, mapping['item_external_id'], source ? get_path(record['request'], source.first) : '')
          end
          item = response_sample(item, item_schema.fetch('items', {}),
                                 [mapping['item_status'], mapping.fetch('item_id', 'id'), mapping['item_external_id']])
          set_path(data, mapping['items'], [item])
          fields << mapping['items']
        end
        identity_fields(data, mapping)
        fields += [mapping['account_field'] || config['account_field'], mapping['mode_field'] || config['mode_field']]
        response_sample(data, schema, fields)
      end

      # Batch processing and the individual transfer have different status
      # vocabularies. An item failure or return must not overwrite a previously
      # valid batch status with a value that only exists in the item contract.
      def response_status(record, mapping, schema)
        value = record['status']
        return value unless mapping['scope'] == 'batch'

        batch_schema = schema_at_path(schema, mapping.fetch('status', 'status')) || {}
        if sample_valid?(batch_schema, value)
          record['batch_status'] = value
          return value
        end
        status_mapping = config.fetch('response', {}).merge(config.dig('response', 'roles', 'status') || {})
        return value unless status_mapping['items'] && status_mapping['item_status']

        status_schema = response_schema('status', success_code('status', 200))
        item_array = schema_at_path(status_schema, status_mapping['items']) || {}
        item_schema = schema_at_path(item_array.fetch('items', {}), status_mapping['item_status'])
        return value unless item_schema && sample_valid?(item_schema, value)

        candidates = [record['batch_status'], approved_status, mapped_status('in_progress')].compact
        candidates.find { |candidate| sample_valid?(batch_schema, candidate) } || value
      end

      def identity_fields(data, mapping)
        account = mapping['account_field'] || config['account_field']
        mode = mapping['mode_field'] || config['mode_field']
        set_path(data, account, scenario == 'account_mismatch' ? 'other-account' : 'test-account') if account
        return unless mode

        values = mapping.fetch('mode_values', config.fetch('mode_values', {}))
        selected = config.fetch('mode', 'sandbox')
        selected = selected == 'sandbox' ? 'production' : 'sandbox' if scenario == 'mode_mismatch'
        set_path(data, mode, values.fetch(selected, selected))
      end

      def initial_status
        configured = configured_states
        return configured.first if configured.any?
        return 'paygen_unknown_status' if scenario == 'unknown_status'
        return approved_status if %w[paid_then_failed booked_then_returned batch_success_item_failed].include?(scenario)

        mapped_status('in_progress') || config.fetch('status_mapping', {}).keys.first || 'pending'
      end

      def status_states
        configured = configured_states
        return configured if configured.any?

        case scenario
        when 'unknown_status' then ['paygen_unknown_status']
        when 'paid_then_failed', 'booked_then_returned' then [approved_status, rejected_status]
        else [approved_status]
        end
      end

      def callback_states
        configured = configured_states
        return configured if configured.any?

        if %w[paid_then_failed booked_then_returned].include?(scenario)
          [approved_status, rejected_status]
        else
          candidates = config.dig('callback', 'events') || {}
          first = candidates.values.find { |status| config.fetch('status_mapping', {})[status] == 'in_progress' }
          [first || mapped_status('in_progress') || 'pending', approved_status]
        end
      end

      def callback_status(status)
        events = config.dig('callback', 'events') || {}
        return status if events.empty? || events.value?(status) || events.value?(nil)

        mapping = config.fetch('status_mapping', {})
        events.values.find { |candidate| mapping[candidate] == mapping[status] } || status
      end

      def mapped_status(internal)
        config.fetch('status_mapping', {}).find do |_external, value|
          (value.is_a?(Hash) ? value['status'] : value) == internal
        end&.first
      end

      def approved_status
        mapped_status('approved') || Array(config['status_order']).reverse.find do |status|
          config.fetch('status_mapping', {})[status] == 'in_progress'
        end || mapped_status('in_progress') || 'completed'
      end

      def configured_states
        Array(config.dig('simulator', 'scenarios', scenario, 'statuses'))
      end

      def rejected_status
        mapped_status('rejected') || 'failed'
      end

      def terminal_status?(status)
        mapping = config.fetch('status_mapping', {})[status]
        %w[approved rejected cancelled].include?(mapping.is_a?(Hash) ? mapping['status'] : mapping)
      end

      def callback_event(record, status, sequence, secret:)
        callback = config.fetch('callback', {})
        schema = config.dig('endpoints', 'callback', 'request_schema') || {}
        payload = sample_schema(schema)
        set_path(payload, callback.fetch('id', 'payout_id'), record['id'])
        set_path(payload, callback.fetch('status', 'status'), status)
        event = callback.fetch('events', {}).find { |_key, value| value == status }&.first ||
                callback.fetch('events', {}).find { |_key, value| value.nil? }&.first || status
        set_path(payload, callback['event'], event) if callback['event']
        set_path(payload, callback['event_id'], "evt_#{seed}_#{record['id']}_#{sequence}") if callback['event_id']
        set_path(payload, callback['sequence'], sequence) if callback['sequence']
        if callback['timestamp']
          existing = get_path(payload, callback['timestamp'])
          value = existing.is_a?(String) ? Time.at(1_800_000_000 + sequence).utc.iso8601 : 1_800_000_000 + sequence
          set_path(payload, callback['timestamp'], value)
        end
        if callback['external_id']
          source = config.fetch('request_mapping', {}).find { |_key, rule| rule.is_a?(Hash) && rule['from'] == 'id' }
          set_path(payload, callback['external_id'], get_path(record['request'], source.first)) if source
        end
        callback.fetch('constraints', {}).each { |path, value| set_path(payload, path, value) }
        identity_fields(payload, callback)
        fields = [callback.fetch('id', 'payout_id'), callback.fetch('status', 'status'),
                  callback['event'], callback['event_id'], callback['sequence'],
                  callback['timestamp'], callback['external_id'],
                  callback['account_field'] || config['account_field'], callback['mode_field'] || config['mode_field']]
        payload = response_sample(payload, schema, fields + callback.fetch('constraints', {}).keys)
        raw = JSON.generate(payload)
        { 'payload' => payload, 'raw_body' => raw, 'headers' => sign(raw, secret || callback_secret, sequence) }
      end

      def callback_secret
        config.dig('simulator', 'callback_secret') ||
          (config.dig('callback', 'signature', 'key_encoding') == 'hex' ? 'ab' * 32 : 'paygen-test-secret')
      end

      def sign(raw, secret, sequence)
        signature = config.dig('callback', 'signature') || {}
        return {} if signature.empty? || signature['algorithm'] == 'provider_verification'

        key = signature['key_encoding'] == 'hex' ? [secret].pack('H*') : secret
        if signature['algorithm'] == 'stripe-v1'
          timestamp = 1_800_000_000 + sequence
          digest = OpenSSL::HMAC.hexdigest('SHA256', key, "#{timestamp}.#{raw}")
          value = "t=#{timestamp},v1=#{digest}"
        else
          digest = OpenSSL::HMAC.digest('SHA256', key, raw)
          value = signature['encoding'] == 'base64' ? Base64.strict_encode64(digest) : digest.unpack1('H*')
        end
        { signature.fetch('header', 'X-Signature') => value }
      end

      def success_code(role, fallback)
        codes = config.dig('endpoints', role, 'responses') || {}
        codes.keys.map(&:to_s).select { |code| code.match?(/\A2\d\d\z/) }.map(&:to_i).min || fallback
      end

      def response_schema(role, status)
        entry = (config.dig('endpoints', role, 'responses') || {})[status.to_s] || {}
        entry.dig('content', 'application/json', 'schema') || entry['schema'] || {}
      end

      def sample_schema(schema, depth = 0)
        return {} unless schema.is_a?(Hash) && depth < 16
        return JSON.parse(JSON.generate(schema['example'])) if schema.key?('example')
        return JSON.parse(JSON.generate(schema['default'])) if schema.key?('default')
        return JSON.parse(JSON.generate(schema['const'])) if schema.key?('const')
        return JSON.parse(JSON.generate(schema['enum'].first)) if schema['enum'].is_a?(Array) && !schema['enum'].empty?

        type = schema['type'] || (schema['properties'] ? 'object' : nil)
        type = type.find { |candidate| candidate != 'null' } if type.is_a?(Array)
        case type
        when 'object'
          schema.fetch('properties', {}).each_with_object({}) do |(name, value), result|
            candidate = sample_schema(value, depth + 1)
            # Some native contracts contain contradictory optional enums or
            # invalid annotations. Omit an invalid optional sample; leave a
            # required failure visible to the verifier instead of inventing data.
            next if !Array(schema['required']).include?(name) && !sample_valid?(value, candidate)
            result[name] = candidate
          end
        when 'array' then [sample_schema(schema.fetch('items', {}), depth + 1)]
        when 'integer', 'number' then schema.fetch('minimum', 1)
        when 'boolean' then false
        when 'string'
          example = { 'date-time' => '2027-01-15T08:00:00Z', 'date' => '2027-01-15',
            'email' => 'sample@example.test', 'uuid' => '00000000-0000-4000-8000-000000000001',
            'uri' => 'https://simulator.example', 'uri-reference' => '/test',
            'hostname' => 'simulator.example', 'ipv4' => '203.0.113.1',
            'ipv6' => '2001:db8::1' }.fetch(schema['format'], 'test-value')
          if schema['maxLength'].is_a?(Integer) && example.length > schema['maxLength']
            example = example[0, schema['maxLength']]
          end
          if schema['pattern']
            # A small deterministic sample set, never a claim of arbitrary regex
            # generation. The verifier reports patterns for which no sample fits.
            candidates = [example, '0.00', '1.00', '1', 'x', '1234567890']
            example = candidates.find { |value| sample_valid?(schema, value) } || example
          end
          example
        else {}
        end
      end

      def schema_at_path(schema, path)
        path_tokens(path).reduce(schema) do |node, token|
          break nil unless node.is_a?(Hash)
          token.match?(/\A\d+\z/) ? node['items'] : node.dig('properties', token)
        end
      end

      # Keep contract-required data and values supplied by this scenario. Optional
      # schema placeholders can otherwise imply an error or completion that never
      # happened. Preserve the full sample when conditional constraints need it.
      def response_sample(value, schema, fields)
        candidate = compact_sample(value, schema, fields.compact.map { |field| path_tokens(field) })
        sample_valid?(schema, candidate) ? candidate : value
      end

      def compact_sample(value, schema, paths)
        return value unless schema.is_a?(Hash)
        return value if paths.include?([]) || schema.key?('const') || schema.key?('enum')

        case value
        when Hash
          required = Array(schema['required'])
          value.each_with_object({}) do |(name, child), result|
            selected = paths.select { |path| path.first == name }.map { |path| path.drop(1) }
            next unless required.include?(name) || selected.any?

            result[name] = compact_sample(child, schema.dig('properties', name) || {}, selected)
          end
        when Array
          value.each_with_index.map do |child, index|
            selected = paths.select { |path| path.first == index.to_s }.map { |path| path.drop(1) }
            compact_sample(child, schema['items'] || {}, selected)
          end
        else value
        end
      end

      def sample_valid?(schema, candidate)
        @sample_validators ||= {}
        (@sample_validators[schema] ||= JSONSchemer.schema(schema)).valid?(candidate)
      end

      def parse_body(body, headers, schema: {})
        return JSON.parse(JSON.generate(body)) if body.is_a?(Hash)
        return {} if body.nil? || body.empty?
        if header(headers, 'content-type').to_s.split(';').first.to_s.strip.casecmp?('application/x-www-form-urlencoded')
          parse_form_body(body, schema)
        else
          parsed = JSON.parse(body)
          raise ArgumentError, 'Request must be an object' unless parsed.is_a?(Hash)

          parsed
        end
      end

      def parse_form_body(body, schema)
        paths = []
        fields = URI.decode_www_form(body)
        raise RequestContractError, 'too_many_form_parameters' if fields.length > 1000

        fields.group_by(&:first).each_with_object({}) do |(key, pairs), result|
          path = path_tokens(key.gsub(/\[([^\]]+)\]/, '.\\1').sub(/\A\./, ''))
          if path.empty? || path.length > 32 || path.any? { |token| token.match?(/\A\d+\z/) && token.to_i > 999 }
            raise RequestContractError, 'invalid_form_parameter'
          end
          if paths.any? { |previous| previous.take(path.length) == path || path.take(previous.length) == previous }
            raise RequestContractError, 'ambiguous_form_parameter'
          end
          paths << path
          values = pairs.map(&:last)
          target_schema = schema_at_path(schema, path.join('.'))
          array = target_schema.is_a?(Hash) && Array(target_schema['type']).include?('array')
          if values.length > 1 && !array
            raise RequestContractError, 'ambiguous_form_parameter'
          end
          set_path(result, path.join('.'), array ? values : values.first)
        end
      end

      def header(headers, name)
        headers.find { |key, _value| key.to_s.casecmp?(name.to_s) }&.last
      end

      def get_path(object, path)
        path_tokens(path).reduce(object) do |value, key|
          break nil unless value.is_a?(Hash) || value.is_a?(Array)

          value.is_a?(Array) ? value[key.to_i] : value[key]
        end
      end

      def set_path(object, path, value)
        keys = path_tokens(path)
        return if keys.empty?

        target = object
        keys.each_with_index do |key, index|
          lookup = target.is_a?(Array) ? Integer(key) : key
          if index == keys.length - 1
            target[lookup] = value
          else
            target[lookup] ||= keys[index + 1].match?(/\A\d+\z/) ? [] : {}
            target = target[lookup]
          end
        end
      end

      def path_tokens(path)
        path.to_s.sub(/\A\$\.?/, '').gsub(/\[(\d+)\]/, '.\\1').split('.').reject(&:empty?)
      end

      def canonical(value)
        ordered = case value
                  when Hash then value.keys.sort.to_h { |key| [key, JSON.parse(canonical(value[key]))] }
                  when Array then value.map { |entry| JSON.parse(canonical(entry)) }
                  else value
                  end
        JSON.generate(ordered)
      end

      def error_body(code, message = code)
        { 'error' => { 'code' => code, 'message' => message } }
      end

      def response(status, body, headers = {})
        { status: status, headers: { 'content-type' => 'application/json' }.merge(headers), body: JSON.generate(body) }
      end

      def rack_response(result)
        headers = result[:headers].transform_keys(&:downcase)
        headers['content-length'] = result[:body].bytesize.to_s
        [result[:status], headers, [result[:body]]]
      end
    end
  end
end
