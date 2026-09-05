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
        @document = document
        @diagnostics = []
        inferred = infer
        vendor = document.fetch('x-paygen', {})
        unless vendor.is_a?(Hash)
          raise Error.new('x-paygen must be an object', code: 'INVALID_PROFILE', exit_code: 3)
        end
        @profile = [vendor, recipe, profile, overrides].reduce(inferred) { |memo, layer| Paygen.deep_merge(memo, layer) }
        @provenance = {}
        [['inference', inferred], ['vendor-extension', vendor], ['recipe', recipe],
         ['integration-profile', profile], ['cli-override', overrides]].each do |origin, layer|
          record_provenance(layer, '', origin)
        end
        validate_profile
      end

      def operations
        @operations ||= document.fetch('paths', {}).flat_map do |path, item|
          next [] unless item.is_a?(Hash)
          item.filter_map do |method, operation|
            next unless METHODS.include?(method) && operation.is_a?(Hash)
            content = operation.dig('requestBody', 'content') || {}
            media_type = content.key?('application/json') ? 'application/json' : content.keys.first
            {
              'operation_id' => operation['operationId'] || "#{method}:#{path}",
              'method' => method.upcase, 'path' => path,
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
          [role, operation]
        end.compact
        profile.merge('endpoints' => endpoints, 'servers' => document.fetch('servers', []).map { |s| s['url'] },
                      'source_hash' => Digest::SHA256.hexdigest(Paygen.json(document)))
      end

      def to_h
        { 'openapi' => document['openapi'], 'title' => document.dig('info', 'title'),
          'operations' => operations, 'profile' => profile, 'diagnostics' => diagnostics }
      end

      private

      def infer
        title = document.dig('info', 'title').to_s
        slug = title.downcase.gsub(/[^a-z0-9]+/, '_').sub(/_+\z/, '')
        roles = ROLES.to_h do |role, regex|
          candidates = operations.select { |operation| operation['operation_id'].match?(regex) }
          [role, candidates.one? ? candidates.first['operation_id'] : nil]
        end.compact
        result = { 'version' => 1, 'provider' => slug, 'class_name' => slug.split('_').map(&:capitalize).join + 'Service',
                   'operations' => roles }
        schemes = document.dig('components', 'securitySchemes') || {}
        if schemes.size == 1
          auth = schemes.values.first
          if auth['type'] == 'apiKey'
            result['auth'] = auth.slice('type', 'in', 'name').merge('credential' => 'api_key')
          elsif auth['type'] == 'http'
            result['auth'] = { 'type' => auth['scheme'], 'credential' => 'token' }
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
        if operation_map['callback'] && !profile.dig('callback', 'signature')
          diagnostic('CALLBACK_SIGNATURE_REQUIRED', 'Configure raw-body callback verification', 'callback.signature')
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
