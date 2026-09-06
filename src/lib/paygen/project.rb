# frozen_string_literal: true
require 'tempfile'
require 'tmpdir'

module Paygen
  class Project
    DIRECTORIES = %w[source overlays workflows recipes extensions scenarios generated].freeze
    attr_reader :root

    def self.init(input, output:, stdin: $stdin, profile: nil)
      destination = File.expand_path(output)
      raise Error, 'Output already exists; choose an empty project path' if File.exist?(destination)
      raw_document = Core::Input.read(input, stdin: stdin)
      remote = input.to_s == '-' || input.to_s.match?(/\Ahttps?:/i)
      base_dir = remote ? nil : File.dirname(File.realpath(input))
      document = Core::Input.graph(raw_document, base_dir: base_dir, source_path: remote ? nil : input,
                                  source_uri: remote && input.to_s != '-' ? input.to_s : nil)
      project = new(destination, create: true)
      DIRECTORIES.each { |directory| FileUtils.mkdir_p(project.path(directory)) }
      project.write('source/openapi.json', Paygen.json(document))
      recipe = available_recipes.find { |candidate| matches?(candidate, document) }
      # Persist harmless naming defaults, not inferred payment decisions as operator answers.
      defaults = recipe ? recipe.fetch('profile') : Core::IR.new(document).profile.reject { |key, _| %w[operations auth].include?(key) }
      supplied = profile ? Core::Input.read(profile) : {}
      project.write('integration.yml', YAML.dump(Paygen.deep_merge(defaults, supplied)))
      if recipe
        project.write('recipes/selected.yml', YAML.dump(recipe))
        recipe.fetch('overlays', []).each_with_index do |overlay, index|
          project.write(format('overlays/%03d-recipe.yaml', index + 1), YAML.dump(overlay))
        end
        recipe.fetch('workflows', {}).each do |name, workflow|
          raise Error, 'Workflow filename must be a basename' unless name == File.basename(name)
          project.write("workflows/#{name}", YAML.dump(workflow))
        end
      end
      project.write('extensions/README.md', "# User-owned extensions\n\nAdd trusted Ruby hooks here. Paygen never executes or overwrites these files during generation.\n")
      project.write('paygen.lock', Paygen.json({ 'version' => 1, 'source_uri' => remote ? input.to_s : File.expand_path(input), 'source_sha256' => Digest::SHA256.hexdigest(Paygen.json(document)), 'generated' => {} }))
      project
    rescue StandardError
      FileUtils.remove_entry(destination) if defined?(project) && project && File.directory?(destination)
      raise
    end

    def self.available_recipes
      Dir[File.expand_path('../../recipes/*.yml', __dir__)].map { |file| Core::Input.read(file) }
    end

    def self.matches?(recipe, document)
      match = recipe.fetch('match', {})
      operations = Core::IR.new(document).operations.map { |item| item['operation_id'] }
      match['title'] == document.dig('info', 'title') &&
        Array(match['operation_ids']).all? { |id| operations.include?(id) }
    end

    def initialize(root, create: false)
      @root = File.expand_path(root)
      raise Error, 'Project root must not be a symbolic link' if File.symlink?(@root)
      unless create || File.file?(File.join(@root, 'integration.yml'))
        raise Error, 'Not a Paygen project: integration.yml is missing'
      end
    end

    def path(relative)
      candidate = File.expand_path(relative, root)
      unless candidate.start_with?(root + File::SEPARATOR)
        raise Error.new('Path escapes project root', code: 'PATH_DENIED', exit_code: 5)
      end
      current = root
      Pathname.new(candidate).relative_path_from(Pathname.new(root)).each_filename do |part|
        current = File.join(current, part)
        raise Error.new('Symbolic links are not allowed in managed paths', code: 'PATH_DENIED', exit_code: 5) if File.symlink?(current)
      end
      candidate
    end

    def write(relative, contents)
      target = path(relative)
      FileUtils.mkdir_p(File.dirname(target))
      Tempfile.create(['.paygen-', '.tmp'], File.dirname(target)) do |file|
        file.write(contents)
        file.flush
        file.fsync
        File.rename(file.path, target)
      end
    end

    def transaction
      File.open(path('.paygen-write.lock'), File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      ensure
        file&.flock(File::LOCK_UN)
      end
    end

    def replace_generated(files, manifest)
      destination = path('generated')
      files.each_key do |name|
        target = path("generated/#{name}")
        if File.exist?(target) && !File.file?(target)
          raise Error.new('A generated output path is occupied by a directory', code: 'GENERATED_DRIFT', exit_code: 1)
        end
      end
      staging = Dir.mktmpdir('.paygen-staging-', root)
      backup = Dir.mktmpdir('.paygen-backup-', root)
      Dir.rmdir(backup)
      files.each do |name, body|
        target = File.join(staging, name)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, body)
      end
      File.rename(destination, backup) if File.exist?(destination)
      begin
        File.rename(staging, destination)
        write('paygen.lock', Paygen.json(manifest))
      rescue StandardError
        FileUtils.remove_entry(destination) if File.directory?(destination)
        File.rename(backup, destination) if File.directory?(backup)
        raise
      end
    ensure
      FileUtils.remove_entry(staging) if staging && File.directory?(staging)
      FileUtils.remove_entry(backup) if backup && File.directory?(backup)
    end

    def lock
      result = File.file?(path('paygen.lock')) ? Core::Input.read(path('paygen.lock')) : { 'version' => 1, 'generated' => {} }
      unless result['version'] == 1 && result['generated'].is_a?(Hash)
        raise Error.new('Invalid project lock manifest', code: 'INVALID_LOCK', exit_code: 3)
      end
      result['generated'].each do |name, checksum|
        unless name.is_a?(String) && !name.empty? && !name.start_with?('/') &&
               name.split('/').none? { |part| ['.', '..', ''].include?(part) } &&
               !name.match?(/[\\\x00-\x1f]/) && checksum.is_a?(String) && checksum.match?(/\A[0-9a-f]{64}\z/)
          raise Error.new('Unsafe generated-file manifest entry', code: 'INVALID_LOCK', exit_code: 5)
        end
      end
      result
    end

    def profile
      Core::Input.read(path('integration.yml'))
    end

    def effective_document
      document = Core::Input.read(path('source/openapi.json'))
      @overlay_diagnostics = []
      # Brace globs sort each extension group separately; overlay order is global.
      Dir[path('overlays/*.{json,yaml,yml}')].sort.each do |file| # rubocop:disable Lint/RedundantDirGlobSort
        relative = Pathname.new(file).relative_path_from(Pathname.new(root)).to_s
        overlay = Core::Overlay.new(document, source_uri: lock['source_uri'] || path('source/openapi.json'))
        document = overlay.apply(Core::Input.read(path(relative)), overlay_uri: file)
        @overlay_diagnostics.concat(overlay.diagnostics)
      end
      Core::Input.graph(document, source_path: path('source/openapi.json'))
    end

    def ir(overrides: {})
      document = effective_document
      selected = path('recipes/selected.yml')
      defaults = File.file?(selected) ? Core::Input.read(selected).fetch('profile', {}) : {}
      result = Core::IR.new(document, recipe: defaults, profile: profile, overrides: overrides)
      result.diagnostics.concat(@overlay_diagnostics)
      Dir[path('workflows/*.{json,yaml,yml}')].each do |file|
        relative = Pathname.new(file).relative_path_from(Pathname.new(root)).to_s
        Core::Workflow.new(Core::Input.read(path(relative))).validate!
      end
      result
    end

    def input_hashes
      files = %w[source/openapi.json integration.yml] +
              Dir[path('{overlays,recipes,workflows,scenarios}/**/*')].select { |file| File.file?(file) }.map { |file| Pathname.new(file).relative_path_from(Pathname.new(root)).to_s }
      files.sort.to_h { |file| [file, Digest::SHA256.file(path(file)).hexdigest] }
    end

    def generated_drift
      expected = lock.fetch('generated', {})
      differences = expected.filter_map do |relative, checksum|
        file = path("generated/#{relative}")
        next if File.file?(file) && Digest::SHA256.file(file).hexdigest == checksum
        { 'path' => relative, 'reason' => File.exist?(file) ? 'modified' : 'missing' }
      end
      actual = Dir.glob(path('generated/**/*'), File::FNM_DOTMATCH).select do |file|
        relative = Pathname.new(file).relative_path_from(Pathname.new(root)).to_s
        File.file?(path(relative))
      end.map { |file| file.delete_prefix(path('generated') + '/') }
      differences + (actual - expected.keys).map { |file| { 'path' => file, 'reason' => 'untracked' } }
    end

    def update(input)
      document = Core::Input.read(input)
      remote = input.to_s == '-' || input.to_s.match?(/\Ahttps?:/i)
      base_dir = remote ? nil : File.dirname(File.realpath(input))
      document = Core::Input.graph(document, base_dir: base_dir, source_path: remote ? nil : input,
                                   source_uri: remote && input.to_s != '-' ? input.to_s : nil)
      source_uri = remote ? input.to_s : File.expand_path(input)
      source_body = Paygen.json(document)
      source_sha256 = Digest::SHA256.hexdigest(source_body)
      transaction do
        # Validate overlays against the replacement identity before changing either file.
        effective = document
        Dir[path('overlays/*.{json,yml,yaml}')].sort.each do |file| # rubocop:disable Lint/RedundantDirGlobSort
          relative = Pathname.new(file).relative_path_from(Pathname.new(root)).to_s
          effective = Core::Overlay.new(effective, source_uri: source_uri).apply(Core::Input.read(path(relative)), overlay_uri: file)
        end
        Core::Input.graph(effective)
        manifest = lock.merge('source_uri' => source_uri, 'source_sha256' => source_sha256)
        previous_source = File.read(path('source/openapi.json'))
        write('source/openapi.json', source_body)
        begin
          write('paygen.lock', Paygen.json(manifest))
        rescue StandardError
          write('source/openapi.json', previous_source)
          raise
        end
      end
      { 'status' => 'updated', 'source_uri' => source_uri, 'source_sha256' => source_sha256 }
    end
  end
end
