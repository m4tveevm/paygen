#!/usr/bin/env ruby
# Sources: fixtures/* provenance.json and provider_api.yaml (organizer original);
# JSONSchemer 2.5.0 OpenAPI native dialect/ref API from the installed open-source gem.
# Independent schema validation: never calls Runtime::Adapter#validation_schema.

require_relative '../lib/paygen'
require 'json_schemer'
require 'tmpdir'
require 'bigdecimal'

Dir.chdir(File.expand_path('../..', __dir__))
inputs = {
  'novapay' => ['fixtures/novapay/openapi.yaml', nil],
  'stripe' => ['fixtures/stripe/openapi.yaml', nil],
  'adyen' => ['fixtures/adyen/openapi.yaml', nil],
  'paypal' => ['fixtures/paypal/openapi.yaml', nil],
  'native-paystack' => ['fixtures/native-paystack/openapi.yaml', 'fixtures/native-paystack/profile.yml'],
  'native-paypal' => ['fixtures/native-paypal/openapi.json', 'fixtures/native-paypal/profile.yml'],
  'raiffeisen' => ['fixtures/raiffeisen_payouts/upstream/openapi.json', 'fixtures/raiffeisen_payouts/integration.yml']
}
report = {
  'oracle' => 'JSONSchemer OpenAPI native dialect .ref; no adapter validation_schema conversion',
  'profiles' => [],
  'failures' => []
}
escape = ->(value) { value.gsub('~', '~0').gsub('/', '~1') }

Dir.mktmpdir do |root|
  inputs.each do |name, (source, profile)|
    project = Paygen::Project.init(source, profile: profile, output: File.join(root, name))
    files = Paygen::Generator.new(project).render
    fixtures = JSON.parse(files.fetch('fixtures.json'), decimal_class: BigDecimal)
    ir = project.ir
    oracle = JSONSchemer.openapi(ir.document)

    # Follow intermediate OpenAPI references to locate the original schema.
    # Validation itself uses the native OpenAPI dialect, not runtime conversion.
    validator = lambda do |pointer|
      tokens = pointer.split('/').drop(1)
      node = ir.document
      actual = []
      tokens.each do |token|
        50.times do
          break unless node.is_a?(Hash) && node['$ref']

          actual = node.fetch('$ref').delete_prefix('#').split('/').drop(1)
          node = actual.reduce(ir.document) do |value, key|
            value.fetch(key.gsub('~1', '/').gsub('~0', '~'))
          end
        end
        node = node.fetch(token.gsub('~1', '/').gsub('~0', '~'))
        actual << token
      end
      oracle.ref('#' + URI::DEFAULT_PARSER.escape('/' + actual.join('/')))
    end

    summary = { 'name' => name, 'positive' => 0, 'primary' => 0, 'invalid_positive' => 0, 'source_invalid' => 0 }
    ir.config.fetch('endpoints').each do |role, operation|
      entry = fixtures.fetch(role)
      pointer = operation.fetch('source_pointer')
      validate = lambda do |item, location, value|
        valid = validator.call(location).valid?(value)
        if item['suitability'] == 'positive'
          summary['positive'] += 1
          unless valid
            summary['invalid_positive'] += 1
            report['failures'] << "#{name} #{role} invalid positive #{location}"
          end
        elsif item['origin'] == 'openapi-example' && !valid
          summary['source_invalid'] += 1
        end
        valid
      end

      entry.fetch('request_examples').each do |item|
        next unless item['schema_validation']['checked']

        location = pointer + '/requestBody/content/' + escape.call(item.fetch('content_type')) + '/schema'
        validate.call(item, location, item['value'])
      end
      if entry.key?('request')
        summary['primary'] += 1
        location = pointer + '/requestBody/content/' + escape.call(operation['content_type']) + '/schema'
        unless validator.call(location).valid?(entry['request'])
          report['failures'] << "#{name} #{role} invalid primary request"
        end
      end

      entry.fetch('response_examples').each do |status, items|
        items.each do |item|
          next unless item['schema_validation']['checked']

          location = pointer + '/responses/' + escape.call(status) + '/content/' +
                     escape.call(item['content_type']) + '/schema'
          validate.call(item, location, item['value'])
        end
        next unless entry.key?('response_' + status)

        summary['primary'] += 1
        media = items.find do |item|
          item['suitability'] == 'positive' && item['value'] == entry['response_' + status]
        end&.fetch('content_type')
        location = pointer + '/responses/' + escape.call(status) + '/content/' + escape.call(media.to_s) + '/schema'
        unless media && validator.call(location).valid?(entry['response_' + status])
          report['failures'] << "#{name} #{role}/#{status} invalid primary"
        end
      end
      Array(entry['cases']).each do |item|
        location = pointer + '/requestBody/content/' + escape.call(operation['content_type']) + '/schema'
        validate.call(item, location, item['payload'])
      end
    end
    report['profiles'] << summary
  end
end

puts JSON.pretty_generate(report)
exit(report['failures'].empty? ? 0 : 1)
