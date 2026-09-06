# frozen_string_literal: true

module Paygen
  # A small opt-in correlation contract, not an expression language. Identity
  # and currency comparison is exact; only amount declares a unit conversion.
  module ResponseBindings
    NAMES = %w[merchant_reference provider_id amount currency].freeze
    ROLES = %w[create status cancel].freeze
    FIELDS = %w[response_path operation_path roles required].freeze
    module_function

    def valid?(name, rule)
      return false unless NAMES.include?(name) && rule.is_a?(Hash)
      fields = name == 'amount' ? FIELDS + ['response_unit'] : FIELDS
      return false unless (rule.keys - fields).empty? && (fields - rule.keys).empty?
      return false unless %w[response_path operation_path].all? { |key| rule[key].is_a?(String) && !rule[key].empty? }
      return false unless [true, false].include?(rule['required'])
      return false unless rule['roles'].is_a?(Array) && !rule['roles'].empty? &&
                          rule['roles'].uniq == rule['roles'] && (rule['roles'] - ROLES).empty?

      name != 'amount' || %w[major minor].include?(rule['response_unit'])
    end
  end
end
