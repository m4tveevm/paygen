# frozen_string_literal: true

require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'rubygems/package'

# Exercise the installed gem from outside the checkout: Bundler's source-gem
# load path must not hide missing runtime assets, recipes or a broken executable.
root = File.expand_path('..', __dir__)
dependency_paths = (Gem.path + Gem.loaded_specs.values.map(&:base_dir)).uniq
clean_env = ENV.keys.grep(/\ABUNDLE_/).to_h { |name| [name, nil] }
clean_env.merge!('RUBYOPT' => nil, 'RUBYLIB' => nil)

Dir.mktmpdir('paygen-package-') do |directory|
  archive = File.join(directory, 'paygen.gem')
  install = File.join(directory, 'gems')
  run = lambda do |env, cwd, *arguments|
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, *arguments, chdir: cwd)
    abort "#{arguments.join(' ')} failed:\n#{stdout}\n#{stderr}" unless status.success?
    stdout
  end
  run.call({}, root, '-S', 'gem', 'build', 'paygen.gemspec', '--output', archive)
  package = Gem::Package.new(archive)
  required = %w[src/bin/paygen src/lib/paygen.rb src/lib/paygen/runtime/demo/index.html
                src/lib/paygen/core/schemas/arazzo-1.1.json src/recipes/novapay.yml]
  abort 'Gem is missing runtime assets' unless (required - package.contents).empty?

  env = clean_env.merge('GEM_HOME' => install, 'GEM_PATH' => ([install] + dependency_paths).join(File::PATH_SEPARATOR))
  run.call(env, directory, '-S', 'gem', 'install', '--local', '--no-document', '--ignore-dependencies',
           '--install-dir', install, '--bindir', File.join(install, 'bin'), archive)
  executable = File.join(install, 'bin/paygen')
  run.call(env, directory, executable, 'doctor')
  project = File.join(directory, 'project')
  run.call(env, directory, executable, 'init', File.join(root, 'fixtures/novapay/openapi.yaml'), '--output', project)
  abort 'Installed gem did not find its bundled recipe' unless File.file?(File.join(project, 'recipes/selected.yml'))
  run.call(env, directory, executable, 'generate', project)
  run.call(env, directory, executable, 'verify', project, '--seed', '42')
end

puts 'Installed gem: CLI, bundled assets, recipe discovery, generation and verification passed'
