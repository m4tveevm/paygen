# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../lib/paygen'

module DocsProviderAssets
  FILES = %w[INTEGRATION.md fixtures.json config.json diagnostics.json provenance.json].freeze
  ROOT = File.expand_path('..', __dir__)

  def self.source_sha
    supplied = ENV['PAYGEN_SOURCE_SHA']
    if File.exist?(File.join(ROOT, '.git'))
      revision, status = Open3.capture2('git', 'rev-parse', 'HEAD', chdir: ROOT)
      raise 'Cannot determine source revision' unless status.success?

      revision = revision.strip
      raise 'PAYGEN_SOURCE_SHA does not match checkout' if supplied && supplied != revision
    end
    revision = supplied || revision
    raise 'PAYGEN_SOURCE_SHA must be a full commit SHA (required in a source archive)' unless revision&.match?(/\A[0-9a-f]{40}\z/)

    revision
  end

  def self.build(output)
    revision = source_sha
    output = File.expand_path(output)
    raise 'Render documentation first; output must be a real directory' unless File.directory?(output) && !File.symlink?(output)

    downloads_root = File.join(output, 'downloads')
    raise 'Refusing a symbolic-link downloads directory' if File.symlink?(downloads_root)

    downloads = File.join(downloads_root, 'novapay')
    version_file = File.join(output, 'version.json')
    [downloads, version_file].each do |target|
      raise 'Provider publication output already exists; run a clean docs build' if File.exist?(target) || File.symlink?(target)
    end
    source = File.join(ROOT, 'fixtures/novapay/openapi.yaml')
    profile = File.join(ROOT, 'fixtures/novapay/integration.yml')
    Dir.mktmpdir('paygen-docs-provider-') do |directory|
      project = Paygen::Project.init(source, output: File.join(directory, 'novapay'), profile: profile)
      Paygen::Generator.new(project).generate
      # Copy only known generated outputs, never the project, environment or state.
      FileUtils.mkdir_p(downloads)
      FILES.each { |name| FileUtils.cp(project.path("generated/#{name}"), File.join(downloads, name)) }
      manifest = {
        'schema_version' => 2,
        'source_code_sha' => revision,
        'generator_version' => Paygen::VERSION,
        'provider' => 'novapay',
        'source_path' => 'fixtures/novapay/openapi.yaml',
        'profile_path' => 'fixtures/novapay/integration.yml',
        'source_sha256' => Digest::SHA256.file(source).hexdigest,
        'profile_sha256' => Digest::SHA256.file(profile).hexdigest,
        # Includes the effective profile, selected recipe, ordered overlays and workflows.
        'generated_input_sha256' => project.lock.fetch('inputs'),
        'files' => FILES.to_h { |name| [name, Digest::SHA256.file(File.join(downloads, name)).hexdigest] }
      }
      File.write(File.join(downloads, 'manifest.json'), "#{JSON.pretty_generate(manifest)}\n", mode: 'wx')
      version = manifest.slice('schema_version', 'source_code_sha', 'generator_version')
      File.write(version_file, "#{JSON.pretty_generate(version)}\n", mode: 'wx')
      manifest
    end
  end
end

DocsProviderAssets.build(ARGV.fetch(0, 'docs/_build')) if $PROGRAM_NAME == __FILE__
