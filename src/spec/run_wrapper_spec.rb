# frozen_string_literal: true
require 'spec_helper'
require 'open3'

RSpec.describe 'src/run test entrypoint' do
  it 'uses src/spec with flags, preserves explicit selections, and rejects empty runs' do
    Dir.mktmpdir('paygen-wrapper-') do |root|
      original = File.expand_path('..', __dir__)
      FileUtils.mkdir_p(File.join(root, 'src/spec'))
      FileUtils.mkdir_p(File.join(root, 'src/script'))
      FileUtils.mkdir_p(File.join(root, 'src/lib/paygen'))
      %w[run .rspec Gemfile Gemfile.lock paygen.gemspec lib/paygen/version.rb script/rspec-policy.rb].each do |name|
        FileUtils.cp(File.join(original, name), File.join(root, 'src', name))
      end
      File.write(File.join(root, 'src/spec/spec_helper.rb'), "require 'rspec'\n")
      File.write(File.join(root, 'src/spec/probe_spec.rb'), "RSpec.describe('wrapper probe') do\n  it('selected case') { expect(2 + 2).to eq(4) }\nend\n")
      FileUtils.mkdir_p(File.join(root, 'checks'))
      File.write(File.join(root, 'checks/explicit_spec.rb'), "RSpec.describe('explicit') { it('outside default') { expect(true).to eq(true) } }\n")
      [[], %w[--seed 29193], %w[--format documentation], %w[src/spec/probe_spec.rb],
       %w[src/spec/probe_spec.rb:2], %w[--example selected], %w[checks/explicit_spec.rb]].each do |args|
        out, err, status = Open3.capture3('bash', 'src/run', 'test', *args, chdir: root)
        expect(status.exitstatus).to eq(0), "#{args.inspect}: #{out} #{err}"
        expect(out).to include('1 example, 0 failures')
      end
      [%w[--example deliberately-absent], %w[--pattern does-not-match/**/*_spec.rb]].each do |args|
        out, err, status = Open3.capture3('bash', 'src/run', 'test', *args, chdir: root)
        expect(status.exitstatus).not_to eq(0), "#{args.inspect}: #{out} #{err}"
        expect(out).to include('0 examples')
      end
      File.delete(File.join(root, 'src/spec/probe_spec.rb'))
      out, err, status = Open3.capture3('bash', 'src/run', 'test', chdir: root)
      expect(status.exitstatus).not_to eq(0), "#{out} #{err}"
    end
  end
end
