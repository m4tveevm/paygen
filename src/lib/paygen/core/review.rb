# frozen_string_literal: true

module Paygen
  module Core
    # A saved value is not evidence of review. Bind explicit decisions to the
    # relevant effective contract; keep reads deterministic and side-effect free.
    class Review
      VERSION = 1
      NAMING = %w[provider class_name version].freeze

      def initialize(ir, state = nil)
        @ir = ir
        @state = state
        @dependencies = {}
        if state && (invalid_path = invalid_state_path(state))
          raise Error.new("Invalid review metadata at #{invalid_path}; restore review.json from a trusted backup",
                          code: 'INVALID_REVIEW', exit_code: 3, details: { 'path' => invalid_path })
        end
      end

      def basis
        @basis ||= {
          'endpoints' => @ir.profile.fetch('operations', {}).to_h { |role, id| [role, endpoint(id)] },
          'security_schemes' => @ir.document.dig('components', 'securitySchemes') || {},
          'vendor_profile' => @ir.document.fetch('x-paygen', {}),
          'description' => @ir.document.dig('info', 'description')
        }
      end

      def capture(paths = @ir.provenance.keys, initial: false)
        state = @state ? Marshal.load(Marshal.dump(@state)) : { 'version' => VERSION, 'basis' => basis, 'manual_additions' => initial, 'decisions' => {} }
        paths.each do |path|
          fact = @ir.provenance[path]
          next unless fact && critical?(path) && fact['origin'] != 'inference'
          state['decisions'][path] = { 'value_sha256' => digest(fact['value']), 'dependency_sha256' => dependency(path, basis) }
        end
        state
      end

      def apply
        @ir.provenance.each do |path, fact|
          next unless critical?(path)
          state = review_state(path, fact)
          fact['review_state'] = state
          fact['review_required'] = %w[legacy stale].include?(state) ||
                                    (state == 'inferred' && @ir.diagnostics.any? { |item| item['severity'] == 'blocker' && item['path'] == path })
          next unless %w[legacy stale].include?(state)
          @ir.diagnostics << {
            'code' => state == 'legacy' ? 'REVIEW_METADATA_REQUIRED' : 'REVIEW_STALE', 'severity' => 'blocker',
            'path' => path,
            'message' => "#{state == 'legacy' ? 'No saved review evidence' : 'Relevant contract or operation changed'}; " \
                         "review this decision and reapply it with configure PROJECT --answers FILE or --set #{path}=VALUE. " \
                         'Previously generated files are stale; regenerate after resolving blockers.'
          }
        end
        @ir
      end

      def self.paths(value, prefix = '')
        value.flat_map do |key, item|
          path = prefix.empty? ? key : "#{prefix}.#{key}"
          item.is_a?(Hash) ? paths(item, path) : [path]
        end
      end

      private

      def invalid_state_path(state)
        return 'review' unless state.is_a?(Hash) && state['version'] == VERSION
        return 'review.decisions' unless state['decisions'].is_a?(Hash)
        return 'review.basis' unless state['basis'].is_a?(Hash)
        source = state['basis']
        %w[endpoints security_schemes vendor_profile].each do |key|
          return "review.basis.#{key}" unless source[key].is_a?(Hash)
        end
        source['endpoints'].each do |role, operation|
          next if operation.nil?
          return "review.basis.endpoints.#{role}" unless operation.is_a?(Hash)
          unless operation['security'].is_a?(Array) && operation['security'].all? { |item| item.is_a?(Hash) }
            return "review.basis.endpoints.#{role}.security"
          end
        end
        state['decisions'].each do |path, fact|
          return "review.decisions.#{path}" unless fact.is_a?(Hash)
          %w[value_sha256 dependency_sha256].each do |key|
            return "review.decisions.#{path}.#{key}" unless fact[key].is_a?(String) && fact[key].match?(/\A[0-9a-f]{64}\z/)
          end
        end
        nil
      end

      def endpoint(id)
        operation = @ir.endpoint(id)
        return unless operation
        raw = operation['source_pointer'].split('/').drop(1).reduce(@ir.document) { |value, token| Input.dereference(@ir.document, value)[token.gsub('~1', '/').gsub('~0', '~')] }
        operation.merge('review_description' => Input.dereference(@ir.document, raw)['description'])
      end

      def critical?(path)
        return false if path.start_with?('callback.') && @ir.profile.dig('operations', 'callback').nil?
        return false if path.start_with?('auth.') && path != 'auth.type' && @ir.profile.dig('auth', 'type') == 'none'
        !NAMING.include?(path.split('.').first)
      end

      def review_state(path, fact)
        return 'inferred' if fact['origin'] == 'inference'
        return 'explicit-override' if fact['origin'] == 'cli-override'
        return 'legacy' unless @state
        previous = @state['decisions'][path]
        return 'legacy' unless previous || @state['manual_additions'] == true
        expected = previous ? previous['dependency_sha256'] : dependency(path, @state['basis'])
        return 'stale' unless expected == dependency(path, basis)
        return 'confirmed' if previous && previous['value_sha256'] == digest(fact['value'])
        fact['origin'] == 'integration-profile' ? 'explicit-edit' : 'stale'
      end

      def dependency(path, source)
        group, role = path.split('.')
        cache_key = [source.object_id, group, %w[operations request_mappings parameter_mapping].include?(group) ? role : nil]
        return @dependencies[cache_key] if @dependencies.key?(cache_key)
        endpoints = source.fetch('endpoints', {})
        selected = case group
                   when 'operations', 'request_mappings', 'parameter_mapping' then { role => endpoints[role] }
                   when 'callback' then { 'callback' => endpoints['callback'] }
                   when 'request_mapping', 'amount', 'idempotency', 'conditions' then { 'create' => endpoints['create'] }
                   when 'auth' then endpoints.reject { |key, _| key == 'callback' }.transform_values { |op| op && op.slice('operation_id', 'security') }
                   else endpoints
                   end
        # Only security schemes actually referenced by the selected operations
        # matter. Adding an unrelated operation or scheme does not reset review.
        names = selected.values.compact.flat_map { |op| Array(op['security']).flat_map(&:keys) }.uniq
        schemes = source.fetch('security_schemes', {}).slice(*names)
        @dependencies[cache_key] = digest({ 'endpoints' => selected, 'security_schemes' => schemes,
                                          'vendor_profile' => source.fetch('vendor_profile', {})[group],
                                          'description' => source['description'] })
      end

      def digest(value)
        Digest::SHA256.hexdigest(Paygen.json(value))
      end
    end
  end
end
