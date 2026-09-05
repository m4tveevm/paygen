# frozen_string_literal: true
require 'dry/cli'
require_relative '../paygen'

module Paygen
  module CLI
    module Commands
      extend Dry::CLI::Registry

      class Base < Dry::CLI::Command
        def emit(result)
          $stdout.write(Paygen.json(result))
        end

        def parse_sets(values)
          Array(values).each_with_object({}) do |assignment, result|
            key, value = assignment.split('=', 2)
            raise Error, '--set expects KEY=VALUE' unless value && key.match?(/\A[a-zA-Z_][\w.-]*\z/)
            keys = key.split('.')
            leaf = keys.pop
            parent = keys.reduce(result) do |memo, segment|
              memo[segment] ||= {}
              raise Error, 'Conflicting --set paths' unless memo[segment].is_a?(Hash)
              memo[segment]
            end
            parent[leaf] = begin
              JSON.parse(value)
            rescue JSON::ParserError
              value
            end
          end
        end
      end

      class Inspect < Base
        desc 'Inspect an OpenAPI contract and report unresolved integration semantics'
        argument :input, required: true, desc: 'OpenAPI file, HTTPS URL, or - for standard input'
        option :profile, type: :string, desc: 'Read an integration profile from YAML or JSON'
        option :format, default: 'text', values: %w[text json], desc: 'Output format'
        option :strict, type: :boolean, default: false, desc: 'Exit with code 4 when integration decisions remain unresolved'
        def call(input:, profile: nil, format: 'text', strict: false, **)
          document = Core::Input.load(input)
          result = Core::IR.new(document, profile: profile ? Core::Input.read(profile) : {})
          if format == 'json'
            emit(result.to_h)
          else
            puts "#{result.document.dig('info', 'title')} — OpenAPI #{result.document['openapi']}"
            result.operations.each { |op| puts "#{op['method']} #{op['path']} (#{op['operation_id']})" }
            result.diagnostics.each { |d| puts "#{d['severity'].upcase} #{d['code']} #{d['path']}: #{d['message']}" }
          end
          if strict && result.diagnostics.any? { |d| d['severity'] == 'blocker' }
            raise Error.new('Unresolved integration semantics', code: 'SEMANTIC_BLOCKERS', exit_code: 4)
          end
        end
      end

      class Init < Base
        desc 'Create a project with pinned source, profile and user-owned extensions'
        argument :input, required: true, desc: 'OpenAPI file, HTTPS URL, or - for standard input'
        option :output, required: true, desc: 'Write to a new output directory'
        option :profile, type: :string, desc: 'Read an integration profile from YAML or JSON'
        def call(input:, output:, profile: nil, **)
          project = Project.init(input, output: output, profile: profile)
          emit({ 'status' => 'initialized', 'project' => project.root, 'diagnostics' => project.ir.diagnostics })
        end
      end

      class Configure < Base
        desc 'Review operation candidates and apply explicit semantic answers'
        argument :project, required: true, desc: 'Generated project directory'
        option :answers, type: :string, desc: 'Merge answers from a YAML or JSON profile'
        option :set, type: :array, default: [], desc: 'Set dotted KEY=VALUE entries; use JSON for structured values'
        def call(project:, answers: nil, set: [], **)
          project = Project.new(project)
          edits = Paygen.deep_merge(answers ? Core::Input.read(answers) : {}, parse_sets(set))
          unless edits.empty?
            project.transaction do
              # Partial profiles remain editable; malformed shapes are rejected.
              project.ir(overrides: edits)
              project.write('integration.yml', YAML.dump(Paygen.deep_merge(project.profile, edits)))
            end
          end
          emit(Core::Onboarding.new(project.ir).report)
        end
      end

      class Generate < Base
        desc 'Generate service, integration guide, fixtures and provenance'
        argument :project, required: true, desc: 'Generated project directory'
        option :draft, type: :boolean, default: false, desc: 'Write diagnostics even when an executable service cannot be generated'
        option :set, type: :array, default: [], desc: 'Set dotted KEY=VALUE entries; use JSON for structured values'
        option :save_profile, type: :string, desc: 'Save effective profile to a project-relative YAML or JSON file'
        option :watch, type: :boolean, default: false, desc: 'Regenerate when project inputs change'
        def call(project:, draft: false, set: [], save_profile: nil, watch: false, **)
          project = Project.new(project)
          overrides = parse_sets(set)
          generator = Generator.new(project)
          if save_profile
            relative = Pathname.new(File.expand_path(save_profile, project.root)).relative_path_from(Pathname.new(project.root)).to_s
            project.path(relative)
            protected_directory = %w[extensions source generated overlays workflows].include?(relative.split('/').first)
            unless %w[.yml .yaml .json].include?(File.extname(relative)) && !protected_directory
              raise Error.new('Save profiles as YAML or JSON outside source, generated, extensions, overlays and workflows',
                              code: 'PROFILE_PATH_DENIED', exit_code: 5)
            end
            # Validate the effective result and existing generated ownership
            # before touching the profile the caller asked to persist.
            generator.render(draft: draft, overrides: overrides)
            drift = project.generated_drift
            unless drift.empty?
              raise Error.new('Generated files have changed; preserve your edits before saving a profile',
                              code: 'GENERATED_DRIFT', exit_code: 1, details: { 'files' => drift })
            end
            saved = Paygen.deep_merge(project.profile, overrides)
            project.write(relative, File.extname(relative) == '.json' ? Paygen.json(saved) : YAML.dump(saved))
          end
          emit(generator.generate(draft: draft, overrides: overrides))
          return unless watch
          require 'listen'
          listener = Listen.to(project.root, ignore: [%r{(?:^|/)generated/}, %r{(?:^|/)extensions/}, %r{(?:^|/)\.paygen-}, /paygen\.lock$/]) do
            begin
              emit(generator.generate(draft: draft, overrides: overrides))
            rescue Error => e
              warn "#{e.code}: #{e.message}"
            end
          end
          listener.start
          sleep
        ensure
          listener&.stop
        end
      end

      class Diff < Base
        desc 'Report source-driven changes and generated-file drift'
        argument :project, required: true, desc: 'Generated project directory'
        option :check, type: :boolean, default: false, desc: 'Exit with code 1 if generated files differ'
        def call(project:, check: false, **)
          files = Generator.new(project).diff
          emit({ 'changed' => !files.empty?, 'files' => files })
          raise Error.new('Generated output differs', code: 'GENERATED_DRIFT', exit_code: 1) if check && files.any?
        end
      end

      class Update < Base
        desc 'Replace pinned OpenAPI after validating existing overlays'
        argument :project, required: true, desc: 'Generated project directory'
        argument :new_input, required: true, desc: 'Replacement OpenAPI file or HTTPS URL'
        def call(project:, new_input:, **)
          emit(Project.new(project).update(new_input))
        end
      end

      class Explain < Base
        desc 'Show the winning source of a semantic fact'
        argument :project, required: true, desc: 'Generated project directory'
        argument :fact_path, required: true, desc: 'Dotted configuration path, for example amount.scale'
        def call(project:, fact_path:, **)
          facts = Project.new(project).ir.provenance
          selected = facts.select { |path, _| path == fact_path || path.start_with?(fact_path + '.') }
          raise Error, 'Unknown semantic fact path' if selected.empty?
          emit(selected)
        end
      end

      class Patch < Base
        desc 'Append an ordered Overlay 1.1 action'
        argument :project, required: true, desc: 'Generated project directory'
        argument :target, required: true, desc: 'JSONPath selecting the contract nodes to modify'
        option :value, type: :string, desc: 'JSON value for the add or replace action'
        option :from, type: :string, desc: 'Source JSONPath for the copy action'
        option :file, default: 'overlays/999-user.yaml', desc: 'Project-relative overlay file to modify'
        def call(project:, target:, value: nil, from: nil, file: 'overlays/999-user.yaml', **)
          project = Project.new(project)
          file = Pathname.new(project.path(file)).relative_path_from(Pathname.new(project.root)).to_s
          unless File.dirname(file) == 'overlays' && %w[.json .yaml .yml].include?(File.extname(file))
            raise Error, 'Overlay must be a YAML or JSON file directly under overlays/'
          end
          overlay = File.file?(project.path(file)) ? Core::Input.read(project.path(file)) :
            { 'overlay' => '1.1.0', 'info' => { 'title' => 'User contract corrections', 'version' => '1.0.0' }, 'actions' => [] }
          action = { 'target' => target }
          additions = case self.class::ACTION
          when 'remove'
            [action.merge('remove' => true)]
          when 'copy'
            raise Error, '--from is required for copy' unless from
            [action.merge('copy' => from)]
          when 'replace'
            raise Error, '--value must contain a JSON value' unless value
            current = replay(project, file, overlay, stop_after: file)
            replacement_actions(current, target, JSON.parse(value))
          else
            raise Error, '--value must contain a JSON value' unless value
            [action.merge('update' => JSON.parse(value))]
          end
          candidate = Paygen.deep_merge(overlay, 'actions' => overlay.fetch('actions') + additions)
          effective = replay(project, file, candidate)
          Core::Input.graph(effective, base_dir: File.dirname(project.path('source/openapi.json')))
          project.write(file, File.extname(file) == '.json' ? Paygen.json(candidate) : YAML.dump(candidate))
          emit({ 'status' => 'patched', 'file' => file, 'actions' => additions })
        end

        private

        def replay(project, replacement_file, replacement_overlay, stop_after: nil)
          files = Dir[project.path('overlays/*.{json,yaml,yml}')].map do |path|
            Pathname.new(path).relative_path_from(Pathname.new(project.root)).to_s
          end
          document = Core::Input.read(project.path('source/openapi.json'))
          (files + [replacement_file]).uniq.sort.each do |file|
            overlay = file == replacement_file ? replacement_overlay : Core::Input.read(project.path(file))
            unless file == replacement_file && overlay['actions'] == []
              document = Core::Overlay.new(document, source_uri: project.lock['source_uri']).apply(overlay, overlay_uri: project.path(file))
            end
            break if file == stop_after
          end
          document
        end

        def replacement_actions(document, target, value)
          # Ask the same RFC 9535 engine used by Overlay for its normalized
          # location. Restrict replacement to a singular object member so a
          # remove followed by parent update cannot shift array indexes.
          Core::Overlay.new(document).validate!({ 'overlay' => '1.1.0',
            'info' => { 'title' => 'Replacement validation', 'version' => '1' },
            'actions' => [{ 'target' => target, 'remove' => true }] })
          matches = []
          Janeway.enum_for(target, document).each do |_selected, parent, key, path|
            matches << [parent, key, path]
            break if matches.length > 1
          end
          unless matches.one? && matches.first[0].is_a?(Hash)
            raise Error.new('replace requires one existing object member; select the whole array to replace array contents',
                            code: 'PATCH_REPLACE_TARGET', exit_code: 2)
          end
          _parent, key, normalized = matches.first
          parent_path = normalized.sub(/\[(?:'(?:\\.|[^'\\])*'|\d+)\]\z/, '')
          if parent_path == normalized
            raise Error.new('Cannot represent this replacement as ordered Overlay actions', code: 'PATCH_REPLACE_TARGET', exit_code: 2)
          end
          [{ 'target' => normalized, 'remove' => true },
           { 'target' => parent_path, 'update' => { key => value } }]
        end
      end
      class PatchAdd < Patch; ACTION = 'add'; end
      class PatchReplace < Patch; ACTION = 'replace'; end
      class PatchRemove < Patch; ACTION = 'remove'; end
      class PatchCopy < Patch; ACTION = 'copy'; end

      class RecipeList < Base
        desc 'List installed declarative recipes'
        def call(**)
          emit({ 'recipes' => Project.available_recipes.map { |r| r.slice('name', 'match') } })
        end
      end
      class RecipeShow < Base
        desc 'Show an installed recipe'
        argument :name, required: true, desc: 'Installed recipe name'
        def call(name:, **)
          recipe = Project.available_recipes.find { |r| r['name'] == name }
          raise Error, 'Unknown recipe' unless recipe
          emit(recipe)
        end
      end
      class RecipeAdd < Base
        desc 'Select a recipe as project defaults'
        argument :project, required: true, desc: 'Generated project directory'
        argument :name, required: true, desc: 'Installed recipe name'
        def call(project:, name:, **)
          recipe = Project.available_recipes.find { |r| r['name'] == name }
          raise Error, 'Unknown recipe' unless recipe
          project = Project.new(project)
          unless Project.matches?(recipe, project.effective_document)
            raise Error.new('Recipe does not match this API title and operation identifiers', code: 'RECIPE_MISMATCH', exit_code: 4)
          end
          project.write('recipes/selected.yml', YAML.dump(recipe))
          emit({ 'status' => 'selected', 'name' => name, 'note' => 'Explicit integration.yml values retain precedence' })
        end
      end
      class RecipeRemove < Base
        desc 'Remove selected recipe defaults'
        argument :project, required: true, desc: 'Generated project directory'
        def call(project:, **)
          project = Project.new(project)
          file = project.path('recipes/selected.yml')
          File.delete(file) if File.file?(file)
          emit({ 'status' => 'removed' })
        end
      end

      class Export < Base
        desc 'Export a detached, user-owned integration with runtime source'
        argument :project, required: true, desc: 'Generated project directory'
        option :standalone, type: :boolean, default: false, desc: 'Include runtime source in a detached integration'
        option :output, required: true, desc: 'Write to a new output directory'
        def call(project:, output:, standalone: false, **)
          raise Error, 'Use --standalone to acknowledge detached regeneration semantics' unless standalone
          emit(Generator.new(project).export(output: output))
        end
      end

      class Docs < Base
        desc 'Export portable integration documentation and examples'
        argument :project, required: true, desc: 'Generated project directory'
        option :format, default: 'html', values: %w[md html], desc: 'Output format'
        option :output, required: true, desc: 'Write to a new output directory'
        def call(project:, output:, format: 'html', **)
          emit(Generator.new(project).docs(format: format, output: output))
        end
      end

      class Collection < Base
        desc 'Export a Bruno collection for the local generated-adapter demo'
        argument :project, required: true, desc: 'Generated project directory'
        option :format, default: 'bruno', values: %w[bruno], desc: 'Output format'
        option :output, required: true, desc: 'Write to a new output directory'
        def call(project:, output:, format: 'bruno', **)
          require_relative 'collection'
          emit(Paygen::Collection.new(project).export(output: output, format: format))
        end
      end

      class ArchitectureCheck < Base
        desc 'Check semantic consistency, input hashes and generated ownership'
        argument :project, required: true, desc: 'Generated project directory'
        def call(project:, **)
          project = Project.new(project)
          diagnostics = project.ir.diagnostics
          drift = Generator.new(project).diff
          emit({ 'diagnostics' => diagnostics, 'generated_drift' => drift })
          raise Error.new('Architecture check failed', code: 'CHECK_FAILED', exit_code: 1) if diagnostics.any? { |d| d['severity'] == 'blocker' } || drift.any?
        end
      end

      class Doctor < Base
        desc 'Print runtime and dependency diagnostics'
        def call(**)
          gems = %w[dry-cli json_schemer janeway-jsonpath rack puma prop_check listen diff-lcs]
          versions = gems.to_h { |name| [name, Gem.loaded_specs[name]&.version&.to_s || Gem::Specification.find_all_by_name(name).first&.version&.to_s] }
          emit({ 'paygen' => VERSION, 'ruby' => RUBY_VERSION, 'gems' => versions })
          raise Error.new('Missing required gems', code: 'DEPENDENCY_MISSING', exit_code: 2) if versions.values.any?(&:nil?)
        end
      end

      class Serve < Base
        desc 'Run a deterministic local provider simulator'
        argument :project, required: true, desc: 'Generated project directory'
        option :scenario, default: 'success', desc: 'Provider simulator scenario, such as success or timeout_after_commit'
        option :seed, default: '0', desc: 'Seed for reproducible simulation'
        option :port, default: '9292', desc: 'Loopback HTTP port'
        def call(project:, scenario: 'success', seed: '0', port: '9292', **)
          require 'puma'
          require_relative 'runtime/simulator'
          config = Project.new(project).ir.config
          app = Runtime::Simulator.new(config: config, scenario: scenario, seed: Integer(seed), strict_auth: true)
          server = Puma::Server.new(app)
          server.add_tcp_listener('127.0.0.1', Integer(port))
          warn "Paygen simulator listening on http://127.0.0.1:#{Integer(port)}"
          trap('INT') { server.stop }
          trap('TERM') { server.stop }
          server.run.join
        end
      end

      class Demo < Base
        desc 'Run a local application that invokes the generated adapter and verifies callbacks'
        argument :project, required: true, desc: 'Generated project directory'
        option :scenario, default: 'success', desc: 'Provider simulator scenario, such as success or timeout_after_commit'
        option :seed, default: '0', desc: 'Seed for reproducible simulation'
        option :port, default: '9293', desc: 'Loopback HTTP port'
        def call(project:, scenario: 'success', seed: '0', port: '9293', **)
          require 'puma'
          require_relative 'runtime/demo'
          project = Project.new(project)
          generator = Generator.new(project)
          raise Error.new('Regenerate before starting the demo', code: 'GENERATED_DRIFT', exit_code: 1) unless generator.diff.empty?
          rendered = generator.render(draft: project.lock.fetch('draft', false), overrides: project.lock.fetch('overrides', {}))
          config = JSON.parse(rendered.fetch('config.json'))
          source = rendered["#{config.fetch('provider')}_service.rb"]
          raise Error.new('Resolve semantic blockers before starting the demo', code: 'SEMANTIC_BLOCKERS', exit_code: 4) unless source
          app = Runtime::Demo.new(source: source, config: config, scenario: scenario, seed: Integer(seed))
          server = Puma::Server.new(app)
          server.add_tcp_listener('127.0.0.1', Integer(port))
          warn "Paygen adapter demo listening on http://127.0.0.1:#{Integer(port)}"
          trap('INT') { server.stop }
          trap('TERM') { server.stop }
          server.run.join
        end
      end

      class Verify < Base
        desc 'Verify an adapter with deterministic offline faults or local HTTP smoke'
        argument :project, required: true, desc: 'Generated project directory'
        option :target, type: :string, desc: 'Existing loopback provider simulator URL'
        option :scenario_pack, default: 'default', desc: 'Verifier scenario pack'
        option :seed, default: '0', desc: 'Seed for reproducible simulation'
        def call(project:, target: nil, scenario_pack: 'default', seed: '0', **)
          require_relative 'runtime/adapter'
          require_relative 'runtime/verifier'
          require_relative 'runtime/reference_provider'
          project = Project.new(project)
          generator = Generator.new(project)
          drift = generator.diff
          unless drift.empty?
            raise Error.new('Generate the current integration before verifying it', code: 'GENERATED_DRIFT', exit_code: 1,
                            details: { 'files' => drift })
          end
          expected = generator.render(draft: project.lock.fetch('draft', false), overrides: project.lock.fetch('overrides', {}))
          config = JSON.parse(expected.fetch('config.json'))
          service_file = "#{config.fetch('provider')}_service.rb"
          unless expected.key?(service_file)
            raise Error.new('A diagnostic-only draft has no adapter to verify', code: 'SEMANTIC_BLOCKERS', exit_code: 4)
          end
          source = File.binread(project.path("generated/#{service_file}"))
          unless source == expected.fetch(service_file).b
            raise Error.new('Generated adapter bytes differ from the trusted render', code: 'GENERATED_DRIFT', exit_code: 1)
          end
          service = Runtime::ReferenceProvider.load_service(source: source, class_name: config.fetch('class_name'))
          report = Runtime::Verifier.new(adapter: service.new, seed: Integer(seed), target: target).run(scenario_pack: scenario_pack)
          emit(report)
          raise Error.new('Adapter verification failed', code: 'VERIFICATION_FAILED', exit_code: 1) unless report['success']
        end
      end

      class Fuzz < Base
        desc 'Check generated payment sequences and replay reduced failures offline'
        argument :project, required: true, desc: 'Generated project directory'
        option :seed, default: '0', desc: 'Seed for reproducible payment sequences'
        option :cases, default: '100', desc: 'Number of independent sequences'
        option :steps, default: '30', desc: 'Maximum actions per generated sequence'
        option :replay, type: :string, desc: 'Replay a saved report or trace instead of generating sequences'
        option :output, type: :string, desc: 'Save the JSON report to a new file outside the project'
        def call(project:, seed: '0', cases: '100', steps: '30', replay: nil, output: nil, **)
          require_relative 'runtime/state_fuzzer'
          require_relative 'runtime/reference_provider'
          project = Project.new(project)
          generator = Generator.new(project)
          raise Error.new('Generate the current integration before fuzzing', code: 'GENERATED_DRIFT', exit_code: 1) unless generator.diff.empty?
          files = generator.render(draft: project.lock.fetch('draft', false), overrides: project.lock.fetch('overrides', {}))
          config = JSON.parse(files.fetch('config.json'))
          source = files["#{config.fetch('provider')}_service.rb"]
          raise Error.new('A diagnostic-only draft has no adapter to test', code: 'SEMANTIC_BLOCKERS', exit_code: 4) unless source
          destination = File.expand_path(output) if output
          if destination && (destination == project.root || destination.start_with?(project.root + '/'))
            raise Error, 'Save the report outside the generated project'
          end
          raise Error, 'Report output already exists' if destination && (File.exist?(destination) || File.symlink?(destination))
          raise Error, 'Report output directory does not exist' if destination && !File.directory?(File.dirname(destination))
          service = Runtime::ReferenceProvider.load_service(source: source, class_name: config.fetch('class_name'))
          fuzzer = Runtime::StateFuzzer.new(adapter: service.new, seed: Integer(seed))
          report = replay ? fuzzer.replay(Core::Input.read(replay)) : fuzzer.run(cases: Integer(cases), steps: Integer(steps))
          File.open(destination, 'wx') { |file| file.write(Paygen.json(report)) } if destination
          emit(report)
          raise Error.new('Payment sequence verification failed', code: 'FUZZ_FAILED', exit_code: 1) unless report['success']
        end
      end

      register 'inspect', Inspect
      register 'init', Init
      register 'configure', Configure
      register 'generate', Generate
      register 'diff', Diff
      register 'update', Update
      register 'explain', Explain
      register 'patch add', PatchAdd
      register 'patch replace', PatchReplace
      register 'patch remove', PatchRemove
      register 'patch copy', PatchCopy
      register 'recipe list', RecipeList
      register 'recipe show', RecipeShow
      register 'recipe add', RecipeAdd
      register 'recipe remove', RecipeRemove
      register 'export', Export
      register 'docs', Docs
      register 'collection', Collection
      register 'architecture-check', ArchitectureCheck
      register 'doctor', Doctor
      register 'serve', Serve
      register 'demo', Demo
      register 'verify', Verify
      register 'fuzz', Fuzz
    end

    def self.run(argv = ARGV)
      help = argv == ['--help'] || argv == ['-h']
      Dry::CLI.new(Commands).call(arguments: help ? [] : argv, err: help ? $stdout : $stderr)
      0
    rescue SystemExit => e
      help || e.success? ? 0 : 2
    rescue Paygen::Error => e
      warn Paygen.json({ 'error' => { 'code' => e.code, 'message' => e.message, 'details' => e.details } })
      e.exit_code
    rescue JSON::ParserError, ArgumentError => e
      warn Paygen.json({ 'error' => { 'code' => 'INVALID_ARGUMENT', 'message' => e.message } })
      2
    rescue Interrupt
      130
    rescue StandardError => e
      warn Paygen.json({ 'error' => { 'code' => 'INTERNAL_ERROR', 'message' => 'Unexpected internal error', 'type' => e.class.name } })
      70
    end
  end
end
