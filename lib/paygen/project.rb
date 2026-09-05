# frozen_string_literal: true
require 'tempfile'

module Paygen
  class Project
    DIRECTORIES = %w[source overlays workflows recipes extensions scenarios generated].freeze
    attr_reader :root

    def self.init(input, output:, stdin: $stdin)
      destination = File.expand_path(output)
      raise Error, 'Output already exists; choose an empty project path' if File.exist?(destination)
      document = Core::Input.load(input, stdin: stdin)
      project = new(destination, create: true)
      DIRECTORIES.each { |directory| FileUtils.mkdir_p(project.path(directory)) }
      project.write('source/openapi.json', Paygen.json(document))
      recipe = available_recipes.find { |candidate| matches?(candidate, document) }
      profile = recipe ? recipe.fetch('profile') : Core::IR.new(document).profile
      project.write('integration.yml', YAML.dump(profile))
      if recipe
        project.write('recipes/selected.yml', YAML.dump(recipe))
        recipe.fetch('overlays', []).each_with_index do |overlay, index|
          project.write(format('overlays/%03d-recipe.yaml', index + 1), YAML.dump(overlay))
        end
      end
      project.write('extensions/README.md', "# User-owned extensions\n\nAdd trusted Ruby hooks here. Paygen never executes or overwrites these files during generation.\n")
      project.write('paygen.lock', Paygen.json({ 'version' => 1, 'source_sha256' => Digest::SHA256.hexdigest(Paygen.json(document)), 'generated' => {} }))
      project
    rescue StandardError
      FileUtils.remove_entry(destination) if defined?(project) && project && File.directory?(destination)
      raise
    end

    def self.available_recipes
      Dir[File.expand_path('../../recipes/*.yml', __dir__)].sort.map { |file| Core::Input.read(file) }
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

    def lock
      File.file?(path('paygen.lock')) ? Core::Input.read(path('paygen.lock')) : { 'version' => 1, 'generated' => {} }
    end

    def profile
      Core::Input.read(path('integration.yml'))
    end

    def effective_document
      document = Core::Input.load(path('source/openapi.json'))
      @overlay_diagnostics = []
      Dir[path('overlays/*.{json,yaml,yml}')].sort.each do |file|
        relative = Pathname.new(file).relative_path_from(Pathname.new(root)).to_s
        overlay = Core::Overlay.new(document, source_uri: path('source/openapi.json'))
        document = overlay.apply(Core::Input.read(path(relative)), overlay_uri: file)
        @overlay_diagnostics.concat(overlay.diagnostics)
      end
      Core::Input.validate!(document)
      document
    end

    def ir(overrides: {})
      document = effective_document
      selected = path('recipes/selected.yml')
      defaults = File.file?(selected) ? Core::Input.read(selected).fetch('profile', {}) : {}
      result = Core::IR.new(document, recipe: defaults, profile: profile, overrides: overrides)
      result.diagnostics.concat(@overlay_diagnostics)
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
      actual = Dir[path('generated/**/*')].select { |file| File.file?(file) }.map { |file| file.delete_prefix(path('generated') + '/') }
      differences + (actual - expected.keys).map { |file| { 'path' => file, 'reason' => 'untracked' } }
    end

    def update(input)
      document = Core::Input.load(input)
      # Validate overlays against the replacement before making any change.
      effective = document
      Dir[path('overlays/*.{json,yml,yaml}')].sort.each do |file|
        effective = Core::Overlay.new(effective).apply(Core::Input.read(file))
      end
      Core::Input.validate!(effective)
      write('source/openapi.json', Paygen.json(document))
      { 'status' => 'updated', 'source_sha256' => Digest::SHA256.hexdigest(Paygen.json(document)) }
    end
  end
end
