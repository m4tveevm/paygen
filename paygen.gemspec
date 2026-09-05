# frozen_string_literal: true
require_relative 'lib/paygen/version'
Gem::Specification.new do |s|
  s.name = 'paygen'
  s.version = Paygen::VERSION
  s.summary = 'Deterministic, auditable payout integration generator'
  s.authors = ['Paygen contributors']
  s.license = 'MIT'
  s.homepage = 'https://github.com/m4tveevm/paygen'
  s.required_ruby_version = '>= 3.3'
  s.files = Dir['lib/**/*', 'bin/*', 'recipes/**/*', 'README.md', 'LICENSE']
  s.bindir = 'bin'
  s.executables = ['paygen']
  s.require_paths = ['lib']
  s.add_dependency 'dry-cli', '~> 1.3'
  s.add_dependency 'json_schemer', '~> 2.4'
  s.add_dependency 'janeway-jsonpath', '>= 0.1', '< 2'
  s.add_dependency 'rack', '~> 3.1'
  s.add_dependency 'puma', '>= 6.6', '< 8'
  s.add_dependency 'prop_check', '~> 1.0'
  s.add_dependency 'listen', '~> 3.9'
  s.add_dependency 'diff-lcs', '~> 1.6'
  s.add_dependency 'bigdecimal', '>= 3.1'
  s.add_dependency 'logger', '>= 1.6'
end
