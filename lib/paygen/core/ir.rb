# frozen_string_literal: true
require_relative '../mapping_rule'
module Paygen
  module Core
    # Provider-neutral, JSON-shaped representation of the effective contract.
    class IR
      METHODS = %w[get put post delete options head patch trace].freeze
      ROLES = {
        'create' => /create.*(?:payout|transfer)|(?:payout|transfer).*create/i,
        'status' => /get.*(?:payout|transfer)|(?:payout|transfer).*(?:status|retrieve)/i,
        'cancel' => /cancel/i, 'balance' => /balance/i, 'callback' => /webhook|callback/i
      }.freeze
      attr_reader :document, :profile, :diagnostics, :provenance

      def initialize(document, profile: {}, recipe: {}, overrides: {})
        unless [profile, recipe, overrides].all? { |layer| layer.is_a?(Hash) }
          raise Error.new('Semantic configuration must be an object', code: 'INVALID_PROFILE', exit_code: 3)
        end
        @document = document
        @diagnostics = []
        vendor = document.fetch('x-paygen', {})
        unless vendor.is_a?(Hash)
          raise Error.new('x-paygen must be an object', code: 'INVALID_PROFILE', exit_code: 3)
        end
        inferred = infer([vendor, recipe, profile, overrides])
        @profile = [vendor, recipe, profile, overrides].reduce(inferred) { |memo, layer| Paygen.deep_merge(memo, layer) }
        %w[operations request_mapping request_mappings status_mapping amount response idempotency auth callback errors parameter_mapping].each do |key|
          next unless @profile.key?(key)
          unless @profile[key].is_a?(Hash)
            raise Error.new("#{key} must be an object", code: 'INVALID_PROFILE', exit_code: 3)
          end
        end
        validate_nested_shapes!
        @provenance = {}
        [['inference', inferred], ['vendor-extension', vendor], ['recipe', recipe],
         ['integration-profile', profile], ['cli-override', overrides]].each do |origin, layer|
          record_provenance(layer, '', origin)
        end
        validate_profile
      end

      def operations
        return @operations if @operations
        @operation_sources = {}
        @operations = []
        document.fetch('paths', {}).each { |path, item| collect_operations(path, item, false, "/paths/#{pointer_token(path)}") }
        document.fetch('webhooks', {}).each { |name, item| collect_operations(name, item, true, "/webhooks/#{pointer_token(name)}") }
        @operations
      end

      # Resolve only selected HTTP contracts. Unrelated recursive component graphs
      # remain pinned in the source rather than being duplicated into every endpoint.
      def endpoint(operation_id)
        @endpoint_cache ||= {}
        return @endpoint_cache[operation_id] if @endpoint_cache.key?(operation_id)
        metadata = operations.find { |item| item['operation_id'] == operation_id }
        return nil unless metadata
        operation, item = @operation_sources.fetch(metadata['source_pointer'])
        resolved = Input.resolve_fragment(document, operation.reject { |key, _| key == 'callbacks' })
        common = Input.resolve_fragment(document, { 'parameters' => item.fetch('parameters', []) })
        @endpoint_cache[operation_id] = operation_metadata(metadata['path'], metadata['method'].downcase,
                                                          resolved, item.merge(common), metadata['inbound'], metadata['source_pointer'])
      end

      def config
        endpoints = profile.fetch('operations', {}).to_h do |role, operation_id|
          operation = endpoint(operation_id)
          operation = operation.merge('servers' => profile['servers']) if operation && profile.key?('servers')
          [role, operation]
        end.compact
        create_servers = endpoints.dig('create', 'servers') || document.fetch('servers', [])
        profile.merge('openapi' => document['openapi'], 'endpoints' => endpoints, 'servers' => profile.fetch('servers', create_servers),
                      'source_hash' => Digest::SHA256.hexdigest(Paygen.json(document)))
      end

      def to_h
        { 'openapi' => document['openapi'], 'title' => document.dig('info', 'title'),
          'operations' => operations, 'profile' => profile, 'diagnostics' => diagnostics,
          'candidates' => candidates }
      end

      # Suggestions carry evidence, never status/amount/auth assumptions. A method
      # named "payout" may simulate receipt of funds rather than send money.
      def candidates
        ROLES.keys.to_h do |role|
          ranked = operations.filter_map do |op|
            evidence = []
            evidence << 'operationId' if op['operation_id'].match?(ROLES.fetch(role))
            evidence << 'inbound callback contract' if role == 'callback' && op['inbound']
            words = [op['path'], op['summary'], *op['tags']].join(' ')
            domain = words.match?(/payout|transfer|payment/i)
            method_match = { 'create' => %w[POST], 'status' => %w[GET], 'cancel' => %w[DELETE POST], 'balance' => %w[GET] }.fetch(role, [])
            evidence << 'HTTP method and payment vocabulary' if !op['inbound'] && domain && method_match.include?(op['method'])
            evidence << 'cancellation vocabulary' if role == 'cancel' && words.match?(/cancel|void/i)
            evidence << 'balance vocabulary' if role == 'balance' && words.match?(/balance/i)
            next if evidence.empty?
            { 'operation_id' => op['operation_id'], 'method' => op['method'], 'path' => op['path'],
              'source_pointer' => op['source_pointer'], 'evidence' => evidence,
              'review_required' => true }
          end
          [role, ranked.sort_by { |item| [-item['evidence'].size, item['operation_id']] }]
        end
      end

      private

      def pointer_token(value)
        value.gsub('~', '~0').gsub('/', '~1')
      end

      def shallow(value)
        Input.dereference(document, value)
      end

      def collect_operations(path, raw_item, inbound, pointer, depth = 0)
        raise Error.new('Callback nesting exceeds the limit', code: 'REF_LIMIT', exit_code: 5) if depth > 16
        item = shallow(raw_item)
        return unless item.is_a?(Hash)
        item.each do |method, raw_operation|
          next unless METHODS.include?(method) && raw_operation.is_a?(Hash)
          operation = shallow(raw_operation)
          location = "#{pointer}/#{method}"
          @operation_sources[location] = [operation, item]
          @operations << operation_metadata(path, method, operation, item, inbound, location)
          operation.fetch('callbacks', {}).each do |name, raw_callback|
            callback = shallow(raw_callback)
            callback.each do |expression, callback_item|
              next if expression.start_with?('x-')
              collect_operations(expression, callback_item, true,
                                 "#{location}/callbacks/#{pointer_token(name)}/#{pointer_token(expression)}", depth + 1)
            end
          end
        end
      end

      def operation_metadata(path, method, operation, item, inbound, pointer)
        content = shallow(operation.fetch('requestBody', {})).fetch('content', {})
        media_type = content.key?('application/json') ? 'application/json' : content.keys.first
        {
          'operation_id' => operation['operationId'] || "#{method}:#{inbound ? pointer : path}",
          'method' => method.upcase, 'path' => path, 'inbound' => inbound, 'source_pointer' => pointer,
          'servers' => operation.fetch('servers', item.fetch('servers', document.fetch('servers', []))),
          'summary' => operation['summary'], 'tags' => operation.fetch('tags', []),
          'parameters' => merge_parameters(item.fetch('parameters', []).map { |p| shallow(p) }, operation.fetch('parameters', []).map { |p| shallow(p) }),
          'request_schema' => content.dig(media_type, 'schema') || {},
          'request_required' => shallow(operation.fetch('requestBody', {}))['required'] == true,
          'request_content' => content,
          'request_examples' => content[media_type] || {}, 'content_type' => media_type || 'application/json',
          'responses' => operation.fetch('responses', {}),
          'security' => operation.fetch('security', document.fetch('security', []))
        }
      end

      def infer(layers)
        title = document.dig('info', 'title').to_s
        slug = title.downcase.gsub(/[^a-z0-9]+/, '_').sub(/_+\z/, '')
        roles = ROLES.to_h do |role, regex|
          candidates = operations.select do |operation|
            if role == 'callback'
              operation['inbound']
            else
              !operation['inbound'] && operation['operation_id'].match?(regex)
            end
          end
          [role, candidates.one? ? candidates.first['operation_id'] : nil]
        end.compact
        result = { 'version' => 1, 'provider' => slug, 'class_name' => slug.split('_').map(&:capitalize).join + 'Service',
                   'operations' => roles }
        selected_roles = layers.reduce(roles) do |selected, layer|
          layer['operations'].is_a?(Hash) ? Paygen.deep_merge(selected, layer['operations']) : selected
        end
        outgoing_ids = selected_roles.reject { |role, _| role == 'callback' }.values
        schemes = document.dig('components', 'securitySchemes') || {}
        if schemes.size == 1
          scheme_name, auth = schemes.first
          if auth['type'] == 'apiKey'
            result['auth'] = auth.slice('type', 'in', 'name').merge('credential' => 'api_key')
          elsif auth['type'] == 'http'
            result['auth'] = { 'type' => auth['scheme'], 'credential' => 'token' }
          elsif auth['type'] == 'oauth2'
            requirements = operations.select { |op| !op['inbound'] && outgoing_ids.include?(op['operation_id']) }
                                     .flat_map { |op| op['security'] }.select { |requirement| requirement.key?(scheme_name) }
            unless requirements.empty?
              result['auth'] = { 'type' => 'oauth2', 'credential' => 'access_token',
                                 'scopes' => requirements.flat_map { |requirement| requirement.fetch(scheme_name) }.uniq.sort }
            end
          end
        end
        result
      end

      def validate_profile
        unless profile['version'] == 1
          diagnostic('PROFILE_VERSION', 'Unsupported integration profile version', 'version')
        end
        unless profile['provider'].is_a?(String) && profile['provider'].match?(/\A[a-z][a-z0-9_]*\z/)
          diagnostic('INVALID_PROVIDER', 'Provider slug must contain lowercase letters, numbers and underscores', 'provider')
        end
        unless profile['class_name'].is_a?(String) && profile['class_name'].match?(/\A[A-Z][A-Za-z0-9]*Service\z/)
          diagnostic('INVALID_CLASS', 'class_name must be a single Ruby service constant', 'class_name')
        end
        %w[operations request_mapping status_mapping amount].each do |key|
          diagnostic('SEMANTIC_REQUIRED', "Explicit #{key} configuration is required", key) if !profile[key].is_a?(Hash) || profile[key].empty?
        end
        operation_map = profile['operations'].is_a?(Hash) ? profile['operations'].compact : {}
        diagnostic('CREATE_REQUIRED', 'Select the outgoing create operation', 'operations.create') unless operation_map['create']
        operation_map.each do |role, operation_id|
          diagnostic('UNKNOWN_OPERATION', "Unknown operation selected for #{role}", "operations.#{role}") unless operations.any? { |op| op['operation_id'] == operation_id }
        end
        duplicates = operations.group_by { |op| op['operation_id'] }.select { |_id, items| items.size > 1 }
        diagnostic('DUPLICATE_OPERATION_ID', 'Operation identifiers must be unique', 'operations') unless duplicates.empty?
        operation_map.each do |role, operation_id|
          begin
            selected = endpoint(operation_id)
            next unless selected
            if role != 'callback' && selected['inbound']
              diagnostic('INBOUND_OPERATION', 'An inbound callback cannot be an outgoing operation', "operations.#{role}")
            end
            validate_parameters(role, selected) unless role == 'callback'
          rescue Paygen::Error => e
            @endpoint_cache[operation_id] = nil
            diagnostic(e.code, "Selected operation cannot be expanded: #{e.message}", "operations.#{role}")
          end
        end
        authenticated = profile.dig('auth', 'type') && profile.dig('auth', 'type') != 'none'
        auth_type = profile.dig('auth', 'type')
        if auth_type && !%w[none apiKey bearer basic oauth2 OAuth2].include?(auth_type)
          diagnostic('AUTH_UNSUPPORTED', 'Authentication requires an unsupported signing or authorization protocol', 'auth.type')
        end
        unless authenticated
          outgoing_ids = operation_map.reject { |role, _| role == 'callback' }.values
          protected_operations = operations.select do |op|
            !op['inbound'] && outgoing_ids.include?(op['operation_id']) &&
              !op['security'].empty? && op['security'].none?(&:empty?)
          end
          unless protected_operations.empty?
            diagnostic('AUTH_REQUIRED', 'Configure authentication for the selected protected operations', 'auth')
          end
        end
        if operation_map['callback'] && !profile.dig('callback', 'signature')
          diagnostic('CALLBACK_SIGNATURE_REQUIRED', 'Configure raw-body callback verification', 'callback.signature')
        end
        amount = profile.fetch('amount', {})
        unless amount['scale'].is_a?(Integer) && amount['scale'].positive? && amount['scale'].to_s.match?(/\A10*\z/)
          diagnostic('AMOUNT_SCALE_REQUIRED', 'Declare an integer power-of-ten amount scale', 'amount.scale')
        end
        unless amount['currencies'].is_a?(Array) && !amount['currencies'].empty? && amount['currencies'].all? { |c| c.is_a?(String) && c.match?(/\A[A-Z]{3}\z/) }
          diagnostic('CURRENCIES_REQUIRED', 'Declare supported ISO currency codes', 'amount.currencies')
        end
        %w[minimum maximum].each do |bound|
          next unless amount.key?(bound)
          diagnostic('INVALID_AMOUNT_BOUND', 'Amount bounds must be nonnegative integer provider units', "amount.#{bound}") unless amount[bound].is_a?(Integer) && amount[bound] >= 0
        end
        if amount['minimum'].is_a?(Integer) && amount['maximum'].is_a?(Integer) && amount['minimum'] > amount['maximum']
          diagnostic('INVALID_AMOUNT_BOUND', 'Minimum exceeds maximum', 'amount')
        end
        if amount['input_unit'] && !%w[major minor].include?(amount['input_unit'])
          diagnostic('INVALID_AMOUNT_UNIT', 'input_unit must be major or minor', 'amount.input_unit')
        end
        profile.fetch('request_mapping', {}).each do |target, rule|
          unless MappingRule.valid?(rule)
            diagnostic('INVALID_MAPPING', 'Mapping must use one source/literal and valid fallback/default/equality options', "request_mapping.#{target}")
          end
        end
        profile.fetch('request_mappings', {}).each do |role, mappings|
          if !mappings.is_a?(Hash)
            diagnostic('INVALID_MAPPING', 'Role mappings must be an object', "request_mappings.#{role}")
            next
          end
          mappings.each do |target, rule|
            unless MappingRule.valid?(rule)
              diagnostic('INVALID_MAPPING', 'Mapping must use one source/literal and valid fallback/default/equality options', "request_mappings.#{role}.#{target}")
            end
          end
        end
        if operation_map['callback']
          signature = profile.dig('callback', 'signature')
          if !signature.is_a?(Hash) || !signature['algorithm'].is_a?(String) || signature['algorithm'].empty?
            diagnostic('SIGNATURE_ALGORITHM_REQUIRED', 'Declare a callback verification algorithm', 'callback.signature.algorithm')
          end
        end
        if operation_map['create'] && !profile['idempotency'].is_a?(Hash)
          diagnostic('IDEMPOTENCY_REQUIRED', 'Configure a stable idempotency key before generating payouts', 'idempotency')
        end
        strategy = profile.dig('idempotency', 'strategy')
        if strategy && !%w[provider_key reconcile_before_retry].include?(strategy)
          diagnostic('IDEMPOTENCY_STRATEGY_UNSUPPORTED', 'Use provider_key or reconcile_before_retry', 'idempotency.strategy')
        end
        idempotency = profile.fetch('idempotency', {})
        %w[header body from].each do |field|
          value = idempotency[field]
          next if value.nil? || (value.is_a?(String) && !value.empty?)

          diagnostic('INVALID_IDEMPOTENCY', 'Identity fields must be nonempty strings or null', "idempotency.#{field}")
        end
        if idempotency.key?('ttl_seconds') && !(idempotency['ttl_seconds'].is_a?(Integer) && idempotency['ttl_seconds'].positive?)
          diagnostic('INVALID_IDEMPOTENCY_TTL', 'Provider key retention must be a positive integer number of seconds', 'idempotency.ttl_seconds')
        end
        if strategy == 'provider_key' && !%w[header body].any? { |field| idempotency[field].is_a?(String) && !idempotency[field].empty? }
          diagnostic('IDEMPOTENCY_IDENTITY_REQUIRED', 'A provider-key policy requires an explicit header or body identity', 'idempotency')
        end
        statuses = profile['status_mapping']
        if statuses.is_a?(Hash) && statuses.values.any? { |status| !%w[in_progress approved rejected reversed unknown].include?(status) }
          diagnostic('INVALID_STATUS_MAP', 'Target statuses must be canonical payout states', 'status_mapping')
        end
      end

      def diagnostic(code, message, path)
        diagnostics << { 'code' => code, 'severity' => 'blocker', 'message' => message, 'path' => path }
      end

      def require_object!(value, path)
        return if value.is_a?(Hash)
        raise Error.new("#{path} must be an object", code: 'INVALID_PROFILE', exit_code: 3)
      end

      def validate_nested_shapes!
        %w[auth.headers callback.signature callback.events callback.constraints response.roles errors.roles].each do |path|
          parent, key = path.split('.')
          container = profile[parent]
          require_object!(container[key], path) if container&.key?(key)
        end
        %w[response errors].each do |key|
          profile.dig(key, 'roles')&.each { |role, rules| require_object!(rules, "#{key}.roles.#{role}") }
        end
        auth = profile.fetch('auth', {})
        %w[type credential username password in name].each do |key|
          next unless auth.key?(key)
          unless auth[key].is_a?(String) && !auth[key].empty?
            raise Error.new("auth.#{key} must be a nonempty string", code: 'INVALID_PROFILE', exit_code: 3)
          end
        end
        auth.fetch('headers', {}).each do |name, rule|
          valid = rule.is_a?(String) && !rule.empty?
          if rule.is_a?(Hash) && (rule.keys & %w[value credential]).size == 1
            valid = rule.key?('credential') ? (rule['credential'].is_a?(String) && !rule['credential'].empty?) :
              (rule['value'].is_a?(String) || rule['value'].is_a?(Numeric) || [true, false].include?(rule['value']))
          end
          unless valid
            raise Error.new("auth.headers.#{name} must declare a credential name or scalar literal", code: 'INVALID_PROFILE', exit_code: 3)
          end
        end
        profile.fetch('parameter_mapping', {}).each do |role, mappings|
          require_object!(mappings, "parameter_mapping.#{role}")
          mappings.each do |name, mapping|
            if %w[path query header cookie].include?(name)
              require_object!(mapping, "parameter_mapping.#{role}.#{name}")
              mapping.each { |parameter, rule| validate_parameter_rule!(rule, "parameter_mapping.#{role}.#{name}.#{parameter}") }
            else
              validate_parameter_rule!(mapping, "parameter_mapping.#{role}.#{name}")
            end
          end
        end
      end

      def validate_parameter_rule!(rule, path)
        return if rule.is_a?(String) && !rule.empty?
        valid = rule.is_a?(Hash) && (rule.keys & %w[from value credential]).size == 1 &&
                (!rule.key?('from') || rule['from'].is_a?(String)) &&
                (!rule.key?('credential') || rule['credential'].is_a?(String))
        return if valid
        raise Error.new("#{path} must declare one source, credential or literal value", code: 'INVALID_PROFILE', exit_code: 3)
      end

      def validate_parameters(role, operation)
        mappings = profile.dig('parameter_mapping', role) || {}
        mappings.each_key do |name|
          next if %w[path query header cookie].include?(name)
          definitions = operation.fetch('parameters', []).select { |parameter| parameter['name'] == name }
          if definitions.any? && definitions.none? { |parameter| parameter['in'] == 'path' }
            diagnostic('PARAMETER_LOCATION_REQUIRED', 'Query and header mappings must be nested under their location', "parameter_mapping.#{role}.#{name}")
          end
        end
        operation.fetch('parameters', []).each do |parameter|
          location = parameter['in']
          style = parameter.fetch('style', location == 'query' ? 'form' : 'simple')
          schema = parameter.fetch('schema', {})
          unsupported = !%w[path query header].include?(location) || parameter.key?('content') ||
                        parameter['allowReserved'] || style != (location == 'query' ? 'form' : 'simple') ||
                        schema['type'] == 'object' || schema.key?('properties') ||
                        (schema['type'] == 'array' && schema.dig('items', 'type') == 'object')
          next unless unsupported
          diagnostic('PARAMETER_UNSUPPORTED', 'Parameter requires unsupported location, content or serialization; supply an explicit contract overlay',
                     "parameters.#{role}.#{location}.#{parameter['name']}")
        end
      end

      def record_provenance(value, path, origin)
        value.each do |key, item|
          key_path = path.empty? ? key : "#{path}.#{key}"
          if item.is_a?(Hash)
            record_provenance(item, key_path, origin)
          else
            provenance[key_path] = { 'origin' => origin, 'value' => item }
          end
        end
      end

      def merge_parameters(common, local)
        (common + local).each_with_object({}) { |p, result| result[[p['in'], p['name']]] = p }.values
      end
    end
  end
end
