# frozen_string_literal: true

require 'json_schemer'

module Paygen
  # A bounded example builder, not a general JSON Schema or regex solver.
  # Every proposal is checked against the complete schema, including parents.
  class SchemaExample
    MAX_DEPTH = 16
    MAX_CANDIDATES = 64
    MAX_ITEMS = 100
    MAX_STRING = 10_000
    MAX_WORK = 10_000

    def initialize(normalize: ->(schema) { schema })
      @normalize = normalize
    end

    def call(schema, depth = 0)
      @remaining = MAX_WORK if depth.zero? || @remaining.nil?
      candidates(schema, depth).find { |value| valid?(schema, value) }
    end

    private

    def valid?(schema, value)
      return false unless spend_work
      JSONSchemer.schema(@normalize.call(schema)).valid?(value)
    end

    def spend_work
      return false unless @remaining.positive?
      @remaining -= 1
      true
    end

    def candidates(schema, depth)
      return [] unless spend_work
      return [] if depth > MAX_DEPTH || schema == false
      return [nil, 'x', 0, {}] if schema == true || schema == {}
      return [] unless schema.is_a?(Hash)
      return [] if %w[allOf oneOf anyOf].any? { |key| schema[key].is_a?(Array) && schema[key].size > MAX_CANDIDATES }

      proposed = %w[example default const].filter_map { |key| [schema[key]] if schema.key?(key) }.flatten(1)
      proposed.concat(schema['enum']) if schema['enum'].is_a?(Array)
      if schema['allOf']
        merged = schema['allOf'].reduce(schema.reject { |key, _| key == 'allOf' }) { |base, child| intersect(base, child) }
        proposed.concat(candidates(merged, depth + 1))
      elsif schema['oneOf'] || schema['anyOf']
        alternatives = schema['oneOf'] || schema['anyOf']
        parent = schema.reject { |key, _| %w[oneOf anyOf].include?(key) }
        alternatives.first(MAX_CANDIDATES).each { |child| proposed.concat(candidates(intersect(parent, child), depth + 1)) }
      else
        Array(schema.fetch('type', schema['properties'] || schema['required'] ? 'object' : 'string')).each do |type|
          proposed.concat(type_candidates(type, schema, depth))
        end
      end
      proposed.uniq.first(MAX_CANDIDATES).select { |value| valid?(schema, value) }
    end

    def intersect(left, right)
      return false if left == false || right == false
      return left if right == true
      return right if left == true
      left.merge(right) do |key, old, fresh|
        case key
        when 'required' then (Array(old) + Array(fresh)).uniq
        when 'properties' then old.merge(fresh) { |_name, first, second| { 'allOf' => [first, second] } }
        when 'enum' then old & fresh
        when 'minimum', 'minLength', 'minItems' then [old, fresh].max
        when 'maximum', 'maxLength', 'maxItems' then [old, fresh].min
        else fresh
        end
      end
    end

    def type_candidates(type, schema, depth)
      case type
      when 'object'
        properties = schema.fetch('properties', {})
        required = Array(schema['required'])
        keys = [(properties.keys | required), required].uniq
        keys.filter_map do |names|
          next if names.size > MAX_ITEMS
          value = names.to_h { |name| [name, call(properties.fetch(name, {}), depth + 1)] }
          value
        end
      when 'array'
        count = [schema.fetch('minItems', 1), 1].max
        count = [count, schema['maxItems']].min if schema['maxItems']
        return [] if count > MAX_ITEMS
        item = call(schema.fetch('items', {}), depth + 1)
        [Array.new(count) { item }, []]
      when 'boolean' then [false, true]
      when 'null' then [nil]
      when 'number', 'integer'
        lower = schema.fetch('minimum', 0)
        exclusive = schema['exclusiveMinimum']
        lower = [lower, exclusive + 1].max if exclusive.is_a?(Numeric)
        lower += 1 if exclusive == true
        multiple = schema['multipleOf']
        lower = (lower.to_r / multiple.to_r).ceil * multiple if multiple.is_a?(Numeric) && multiple.positive?
        upper = schema['maximum']
        exclusive_upper = schema['exclusiveMaximum']
        upper = exclusive_upper - 1 if exclusive_upper.is_a?(Numeric)
        upper -= 1 if exclusive_upper == true && upper
        raw_lower = schema['exclusiveMinimum'].is_a?(Numeric) ? schema['exclusiveMinimum'] : schema['minimum']
        raw_upper = schema['exclusiveMaximum'].is_a?(Numeric) ? schema['exclusiveMaximum'] : schema['maximum']
        midpoint = (raw_lower.to_r + raw_upper.to_r) / 2 if raw_lower && raw_upper
        midpoint = type == 'integer' ? midpoint.ceil : midpoint.to_f if midpoint
        [lower, upper, midpoint, 0, 1].compact
      when 'string'
        formats = { 'email' => 'example@example.test', 'date-time' => '2026-01-01T00:00:00Z', 'date' => '2026-01-01',
                    'uuid' => '00000000-0000-4000-8000-000000000001', 'uri' => 'https://example.test/', 'url' => 'https://example.test/' }
        length = [schema.fetch('minLength', 1), 1].max
        length = [length, schema['maxLength']].min if schema['maxLength']
        return [] if length > MAX_STRING
        # Finite witnesses for common identifiers and fixed-point money patterns.
        [formats[schema['format']], 'x' * length, '0' * length, '1' * length, '', '0', '1', '0.00', '1.00', '1000.00',
         'USD', 'RUB', '0123456789', '00000000-0000-4000-8000-000000000001'].compact
      else []
      end
    end
  end
end
