#!/usr/bin/env ruby
# frozen_string_literal: true
require 'optparse'
require 'open3'
require 'timeout'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'puma'
require_relative '../src/lib/paygen'
require_relative '../src/lib/paygen/collection'
require_relative '../src/lib/paygen/runtime/demo'

module Paygen
  # Runs a separately installed, pinned Bruno CLI against real loopback HTTP.
  # No package installation or external provider call occurs in this runner.
  class BrunoVerification
    ROOT = File.expand_path('..', __dir__)
    PROFILES = %w[novapay stripe native-paystack raiffeisen_payouts].freeze

    def self.run(arguments)
      options = { cli: ENV['PAYGEN_BRUNO_CLI'], node: ENV.fetch('PAYGEN_NODE_EXECUTABLE', 'node') }
      parser = OptionParser.new do |flags|
        flags.banner = 'Usage: src/run exec ruby script/verify-bruno.rb --cli PATH [--output NEW_DIRECTORY]'
        flags.on('--cli PATH', 'Bruno CLI JavaScript entrypoint; defaults to PAYGEN_BRUNO_CLI') { |value| options[:cli] = value }
        flags.on('--output DIRECTORY', 'Keep JSON, JUnit and logs in a new directory') { |value| options[:output] = value }
        flags.on('-h', '--help', 'Show usage') { puts flags; return true }
      end
      parser.parse!(arguments)
      raise ArgumentError, 'Unexpected positional arguments' unless arguments.empty?
      raise ArgumentError, 'Set --cli or PAYGEN_BRUNO_CLI to the installed Bruno JavaScript entrypoint' if options[:cli].to_s.empty?

      options[:cli] = File.expand_path(options.fetch(:cli))
      raise ArgumentError, 'Bruno CLI entrypoint must be a file' unless File.file?(options.fetch(:cli))

      version, error, status = Open3.capture3(options.fetch(:node), options.fetch(:cli), '--version')
      unless status.success? && version.strip == Collection::BRUNO_VERSION
        raise ArgumentError, "Expected Bruno CLI #{Collection::BRUNO_VERSION}; received #{version.strip.inspect}: #{error.strip}"
      end

      if options[:output]
        destination = File.expand_path(options.fetch(:output))
        raise ArgumentError, 'Report output directory already exists' if File.exist?(destination) || File.symlink?(destination)

        FileUtils.mkdir_p(File.dirname(destination))
        Dir.mkdir(destination)
        new(options, destination).run
      else
        Dir.mktmpdir('paygen-bruno-reports-') { |destination| new(options, destination).run }
      end
    rescue OptionParser::ParseError, ArgumentError, Error, SystemCallError, Timeout::Error => e
      warn "Bruno verification failed: #{e.message}"
      false
    end

    def initialize(options, destination)
      @options = options
      @destination = destination
      @runs = []
    end

    def run
      Dir.mktmpdir('paygen-bruno-projects-') do |working|
        PROFILES.each { |provider| verify_provider(provider, working) }
      end
      passed = @runs.all? { |run| run.fetch('success') }
      summary = { 'status' => passed ? 'PASS' : 'FAIL', 'bruno_version' => Collection::BRUNO_VERSION,
                  'profiles' => PROFILES, 'runs' => @runs, 'requests' => @runs.sum { |run| run.fetch('requests') },
                  'tests' => @runs.sum { |run| run.fetch('tests') } }
      File.write(File.join(@destination, 'summary.json'), Paygen.json(summary))
      puts JSON.generate(summary)
      passed
    end

    private

    def verify_provider(provider, working)
      fixture = File.join(ROOT, 'fixtures', provider)
      source = Dir[File.join(fixture, 'openapi.*'), File.join(fixture, 'upstream/openapi.*')].first
      profile = File.join(fixture, 'profile.yml')
      project = Project.init(source, output: File.join(working, "#{provider}-project"),
                             **(File.file?(profile) ? { profile: profile } : {}))
      generator = Generator.new(project)
      generator.generate
      exported = Collection.new(project).export(output: File.join(working, "#{provider}-collection"))
      rendered = generator.render
      config = JSON.parse(rendered.fetch('config.json'))
      app = Runtime::Demo.new(source: rendered.fetch("#{config.fetch('provider')}_service.rb"), config: config)
      server = Puma::Server.new(app)
      listener = server.add_tcp_listener('127.0.0.1', 0)
      port = listener.addr[1]
      server.run
      begin
        # A second complete run against the same state verifies that baseline
        # evidence and fresh IDs work without restarting the application.
        (provider == 'novapay' ? 2 : 1).times do |index|
          name = "#{provider}-#{index + 1}"
          run_collection(name, exported.fetch('path'), port)
        end
        FileUtils.cp(File.join(exported.fetch('path'), 'paygen-collection.json'), File.join(@destination, "#{provider}-collection.json"))
      ensure
        server.stop(true)
      end
    end

    def run_collection(name, collection, port)
      json_path = File.join(@destination, "#{name}.json")
      junit_path = File.join(@destination, "#{name}.xml")
      log_path = File.join(@destination, "#{name}.log")
      command = [@options.fetch(:node), @options.fetch(:cli), 'run', '--env', 'local',
                 '--env-var', "baseUrl=http://127.0.0.1:#{port}", '--noproxy', '--bail',
                 '--reporter-json', json_path, '--reporter-junit', junit_path]
      status = run_command(command, collection, log_path)
      results = File.file?(json_path) ? JSON.parse(File.read(json_path)).flat_map { |iteration| iteration.fetch('results', []) } : []
      tests = results.flat_map { |result| result.fetch('testResults', []) }
      passed = status.success? && results.any? && tests.any? &&
               results.all? { |result| result['status'] == 'pass' && !result['skipped'] } &&
               tests.all? { |test| test['status'] == 'pass' }
      @runs << { 'name' => name, 'success' => passed, 'requests' => results.length, 'tests' => tests.length }
      puts "#{name}: #{passed ? 'PASS' : 'FAIL'} (#{results.length} requests, #{tests.length} tests)"
      warn File.read(log_path) unless passed
    end

    def run_command(command, directory, log_path)
      File.open(log_path, 'w') do |log|
        child = Process.spawn(*command, chdir: directory, out: log, err: log)
        begin
          Timeout.timeout(180) { Process.wait2(child).last }
        rescue Timeout::Error
          Process.kill('TERM', child)
          begin
            Timeout.timeout(5) { Process.wait(child) }
          rescue Timeout::Error
            Process.kill('KILL', child)
            Process.wait(child)
          end
          raise Timeout::Error, 'Bruno collection exceeded the 180-second limit'
        end
      end
    end
  end
end

exit(Paygen::BrunoVerification.run(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
