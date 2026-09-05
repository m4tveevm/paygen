# frozen_string_literal: true
require 'open3'
require 'rbconfig'
require 'cgi'
require 'bigdecimal'
require_relative 'documentation'

module Paygen
  class Generator
    attr_reader :project
    def initialize(project)
      @project = project.is_a?(Project) ? project : Project.new(project)
    end

    def render(draft: false, overrides: {})
      ir = project.ir(overrides: overrides)
      algorithm = ir.profile.dig('callback', 'signature', 'algorithm')
      if algorithm && !%w[hmac-sha256 stripe-v1 provider_verification].include?(algorithm)
        ir.diagnostics << { 'code' => 'SIGNATURE_UNSUPPORTED', 'severity' => 'blocker',
                            'message' => 'Unsupported callback verification algorithm', 'path' => 'callback.signature.algorithm' }
      end
      blockers = ir.diagnostics.select { |item| item['severity'] == 'blocker' }
      if blockers.any? && !draft
        raise Error.new('Resolve semantic blockers before generation', code: 'SEMANTIC_BLOCKERS', exit_code: 4,
                        details: { 'diagnostics' => blockers })
      end
      config = ir.config
      config['draft'] = true if draft && blockers.any?
      files = {
        'config.json' => Paygen.json(config),
        'INTEGRATION.md' => guide(ir),
        'fixtures.json' => Paygen.json(exact_json_numbers(fixtures(ir))),
        'effective-openapi.json' => Paygen.json(ir.document),
        'provenance.json' => Paygen.json(ir.provenance),
        'diagnostics.json' => Paygen.json({ 'diagnostics' => ir.diagnostics })
      }
      if blockers.empty?
        files["#{ir.profile.fetch('provider')}_service.rb"] = service(config)
      end
      files
    end

    def generate(draft: false, overrides: {})
      project.transaction { generate_locked(draft: draft, overrides: overrides) }
    end

    def generate_locked(draft: false, overrides: {})
      drift = project.generated_drift
      unless drift.empty?
        raise Error.new('Generated files have changed; preserve your edits before regenerating', code: 'GENERATED_DRIFT', exit_code: 1, details: { 'files' => drift })
      end
      inputs_before = project.input_hashes
      files = render(draft: draft, overrides: overrides)
      files.each do |name, body|
        next unless name.end_with?('.rb')
        _out, _err, status = Open3.capture3(RbConfig.ruby, '-c', stdin_data: body)
        raise Error.new('Generated Ruby failed syntax validation', code: 'GENERATOR_ERROR', exit_code: 70) unless status.success?
      end
      if project.input_hashes != inputs_before
        raise Error.new('Project inputs changed during generation; retry', code: 'INPUT_CHANGED', exit_code: 1)
      end
      lock = { 'version' => 1, 'paygen_version' => VERSION, 'source_uri' => project.lock['source_uri'],
               'source_sha256' => inputs_before.fetch('source/openapi.json'), 'inputs' => inputs_before,
               'generated' => files.to_h { |name, body| [name, Digest::SHA256.hexdigest(body)] },
               'overrides' => overrides, 'draft' => draft }
      project.replace_generated(files, lock)
      { 'status' => 'generated', 'files' => files.keys.sort, 'draft' => draft }
    end

    def diff
      expected = render(draft: project.lock.fetch('draft', false), overrides: project.lock.fetch('overrides', {}))
      tracked = project.lock.fetch('generated', {})
      changes = (expected.keys | tracked.keys).sort.filter_map do |name|
        target = project.path("generated/#{name}")
        current = File.file?(target) ? File.read(target) : nil
        next if current == expected[name]
        { 'path' => name, 'change' => current.nil? ? 'add' : (expected[name].nil? ? 'remove' : 'change') }
      end + project.generated_drift.select { |item| item['reason'] == 'untracked' }
      previous_inputs = project.lock.fetch('inputs', {})
      current_inputs = project.input_hashes
      (previous_inputs.keys | current_inputs.keys).sort.each do |name|
        changes << { 'path' => name, 'change' => 'input_changed' } if previous_inputs[name] != current_inputs[name]
      end
      changes
    end

    def export(output:)
      changes = diff
      raise Error.new('Regenerate before exporting', code: 'GENERATED_DRIFT', exit_code: 1) unless changes.empty?
      destination = File.expand_path(output)
      raise Error, 'Export destination already exists' if File.exist?(destination)
      raise Error, 'Export destination cannot be inside the project' if destination.start_with?(project.root + '/')
      FileUtils.mkdir_p(destination)
      Dir[project.path('generated/**/*')].each do |file|
        relative = Pathname.new(file).relative_path_from(Pathname.new(project.path('generated'))).to_s
        verified = project.path("generated/#{relative}")
        next unless File.file?(verified)
        target = File.join(destination, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(verified, target)
      end
      runtime_source = File.expand_path('runtime', __dir__)
      FileUtils.mkdir_p(File.join(destination, 'lib/paygen'))
      FileUtils.cp_r(runtime_source, File.join(destination, 'lib/paygen/runtime'))
      Dir.glob(project.path('extensions/**/*'), File::FNM_DOTMATCH).each do |file|
        relative = Pathname.new(file).relative_path_from(Pathname.new(project.root)).to_s
        verified = project.path(relative)
        next unless File.file?(verified)
        target = File.join(destination, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(verified, target)
      end
      File.write(File.join(destination, 'Gemfile'), "source 'https://rubygems.org'\ngem 'json', '~> 2.21'\ngem 'json_schemer', '~> 2.4'\ngem 'bigdecimal', '>= 3.1'\ngem 'base64', '~> 0.2'\ngem 'rack', '~> 3.1'\n")
      File.write(File.join(destination, 'DETACHED.md'), "# Detached integration\n\nThis export is user-owned and is not safely regenerable. Install dependencies with bundle install. Add this directory's lib to RUBYLIB and load your Provider::BaseService before the service. Review credentials and hook contract in INTEGRATION.md.\n")
      { 'status' => 'exported', 'path' => destination, 'detached' => true }
    end

    # Publishing is a separate application decision. This produces a portable,
    # local documentation bundle from precisely the checked generated bytes.
    def docs(format:, output:)
      unless %w[md html].include?(format)
        raise Error.new('Documentation format must be md or html', code: 'DOCS_FORMAT', exit_code: 2)
      end
      raise Error.new('Regenerate before exporting documentation', code: 'GENERATED_DRIFT', exit_code: 1) unless diff.empty?
      destination = File.expand_path(output)
      raise Error, 'Documentation destination already exists' if File.exist?(destination)
      if destination == project.root || destination.start_with?(project.root + '/')
        raise Error, 'Documentation destination cannot be inside the project'
      end
      files = %w[INTEGRATION.md effective-openapi.json fixtures.json config.json provenance.json diagnostics.json].to_h do |name|
        [name, File.read(project.path("generated/#{name}"))]
      end
      files['index.html'] = Documentation.html(files.fetch('INTEGRATION.md')) if format == 'html'
      FileUtils.mkdir_p(destination)
      files.each { |name, body| File.write(File.join(destination, name), body) }
      { 'status' => 'documented', 'format' => format, 'path' => destination, 'files' => files.keys.sort }
    end

    private

    def exact_json_numbers(value)
      case value
      when Hash then value.transform_values { |child| exact_json_numbers(child) }
      when Array then value.map { |child| exact_json_numbers(child) }
      when BigDecimal then JSON::Fragment.new(value.to_s('F'))
      else value
      end
    end

    def service(config)
      <<~RUBY
        # frozen_string_literal: true
        # Generated by Paygen #{VERSION}. Change integration.yml or extensions, then regenerate.
        require 'json'
        require 'paygen/runtime/adapter'
        class Provider::#{config.fetch('class_name')} < Provider::BaseService
          PAYGEN_CONFIG = JSON.parse(#{JSON.generate(config).dump}).freeze
          include Paygen::Runtime::Adapter
        end
      RUBY
    end

    def guide(ir)
      Documentation.new(ir, example_builder: method(:schema_example)).markdown
    end

    def fixtures(ir)
      Documentation.new(ir, example_builder: method(:schema_example)).fixtures
    end

    def schema_example(schema, depth = 0)
      return nil if depth > 16
      return nil unless schema.is_a?(Hash)
      if schema['allOf']
        return schema['allOf'].reduce({}) do |memo, child|
          example = schema_example(child, depth + 1)
          example.is_a?(Hash) ? Paygen.deep_merge(memo, example) : memo
        end
      end
      return schema_example((schema['oneOf'] || schema['anyOf']).first, depth + 1) if schema['oneOf'] || schema['anyOf']
      return schema['example'] if schema.key?('example')
      return schema['default'] if schema.key?('default')
      return schema['enum'].first if schema['enum'].is_a?(Array)
      if schema['properties']
        schema['properties'].to_h { |key, value| [key, schema_example(value, depth + 1)] }.compact
      elsif schema['type'] == 'array'
        count = [schema.fetch('minItems', 1), 1].max
        Array.new([count, 100].min) { schema_example(schema.fetch('items', {}), depth + 1) }
      elsif schema['type'] == 'boolean'
        false
      elsif %w[number integer].include?(schema['type'])
        schema.fetch('minimum', 0)
      elsif schema['type'] == 'string'
        return 'example@example.test' if schema['format'] == 'email'
        return '2026-01-01T00:00:00Z' if schema['format'] == 'date-time'
        return '00000000-0000-4000-8000-000000000001' if schema['format'] == 'uuid'
        return 'https://example.test/' if %w[uri url].include?(schema['format'])
        length = [schema.fetch('minLength', 1), 1].max
        length = [length, schema['maxLength']].min if schema['maxLength']
        'x' * [length, 10000].min
      end
    end

    def cell(value)
      CGI.escapeHTML(value.to_s).gsub('|', '\\|').gsub('`', '\\`').gsub(/[\r\n]/, ' ')
    end
  end
end
