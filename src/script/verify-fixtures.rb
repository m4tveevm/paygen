#!/usr/bin/env ruby
# Sources: fixtures/* provenance.json and original NovaPay provider_api.yaml; offline generated-example gate.
# frozen_string_literal: true

require 'tmpdir'
require_relative '../lib/paygen'
require_relative '../lib/paygen/runtime/adapter'

module Paygen
  module FixtureGate
    DATASETS = {
      'novapay' => ['openapi.yaml', nil, 5, 15],
      'stripe' => ['openapi.yaml', nil, 4, 4],
      'adyen' => ['openapi.yaml', nil, 3, 4],
      'paypal' => ['openapi.yaml', nil, 4, 4],
      'native-paystack' => ['openapi.yaml', 'profile.yml', 2, 5],
      'native-paypal' => ['openapi.json', 'profile.yml', 2, 9],
      'raiffeisen_payouts' => ['upstream/openapi.json', 'integration.yml', 2, 5]
    }.freeze

    def self.run(root: File.expand_path('../..', __dir__))
      report = { 'profiles' => [], 'failures' => [], 'provider_acceptance_verified' => false }
      Dir.mktmpdir('paygen-fixture-gate-') do |directory|
        DATASETS.each do |name, (source, profile, expected_roles, expected_responses)|
          base = File.join(root, 'fixtures', name)
          project = Project.init(File.join(base, source), output: File.join(directory, name), profile: profile && File.join(base, profile))
          files = Generator.new(project).render
          fixtures = JSON.parse(files.fetch('fixtures.json'), decimal_class: BigDecimal)
          config = project.ir.config
          document = project.effective_document
          adapter = Class.new do
            const_set(:PAYGEN_CONFIG, config)
            include Runtime::Adapter
          end.new
          summary = { 'name' => name, 'roles' => fixtures.keys.sort, 'positive' => 0, 'upstream_invalid' => 0,
                      'request_coverage' => [], 'response_coverage' => [], 'exceptions' => [] }
          check = lambda do |condition, message|
            report['failures'] << "#{name}: #{message}" unless condition
          end
          check.call(fixtures.size == expected_roles, "expected #{expected_roles} selected operations")
          validate = lambda do |example, schema, location|
            if example['origin'] == 'openapi-example'
              tokens = example.fetch('source_pointer').split('/').drop(1).map { |token| token.gsub('~1', '/').gsub('~0', '~') }
              source_value = tokens.reduce(document) do |node, token|
                node = Core::Input.dereference(document, node)
                node.is_a?(Hash) ? node[token] : nil
              end
              source_value = source_value['value'] if source_value.is_a?(Hash) && tokens[-2] == 'examples'
              payload = example.key?('value') ? example['value'] : example['payload']
              check.call(payload == source_value, "changed original example #{location}")
            end
            valid = JSONSchemer.schema(adapter.send(:validation_schema, schema)).valid?(example.key?('value') ? example['value'] : example['payload'])
            if example['suitability'] == 'positive'
              summary['positive'] += 1
              check.call(valid, "invalid positive #{location}")
            end
            if example['origin'] == 'openapi-example' && example.dig('schema_validation', 'valid') == false
              summary['upstream_invalid'] += 1
              diagnostics = JSON.parse(files.fetch('diagnostics.json')).fetch('diagnostics')
              check.call(diagnostics.any? { |item| item['code'] == 'FIXTURE_SCHEMA_INVALID' && item['path'] == example['source_pointer'] }, "missing invalid-source diagnostic #{location}")
            end
          end
          config.fetch('endpoints').each do |role, operation|
            entry = fixtures.fetch(role)
            contents = operation.fetch('request_content', {})
            entry.fetch('request_examples').each do |example|
              next unless example.key?('value')
              schema = contents.dig(example['content_type'], 'schema') || operation.fetch('request_schema', {})
              validate.call(example, schema, "#{role}/request/#{example['name']}")
            end
            if entry.key?('request')
              check.call(entry.fetch('request_examples').any? { |example| example['suitability'] == 'positive' && example['value'] == entry['request'] && example['content_type'] == operation.fetch('content_type', 'application/json') }, "request alias does not select a positive #{role} candidate")
            end
            request_schema = operation.fetch('request_schema', {})
            if request_schema.empty?
              summary['exceptions'] << "#{role}/request: no body schema declared; no positive payload claimed"
            else
              check.call(entry.key?('request') && JSONSchemer.schema(adapter.send(:validation_schema, request_schema)).valid?(entry['request']), "missing/invalid #{role} primary request")
              summary['request_coverage'] << role
            end
            operation.fetch('responses', {}).each do |status, response|
              if response.fetch('content', {}).empty?
                summary['exceptions'] << "#{role}/#{status}: no response payload schema declared"
              end
              response.fetch('content', {}).each do |media, content|
                cases = entry.fetch('response_examples').fetch(status).select { |example| example['content_type'] == media }
                schema = content.fetch('schema', {})
                cases.each { |example| validate.call(example, schema, "#{role}/#{status}/#{example['name']}") if example.key?('value') }
                unless Capabilities.json_media?(media)
                  summary['exceptions'] << "#{role}/#{status}/#{media}: outside the selected JSON runtime scope; retained source evidence only"
                  next
                end
                if schema == {}
                  summary['exceptions'] << "#{role}/#{status}/#{media}: no response payload schema declared"
                  next
                end
                positives = cases.select { |example| example['suitability'] == 'positive' }
                check.call(!positives.empty?, "missing #{role}/#{status}/#{media} positive coverage")
                summary['response_coverage'] << "#{role}/#{status}/#{media}"
              end
              supported = entry.fetch('response_examples').fetch(status).select do |example|
                example['suitability'] == 'positive' && Capabilities.json_media?(example['content_type'])
              end
              if entry.key?("response_#{status}") || !supported.empty?
                check.call(supported.any? { |example| example['value'] == entry["response_#{status}"] }, "invalid primary #{role}/#{status}")
              end
            end
            Array(entry['cases']).each do |example|
              validate.call(example, request_schema, "#{role}/callback/#{example['name']}")
              if example['suitability'] == 'positive' && !example['requires_provider_verification']
                check.call(example.dig('adapter_validation', 'success') == true, "non-executable positive callback #{example['name']}")
              end
            end
          end
          check.call(summary['response_coverage'].size == expected_responses, "expected #{expected_responses} response/media schemas")
          check.call(summary['positive'].positive?, 'empty positive example set')
          if name == 'novapay'
            %w[approved rejected].each do |state|
              check.call(fixtures.fetch('callback').fetch('cases').any? { |example| example['suitability'] == 'positive' && example.dig('adapter_validation', 'success') && example['expected_operation_status'] == state }, "missing executable #{state} callback")
            end
          end
          report['profiles'] << summary
        rescue Paygen::Error => error
          report['failures'] << "#{name}: generation failed (#{error.code})"
          report['profiles'] << { 'name' => name, 'status' => 'blocked', 'error_code' => error.code }
        end
      end
      report['status'] = report['failures'].empty? ? 'passed' : 'failed'
      report
    end
  end
end

if $PROGRAM_NAME == __FILE__
  report = Paygen::FixtureGate.run
  puts Paygen.json(report)
  exit(report['failures'].empty? ? 0 : 1)
end
