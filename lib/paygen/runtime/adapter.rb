# frozen_string_literal: true

require 'base64'
require 'bigdecimal'
require 'json'
require 'json_schemer'
require 'time'
require 'timeout'
require_relative 'security'

module Paygen
  module Runtime
    # Backend seam: generated classes include this module below BaseService.
    # Public results always use string keys and never contain credential values.
    module Adapter
      DEFAULT_OPERATION_ATTRIBUTES = %w[
        id amount currency payout_requisite provider_operation_id provider_id
        provider_payment_id provider_item_id idempotency_key balance_account_id
      ].freeze

      def configure_paygen(credentials: {}, transport: nil, base_url: nil, mode: 'sandbox', account: nil,
                           token_provider: nil, state_store: nil, clock: nil, allow_local: false,
                           allowed_attributes: [])
        @paygen_credentials = stringify(credentials)
        @paygen_sensitive_values = []
        @paygen_allow_local = allow_local
        @paygen_transport = transport || HTTPTransport.new(allow_local: allow_local)
        @paygen_mode = mode.to_s
        @paygen_account = account || @paygen_credentials['account']
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
        return failure('validation_error', details: { 'violations' => problems }) unless problems.empty?

        { 'success' => true, 'status' => 'valid' }
      rescue ArgumentError, TypeError => e
        failure('validation_error', details: { 'reason' => e.message })
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
        config = paygen_config.fetch('callback', {})
        return failure('callback_not_configured') if config.empty?
        return failure('missing_raw_body') unless raw_body.is_a?(String)
        return failure('payload_too_large') if raw_body.bytesize > 1_048_576

        parsed = JSON.parse(raw_body)
        return failure('payload_mismatch') unless stringify(payload) == parsed
        return failure('invalid_signature') unless verify_callback(parsed, raw_body, stringify(headers))
        schema = endpoint('callback')['request_schema']
        return failure('invalid_callback') if schema && !JSONSchemer.schema(validation_schema(schema)).valid?(parsed)

        mismatch = identity_mismatch(parsed, config)
        return failure(mismatch) if mismatch
        constraints = config.fetch('constraints', {})
        return failure('callback_scope_mismatch') unless constraints.all? { |path, value| read_path(parsed, path) == value }

        provider_id = read_path(parsed, config.fetch('id', 'id'))
        return failure('missing_provider_id') if provider_id.to_s.empty?

        provider_status = read_path(parsed, config.fetch('status', 'status'))
        event = read_path(parsed, config.fetch('event', 'event'))
        events = config.fetch('events', {})
        return failure('unsupported_event') if !events.empty? && !events.key?(event)

        expected = events[event]
        return failure('event_status_mismatch') if expected && provider_status && expected != provider_status

        provider_status ||= expected
        result = status_result(provider_status, provider_id, parsed)
        return result unless result['success']

        event_id = read_path(parsed, config['event_id']) || Digest::SHA256.hexdigest(raw_body)
        ordering = callback_order(parsed, config)
        @paygen_store.synchronize do |state|
          key = "callback:#{paygen_config['provider']}:#{@paygen_mode}:#{@paygen_account}:#{provider_id}"
          previous = state[key] || { 'events' => [], 'status' => nil, 'provider_status' => nil, 'order' => nil }
          if previous['events'].include?(event_id.to_s)
            result.merge('status' => previous['status'], 'ignored' => 'duplicate')
          elsif ordering && previous['order'] && ordering < previous['order']
            result.merge('status' => previous['status'], 'ignored' => 'out_of_order')
          elsif !allowed_transition?(previous['provider_status'], provider_status.to_s)
            result.merge('status' => previous['status'], 'ignored' => 'invalid_transition')
          else
            state[key] = { 'events' => (previous['events'] + [event_id.to_s]).last(10_000),
                           'status' => result['status'], 'provider_status' => provider_status.to_s,
                           'order' => ordering || previous['order'] }
            result['external_id'] = safe(read_path(parsed, config['external_id'])) if config['external_id']
            result
          end
        end
      rescue JSON::ParserError, ArgumentError, TypeError
        failure('invalid_callback')
      rescue SecurityError
        failure('security_denial')
      end

      # Override these methods in extensions. No Ruby code is loaded from YAML.
      def paygen_validate(_operation, _role, _body) = []
      def paygen_request(request, _role, _operation) = request
      def paygen_response(response, _role, _operation) = response
      def paygen_status(status, _payload) = status
      # Override with (_payload, raw_body:, headers:) to verify provider evidence.
      def paygen_verify_callback(_payload, **_verification) = false
      def paygen_classify_error(error, _role, _response) = error
      def paygen_retry_decision(error, _role) = error['retryable']

      private

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
        server.is_a?(Hash) ? server['url'] : server
      end

      def server_mode(server)
        if server.is_a?(Hash)
          explicit = server['mode'] || server['x-paygen-mode']
          return explicit.to_s unless explicit.to_s.empty?

          description = server['description'].to_s
          return 'sandbox' if description.match?(/\b(?:sandbox|test|testing)\b/i)
          return 'production' if description.match?(/\b(?:production|prod|live)\b/i)
        end
        url = server.is_a?(Hash) ? server['url'] : server
        host = URI.parse(url.to_s).hostname.to_s
        return 'sandbox' if host.match?(/(?:\A|[.-])(?:sandbox|test|testing)(?:[.-]|\z)/i)
        return 'production' if host.match?(/(?:\A|[.-])(?:production|prod|live)(?:[.-]|\z)/i)

        nil
      rescue URI::InvalidURIError
        raise SecurityError, 'Invalid server URL'
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
          value = rule.key?('value') ? rule['value'] : read_path(operation, rule['from'])
          next if value.nil? && !rule.key?('value')

          write_path(body, target, transform(value, rule['transform']))
        end
      end

      def execute(role, operation)
        ensure_configured
        return failure('operation_not_supported') if endpoint(role).empty?
        if paygen_config['mode'] && @paygen_mode != paygen_config['mode']
          return failure('mode_mismatch')
        end
        if role == 'create'
          validation = check_conditions(operation, role)
          return validation unless validation['success']
        end

        request = build_request(role, operation)
        request = paygen_request(request, role, operation)
        validate_request_destination!(request, role)
        if role == 'create'
          conflict = @paygen_store.synchronize do |state|
            key = "request:#{paygen_config['provider']}:#{@paygen_mode}:#{@paygen_account}:#{idempotency_key(operation)}"
            fingerprint = Digest::SHA256.hexdigest(request.fetch(:body).to_s)
            previous = state[key]
            state[key] ||= fingerprint
            previous && previous != fingerprint
          end
          return failure('idempotency_conflict') if conflict
        end
        response = stringify(@paygen_transport.request(**request))
        response = stringify(paygen_response(response, role, operation))
        interpret_response(response, role, operation)
      rescue Timeout::Error, EOFError, Errno::ECONNRESET
        failure('transport_timeout', retryable: role != 'create', ambiguous: role == 'create',
                details: role == 'create' ? { 'action' => 'reconcile_before_retry', 'idempotency_key' => idempotency_key(operation) } : {})
      rescue SecurityError
        failure('security_denial')
      rescue ArgumentError, TypeError, KeyError => e
        failure('configuration_error', details: { 'reason' => e.message })
      rescue SocketError, SystemCallError
        failure('transport_error', retryable: role != 'create', ambiguous: role == 'create')
      end

      def build_request(role, operation)
        spec = endpoint(role)
        raise SecurityError, 'Unsupported HTTP method' unless %w[get post put patch delete head options].include?(spec.fetch('method').to_s.downcase)
        path = spec.fetch('path')
        raise SecurityError, 'Endpoint path must be relative to its server' unless path.start_with?('/') && !path.start_with?('//')
        raise SecurityError, 'Unsafe endpoint path' if path.include?('..') || path.include?('\\') || path.include?('?') || path.include?('#')

        mappings = paygen_config.fetch('parameter_mapping', {}).fetch(role, {})
        path = path.gsub(/\{([^}]+)\}/) do
          parameter = Regexp.last_match(1)
          value = read_path(operation, mappings[parameter] || 'provider_id') ||
                  read_path(operation, parameter) || read_path(operation, 'provider_payment_id')
          raise ArgumentError, "missing path parameter #{parameter}" if value.to_s.empty?
          raise SecurityError, 'Unsafe path parameter' if %w[. ..].include?(value.to_s)

          URI.encode_www_form_component(value.to_s).gsub('+', '%20')
        end
        base = Security.uri(server_for(role), allow_local: @paygen_allow_local)
        url = "#{base.to_s.sub(%r{/$}, '')}#{path}"
        headers = { 'Accept' => 'application/json' }
        headers[paygen_config.fetch('idempotency', {}).fetch('header', 'Idempotency-Key')] = idempotency_key(operation) if role == 'create'
        url = apply_auth(headers, url)
        body = build_body(operation, role)
        if body
          encoding = spec['request_encoding'] || paygen_config['request_encoding'] || 'json'
          if encoding == 'form'
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
            body = URI.encode_www_form(form_pairs(body))
          elsif encoding == 'json'
            headers['Content-Type'] = 'application/json'
            body = JSON.generate(body)
          else
            raise ArgumentError, 'unsupported request encoding'
          end
        end
        { method: spec.fetch('method').to_s.upcase, url: url, headers: headers, body: body }
      end

      def form_pairs(value, prefix = nil)
        case value
        when Hash then value.flat_map { |key, child| form_pairs(child, prefix ? "#{prefix}[#{key}]" : key) }
        when Array then value.each_with_index.flat_map { |child, index| form_pairs(child, "#{prefix}[#{index}]") }
        else [[prefix, value]]
        end
      end

      def idempotency_key(operation)
        config = paygen_config.fetch('idempotency', {})
        explicit = read_path(operation, config.fetch('from', 'idempotency_key'))
        return explicit.to_s unless explicit.to_s.empty?

        id = read_path(operation, 'id')
        raise ArgumentError, 'operation id is required for stable idempotency' if id.to_s.empty?

        hex = Digest::SHA256.hexdigest([paygen_config['provider'], @paygen_mode, @paygen_account, id].join(':'))[0, 32]
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
        request.fetch(:headers).each do |key, value|
          raise SecurityError, 'Invalid HTTP header' if key.to_s.match?(/[\r\n:\x00]/) || value.to_s.match?(/[\r\n\x00]/)
        end
      end

      def response_config(role)
        config = paygen_config.fetch('response', {})
        config.merge(config.fetch('roles', {}).fetch(role, {}))
      end

      def interpret_response(response, role, operation)
        status = Integer(response.fetch('status'))
        raw = response['body']
        payload = raw.is_a?(String) ? JSON.parse(raw) : stringify(raw || {})
        mapping = response_config(role)
        duplicate = status == 409 && role == 'create' && read_path(payload, mapping.fetch('id', 'id')) &&
                    read_path(payload, mapping.fetch('status', 'status')) && !read_path(payload, mapping.fetch('error', 'error.code'))
        return classify_error(status, response, payload, role) unless (200..299).cover?(status) || duplicate

        mismatch = identity_mismatch(payload, mapping)
        return failure(mismatch) if mismatch
        return { 'success' => true, 'status' => 'available', 'data' => safe(payload) } if role == 'balance'

        provider_id = read_path(payload, mapping.fetch('id', 'id')) || read_path(operation, 'provider_id')
        return failure('missing_provider_id') if provider_id.to_s.empty?

        provider_status = read_path(payload, mapping.fetch('status', 'status'))
        if mapping['items']
          items = read_path(payload, mapping['items'])
          return failure('missing_item_evidence') unless items.is_a?(Array) && !items.empty?

          matching = if mapping['item_external_id']
                       items.select { |item| read_path(item, mapping['item_external_id']).to_s == read_path(operation, 'id').to_s }
                     else
                       items
                     end
          return failure('ambiguous_item_evidence') unless matching.length == 1

          provider_status = read_path(matching.first, mapping.fetch('item_status', 'status'))
        end
        result = status_result(provider_status, provider_id, payload)
        result['provider_item_id'] = safe(read_path(matching.first, mapping['item_id'])) if mapping['items'] && mapping['item_id']
        # Batch acceptance never proves that a recipient received money.
        if mapping['scope'] == 'batch' && !mapping['items'] && result['status'] == 'approved'
          result['status'] = 'in_progress'
        end
        result['duplicate'] = true if duplicate
        result
      rescue JSON::ParserError
        return classify_error(status, response, {}, role) unless (200..299).cover?(status)

        failure('invalid_provider_response', ambiguous: role == 'create')
      end

      def status_result(provider_status, provider_id, payload)
        mapped = paygen_config.fetch('status_mapping', {})[provider_status.to_s]
        unless mapped
          return failure('unknown_status', details: { 'provider_status' => provider_status,
                                                      'action' => 'reconcile' }).merge('provider_id' => safe(provider_id.to_s))
        end

        mapped = paygen_status(mapped, payload)
        safe({ 'success' => true, 'status' => mapped, 'provider_id' => provider_id.to_s,
               'provider_status' => provider_status.to_s, 'data' => payload })
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
        return Integer(sequence) unless sequence.nil?

        value = read_path(payload, config['timestamp'])
        return nil if value.nil?

        value.is_a?(Numeric) ? value : Time.iso8601(value).to_f
      end

      def allowed_transition?(previous, current)
        return true if previous.nil? || previous == current

        rules = paygen_config['status_transitions']
        return Array(rules[previous]).include?(current) if rules && rules.key?(previous)

        order = paygen_config['status_order']
        if order && order.include?(previous) && order.include?(current)
          return order.index(current) >= order.index(previous)
        end

        mappings = paygen_config.fetch('status_mapping', {})
        !(%w[approved rejected cancelled].include?(mappings[previous]) && mappings[current] == 'in_progress')
      end

      def safe(value)
        Security.redact(value, secrets: (@paygen_credentials&.values || []) + (@paygen_sensitive_values || []))
      end

      def failure(code, retryable: false, ambiguous: false, details: {})
        { 'success' => false, 'status' => 'error', 'error' => safe({ 'code' => code, 'retryable' => retryable,
                                                                'ambiguous' => ambiguous }.merge(details)) }
      end
    end
  end
end
