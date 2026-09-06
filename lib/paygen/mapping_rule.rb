# frozen_string_literal: true

module Paygen
  # Bounded declarative mapping: field/literal, optional fallback/default and one
  # equality condition. Paths are read by the caller; no expression is evaluated.
  module MappingRule
    module_function

    def valid?(rule)
      return false unless rule.is_a?(Hash) && (rule.key?('from') ^ rule.key?('value'))
      return false unless (rule.keys - %w[from value transform fallback_from fallback_conflict default when]).empty?
      return false if rule.key?('from') && !path?(rule['from'])
      return false if rule.key?('value') && (rule.key?('fallback_from') || rule.key?('default'))
      if rule.key?('fallback_from')
        paths = rule['fallback_from']
        return false unless paths.is_a?(Array) && paths.length.between?(1, 16) && paths.all? { |path| path?(path) }
      end
      return false if rule.key?('fallback_conflict') && (rule['fallback_conflict'] != 'reject' || !rule.key?('fallback_from'))
      return true unless rule.key?('when')

      condition = rule['when']
      condition.is_a?(Hash) && (condition.keys - %w[from equals default]).empty? &&
        path?(condition['from']) && condition.key?('equals') && scalar?(condition['equals']) &&
        (!condition.key?('default') || scalar?(condition['default']))
    end

    def applies?(rule)
      return true unless rule.key?('when')

      condition = rule.fetch('when')
      actual = yield condition.fetch('from')
      actual = condition['default'] if actual.nil? && condition.key?('default')
      actual == condition.fetch('equals')
    end

    def value(rule)
      return rule['value'] if rule.key?('value')

      primary = yield rule.fetch('from')
      return primary unless primary.nil?

      fallbacks = rule.fetch('fallback_from', []).map { |path| yield path }.compact
      if rule['fallback_conflict'] == 'reject' && fallbacks.uniq.length > 1
        raise ArgumentError, 'conflicting fallback mapping evidence; supply the primary field explicitly'
      end
      fallbacks.empty? ? rule['default'] : fallbacks.first
    end

    def path?(value)
      value.is_a?(String) && !value.empty?
    end

    def scalar?(value)
      value.nil? || value.is_a?(String) || value.is_a?(Integer) || value == true || value == false ||
        (value.is_a?(Float) && value.finite?)
    end
  end
end
