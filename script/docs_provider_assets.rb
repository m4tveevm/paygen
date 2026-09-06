# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../lib/paygen'

output = File.expand_path(ARGV.fetch(0, 'docs/_build'))
raise 'Documentation output does not exist; render it first' unless File.directory?(output)

downloads = File.join(output, 'downloads', 'novapay')
raise 'Refusing a symbolic-link documentation output' if File.symlink?(output) || File.symlink?(downloads)

FileUtils.rm_rf(downloads)
FileUtils.mkdir_p(downloads)

Dir.mktmpdir('paygen-docs-provider-') do |directory|
  project = Paygen::Project.init(File.expand_path('../fixtures/novapay/openapi.yaml', __dir__),
                                 output: File.join(directory, 'novapay'))
  Paygen::Generator.new(project).generate
  %w[INTEGRATION.md fixtures.json config.json diagnostics.json provenance.json].each do |name|
    FileUtils.cp(project.path("generated/#{name}"), File.join(downloads, name))
  end
end

source_sha = ENV.fetch('PAYGEN_SOURCE_SHA', nil)
if source_sha.to_s.empty?
  source_sha, status = Open3.capture2('git', 'rev-parse', 'HEAD', chdir: File.expand_path('..', __dir__))
  raise 'Cannot determine source revision' unless status.success?

  source_sha = source_sha.strip
end
raise 'PAYGEN_SOURCE_SHA must be a full commit SHA' unless source_sha.match?(/\A[0-9a-f]{40}\z/)

files = Dir[File.join(downloads, '*')].select { |path| File.file?(path) }.sort
manifest = {
  'schema_version' => 1,
  'source_code_sha' => source_sha,
  'generator_version' => Paygen::VERSION,
  'provider' => 'novapay',
  'profile_sha256' => Digest::SHA256.file(File.expand_path('../fixtures/novapay/integration.yml', __dir__)).hexdigest,
  'source_sha256' => Digest::SHA256.file(File.expand_path('../fixtures/novapay/openapi.yaml', __dir__)).hexdigest,
  'files' => files.to_h { |path| [File.basename(path), Digest::SHA256.file(path).hexdigest] }
}
File.write(File.join(downloads, 'manifest.json'), "#{JSON.pretty_generate(manifest)}\n")
version = manifest.slice('schema_version', 'source_code_sha', 'generator_version')
File.write(File.join(output, 'version.json'), "#{JSON.pretty_generate(version)}\n")
