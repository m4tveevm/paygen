# frozen_string_literal: true

module Paygen
  module Core
    # Validate the nested values consumed by runtime before emitting a service.
    # Messages describe types/options only; configuration values may be secrets.
    class ProfileValidation
      OUTGOING_ROLES = Capabilities::OUTGOING_ROLES
      ROLES = (OUTGOING_ROLES + ['callback']).freeze
      RESPONSE_PATHS = %w[id status error items item_status item_id item_external_id account_field mode_field].freeze
      CALLBACK_PATHS = %w[id external_id status event event_id sequence timestamp account_field mode_field error].freeze

      def initialize(profile, diagnostics)
        @profile, @diagnostics = profile, diagnostics
      end

      def validate
        @profile.fetch('operations', {}).each do |role, operation|
          enum(role, ROLES, "operations.#{role}")
          string(operation, "operations.#{role}") unless operation.nil?
        end
        validate_errors(@profile.fetch('errors', {}), 'errors')
        validate_response(@profile.fetch('response', {}), 'response')
        validate_callback
        validate_actions
        validate_lifecycle
        auth = @profile.fetch('auth', {})
        if auth.key?('scopes') && !(auth['scopes'].is_a?(Array) && auth['scopes'].all? { |scope| nonempty_string?(scope) })
          invalid('auth.scopes', 'an array of nonempty strings', auth['scopes'])
        end
        if auth['type'] == 'apiKey' && !nonempty_string?(auth['name'])
          invalid('auth.name', 'a nonempty API key parameter name', auth['name'])
        end
      end

      private

      def validate_lifecycle
        %w[request_mappings parameter_mapping].each do |group|
          @profile.fetch(group, {}).each_key { |role| enum(role, OUTGOING_ROLES, "#{group}.#{role}") }
        end
        %w[account_field mode_field].each { |key| string(@profile[key], key) if @profile.key?(key) }
        if @profile.key?('mode_values') && !@profile['mode_values'].is_a?(Hash)
          invalid('mode_values', 'an object', @profile['mode_values'])
        end
        if @profile.key?('status_order')
          value = @profile['status_order']
          invalid('status_order', 'an array of status strings', value) unless value.is_a?(Array) && value.all? { |status| nonempty_string?(status) }
        end
        transitions = @profile.fetch('status_transitions', {})
        unless transitions.is_a?(Hash)
          invalid('status_transitions', 'an object mapping states to arrays', transitions)
          return
        end
        transitions.each do |status, targets|
          unless targets.is_a?(Array) && targets.all? { |target| nonempty_string?(target) }
            invalid("status_transitions.#{status}", 'an array of status strings', targets)
          end
        end
      end

      def validate_actions
        mappings = @profile.fetch('action_mapping', {})
        return invalid('action_mapping', 'an object', mappings) unless mappings.is_a?(Hash)
        mappings.each do |action, role|
          path = "action_mapping.#{action}"
          string(action, path)
          enum(role, OUTGOING_ROLES, path)
          if (ROLES.include?(action) && action != role) || !@profile.fetch('operations', {})[role]
            invalid(path, 'an alias to a selected outgoing role without remapping a canonical role', role)
          end
        end
      end

      def validate_errors(errors, path)
        errors.each do |status, rule|
          if status == 'roles'
            unless path == 'errors'
              invalid("#{path}.roles", 'role rules only directly under errors.roles', rule)
              next
            end
            rule.each do |role, rules|
              enum(role, OUTGOING_ROLES, "#{path}.roles.#{role}")
              validate_errors(rules, "#{path}.roles.#{role}")
            end
            next
          end
          field = "#{path}.#{status}"
          invalid(field, 'an HTTP status key from 100 through 599', status) unless status.to_s.match?(/\A[1-5]\d\d\z/)
          unless rule.is_a?(Hash)
            invalid(field, 'an object with code and/or action', rule)
            next
          end
          invalid(field, 'at least one code or action field', rule) if (rule.keys & %w[code action]).empty?
          rule.each_key { |key| invalid("#{field}.#{key}", 'a supported code or action option', rule[key]) unless %w[code action].include?(key) }
          string(rule['code'], "#{field}.code") if rule.key?('code')
          enum(rule['action'], %w[reject retry reconcile], "#{field}.action") if rule.key?('action')
        end
      end

      def validate_response(response, path)
        RESPONSE_PATHS.each { |key| string(response[key], "#{path}.#{key}") if response.key?(key) }
        enum(response['scope'], %w[batch operation item], "#{path}.scope") if response.key?('scope')
        if response.key?('mode_values')
          values = response['mode_values']
          invalid("#{path}.mode_values", 'an object', values) unless values.is_a?(Hash)
        end
        if response.key?('roles') && path != 'response'
          invalid("#{path}.roles", 'role rules only directly under response.roles', response['roles'])
          return
        end
        response.fetch('roles', {}).each do |role, config|
          enum(role, OUTGOING_ROLES, "#{path}.roles.#{role}")
          validate_response(config, "#{path}.roles.#{role}")
        end
      end

      def validate_callback
        callback = @profile.fetch('callback', {})
        CALLBACK_PATHS.each { |key| string(callback[key], "callback.#{key}") if callback.key?(key) }
        callback.fetch('events', {}).each { |event, status| string(status, "callback.events.#{event}") unless status.nil? }
        signature = callback['signature']
        return unless signature
        enum(signature['algorithm'], Capabilities::SIGNATURE_ALGORITHMS, 'callback.signature.algorithm')
        %w[header credential].each { |key| string(signature[key], "callback.signature.#{key}") if signature.key?(key) }
        if signature.key?('credentials') && !(signature['credentials'].is_a?(Array) && !signature['credentials'].empty? && signature['credentials'].all? { |name| nonempty_string?(name) })
          invalid('callback.signature.credentials', 'a nonempty array of credential names', signature['credentials'])
        end
        enum(signature['encoding'], %w[hex base64], 'callback.signature.encoding') if signature.key?('encoding')
        enum(signature['key_encoding'], %w[hex raw], 'callback.signature.key_encoding') if signature.key?('key_encoding')
        if signature.key?('prefix') && !signature['prefix'].is_a?(String)
          invalid('callback.signature.prefix', 'a string', signature['prefix'])
        end
        if signature.key?('tolerance') && !(signature['tolerance'].is_a?(Integer) && signature['tolerance'] >= 0)
          invalid('callback.signature.tolerance', 'a nonnegative integer number of seconds', signature['tolerance'])
        end
        allowed_encodings = Capabilities::SIGNATURE_ENCODINGS[signature['algorithm']]
        if allowed_encodings && !allowed_encodings.include?(signature.fetch('encoding', 'hex'))
          invalid('callback.signature.encoding', "a supported encoding for the selected algorithm: #{allowed_encodings.join(', ')}", signature['encoding'])
        end
      end

      def nonempty_string?(value)
        value.is_a?(String) && !value.empty? && !value.match?(/[\x00\r\n]/)
      end

      def string(value, path)
        invalid(path, 'a nonempty string without control characters', value) unless nonempty_string?(value)
      end

      def enum(value, allowed, path)
        invalid(path, "one of #{allowed.join(', ')}", value) unless allowed.include?(value)
      end

      def invalid(path, expected, value)
        @diagnostics << { 'code' => 'INVALID_PROFILE', 'severity' => 'blocker', 'path' => path,
                          'message' => "Expected #{expected}; received #{value.class}" }
      end
    end
  end
end
