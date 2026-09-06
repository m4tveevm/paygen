# frozen_string_literal: true
require 'json'
require 'yaml'
require 'digest'
require 'fileutils'
require 'pathname'
require_relative 'paygen/version'

module Paygen
  class Error < StandardError
    attr_reader :code, :exit_code, :details
    def initialize(message, code: 'PROJECT_ERROR', exit_code: 2, details: {})
      super(message)
      @code, @exit_code, @details = code, exit_code, details
    end
  end

  def self.deep_merge(left, right)
    left.merge(right) { |_key, old, new| old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new }
  end

  def self.canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  def self.json(value)
    JSON.pretty_generate(canonical(value)) + "\n"
  end
end

require_relative 'paygen/core/input'
require_relative 'paygen/core/overlay'
require_relative 'paygen/core/workflow'
require_relative 'paygen/core/ir'
require_relative 'paygen/core/onboarding'
require_relative 'paygen/project'
require_relative 'paygen/generator'
