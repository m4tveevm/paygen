# frozen_string_literal: true

require 'bigdecimal'
require 'json'

module Paygen
  module Runtime
    # Store results as an opaque, JSON-safe value without changing the public
    # Ruby scalar types. Decimal paths are out-of-band, so provider strings or
    # objects resembling a type marker cannot be mistaken for a BigDecimal.
    module ResultCodec
      module_function

      def dump(result)
        decimals = []
        encoded = encode(result, [], decimals)
        JSON.generate('result' => encoded, 'decimal_paths' => decimals)
      end

      def load(stored)
        return deep_copy(stored) unless stored.is_a?(String)

        envelope = JSON.parse(stored)
        result = envelope.fetch('result')
        envelope.fetch('decimal_paths').each do |path|
          parent = path[0...-1].reduce(result) { |value, key| value.fetch(key) }
          parent[path.last] = BigDecimal(parent.fetch(path.last))
        end
        result
      end

      def encode(value, path, decimals)
        case value
        when BigDecimal
          raise ArgumentError, 'result decimal must be finite' unless value.finite?

          decimals << path
          value.to_s('F')
        when Hash then value.to_h { |key, child| [key, encode(child, path + [key], decimals)] }
        when Array then value.each_with_index.map { |child, index| encode(child, path + [index], decimals) }
        else value
        end
      end

      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, child| [key, deep_copy(child)] }
        when Array then value.map { |child| deep_copy(child) }
        when String then value.dup
        else value
        end
      end
    end
  end
end
