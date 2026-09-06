#!/usr/bin/env ruby
# frozen_string_literal: true
require 'json'
require 'yaml'
require 'digest'
require 'ripper'

root = File.expand_path('..', __dir__)
failures = []
Dir[File.join(root, 'src/lib/paygen/core/**/*.rb')].each do |file|
  failures << "provider-specific core: #{file}" if File.read(file).match?(/novapay|paypal|stripe|adyen/i)
end
Dir[File.join(root, '{src/lib,spec}/**/*.rb')].each do |file|
  code = File.read(file)
  failures << "unfinished mandatory code: #{file}" if code.match?(/TODO|NotImplementedError/)
  Ripper.lex(code).each do |_position, type, token, _state|
    if type == :on_ident && %w[skip pending xit xdescribe xcontext].include?(token)
      failures << "disabled test: #{file}"
    end
  end
end
Dir[File.join(root, '.github/workflows/*.yml')].each { |file| YAML.safe_load_file(file, aliases: false) }
Dir[File.join(root, 'fixtures/*/provenance.json')].each do |file|
  data = JSON.parse(File.read(file))
  data.fetch('files_sha256').each do |relative, hash|
    failures << "provenance mismatch: #{file}:#{relative}" unless Digest::SHA256.file(File.join(File.dirname(file), relative)).hexdigest == hash
  end
end
abort failures.join("\n") unless failures.empty?
puts JSON.generate(status: 'PASS', checks: %w[provider_neutral_core no_unfinished_paths no_disabled_tests workflow_yaml provenance])
