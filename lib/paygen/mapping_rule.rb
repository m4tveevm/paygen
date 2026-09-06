# frozen_string_literal: true

module Paygen
  # Bounded declarative mapping: field/literal, optional fallback/default and one
  # equality condition. Paths are read by the caller; no expression is evaluated.
  module MappingRule
    module_function

    def valid?(rule)
      return false unless rule.is_a?(Hash) && (rule.key?('from') ^ rule.key?('value'))
      return false unless (rule.keys - %w[from value transform fallback_from default when]).empty?
      return false if rule.key?('from') && !path?(rule['from'])
      return false if rule.key?('value') && (rule.key?('fallback_from') || rule.key?('default'))
      if rule.key?('fallback_from')
        paths = rule['fallback_from']
        return false unless paths.is_a?(Array) && paths.length.between?(1, 16) && paths.all? { |path| path?(path) }
      end
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

      [rule.fetch('from'), *rule.fetch('fallback_from', [])].each do |path|
        found = yield path
        return found unless found.nil?
      end
      rule['default']
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
