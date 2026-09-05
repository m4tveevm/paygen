# frozen_string_literal: true
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
        %w[operations request_mapping status_mapping amount response idempotency auth callback errors parameter_mapping].each do |key|
          next unless @profile.key?(key)
          unless @profile[key].is_a?(Hash)
            raise Error.new("#{key} must be an object", code: 'INVALID_PROFILE', exit_code: 3)
          end
        end
        @provenance = {}
        [['inference', inferred], ['vendor-extension', vendor], ['recipe', recipe],
         ['integration-profile', profile], ['cli-override', overrides]].each do |origin, layer|
          record_provenance(layer, '', origin)
        end
        validate_profile
      end

      def operations
        @operations ||= document.fetch('paths', {}).map { |path, item| [path, item, false] }.concat(
          document.fetch('webhooks', {}).map { |name, item| [name, item, true] }
        ).flat_map do |path, item, inbound|
          next [] unless item.is_a?(Hash)
          item.filter_map do |method, operation|
            next unless METHODS.include?(method) && operation.is_a?(Hash)
            content = operation.dig('requestBody', 'content') || {}
            media_type = content.key?('application/json') ? 'application/json' : content.keys.first
            {
              'operation_id' => operation['operationId'] || "#{method}:#{path}",
              'method' => method.upcase, 'path' => path,
              'inbound' => inbound,
              'servers' => operation.fetch('servers', item.fetch('servers', document.fetch('servers', []))),
              'summary' => operation['summary'],
              'parameters' => merge_parameters(item.fetch('parameters', []), operation.fetch('parameters', [])),
              'request_schema' => content.dig(media_type, 'schema') || {},
              'request_examples' => content[media_type] || {},
              'content_type' => media_type || 'application/json',
              'responses' => operation.fetch('responses', {}),
              'security' => operation.fetch('security', document.fetch('security', []))
            }
          end
        end
      end

      def config
        endpoints = profile.fetch('operations', {}).to_h do |role, operation_id|
          operation = operations.find { |item| item['operation_id'] == operation_id }
          operation = operation.merge('servers' => profile['servers']) if operation && profile.key?('servers')
          [role, operation]
        end.compact
        create_servers = endpoints.dig('create', 'servers') || document.fetch('servers', [])
        profile.merge('openapi' => document['openapi'], 'endpoints' => endpoints, 'servers' => profile.fetch('servers', create_servers),
                      'source_hash' => Digest::SHA256.hexdigest(Paygen.json(document)))
      end

      def to_h
        { 'openapi' => document['openapi'], 'title' => document.dig('info', 'title'),
          'operations' => operations, 'profile' => profile, 'diagnostics' => diagnostics }
      end

      private

      def infer(layers)
        title = document.dig('info', 'title').to_s
        slug = title.downcase.gsub(/[^a-z0-9]+/, '_').sub(/_+\z/, '')
        roles = ROLES.to_h do |role, regex|
          candidates = operations.select { |operation| operation['operation_id'].match?(regex) || (role == 'callback' && operation['inbound']) }
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
        operation_map = profile['operations'].is_a?(Hash) ? profile['operations'] : {}
        diagnostic('CREATE_REQUIRED', 'Select the outgoing create operation', 'operations.create') unless operation_map['create']
        operation_map.each do |role, operation_id|
          diagnostic('UNKNOWN_OPERATION', "Unknown operation selected for #{role}", "operations.#{role}") unless operations.any? { |op| op['operation_id'] == operation_id }
        end
        authenticated = profile.dig('auth', 'type') && profile.dig('auth', 'type') != 'none'
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
          unless rule.is_a?(Hash) && (rule.key?('from') ^ rule.key?('value')) && (!rule.key?('from') || rule['from'].is_a?(String))
            diagnostic('INVALID_MAPPING', 'Each mapping declares exactly one source field or literal value', "request_mapping.#{target}")
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
        statuses = profile['status_mapping']
        if statuses.is_a?(Hash) && statuses.values.any? { |status| !%w[in_progress approved rejected reversed unknown].include?(status) }
          diagnostic('INVALID_STATUS_MAP', 'Target statuses must be canonical payout states', 'status_mapping')
        end
      end

      def diagnostic(code, message, path)
        diagnostics << { 'code' => code, 'severity' => 'blocker', 'message' => message, 'path' => path }
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
