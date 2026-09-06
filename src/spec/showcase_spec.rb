# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require_relative '../../examples/showcase/runner'

RSpec.describe 'Disposable showcase tooling' do
  it 'rejects executable-looking and out-of-range ports before spawning a process' do
    ['9293;exit', '-1', '65536', '1.5'].each do |port|
      expect { PaygenShowcase::Runner.new(nil, port: port) }.to raise_error(PaygenShowcase::Failure, /port/)
    end
  end

  it 'does not overwrite an existing output directory' do
    Dir.mktmpdir do |directory|
      marker = File.join(directory, 'keep.txt')
      File.write(marker, 'user-owned')
      expect { PaygenShowcase::Runner.new(directory).run }.to raise_error(PaygenShowcase::Failure, /new or empty/)
      expect(File.read(marker)).to eq('user-owned')
      expect(Dir.children(directory)).to eq(['keep.txt'])
    end
  end

  it 'labels a container revision as a build declaration and rejects malformed metadata' do
    Dir.mktmpdir do |directory|
      runner = PaygenShowcase::Runner.new(directory)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(File.expand_path('../../.git', __dir__)).and_return(false)
      allow(ENV).to receive(:[]).with('PAYGEN_SOURCE_SHA').and_return('a' * 40)
      allow(ENV).to receive(:fetch).with('PAYGEN_SOURCE_DIRTY', 'unknown').and_return('clean')
      runner.send(:record_revision)
      report = JSON.parse(File.read(File.join(directory, 'source-revision.json')))
      expect(report).to include('kind' => 'build_declared', 'verified_git_checkout' => false, 'dirty' => 'clean', 'sha' => 'a' * 40)
      [nil, '', 'unknown'].each do |missing|
        allow(ENV).to receive(:[]).with('PAYGEN_SOURCE_SHA').and_return(missing)
        runner.send(:record_revision)
        report = JSON.parse(File.read(File.join(directory, 'source-revision.json')))
        expect(report).to include('kind' => 'unavailable', 'verified_git_checkout' => false, 'sha' => nil)
        expect(File.read(File.join(directory, 'tested-sha.txt'))).to start_with('UNAVAILABLE:')
      end
      allow(ENV).to receive(:[]).with('PAYGEN_SOURCE_SHA').and_return('not-a-revision')
      expect { runner.send(:record_revision) }.to raise_error(PaygenShowcase::Failure, /40 hexadecimal/)
    end
  end

  it 'refuses an occupied port without signaling or starting another process' do
    runner = PaygenShowcase::Runner.new
    expect(TCPServer).to receive(:new).with('127.0.0.1', 9293).and_raise(Errno::EADDRINUSE)
    expect(Process).not_to receive(:spawn)
    expect(Process).not_to receive(:kill)
    expect do
      runner.send(:with_server, '/unused', 'occupied') { raise 'an occupied port must not yield' }
    end.to raise_error(PaygenShowcase::Failure, /no existing process was stopped/)
  end

  it 'bounds a child command and reaps only its owned process' do
    Dir.mktmpdir do |directory|
      processes = PaygenShowcase::Processes.new
      log = File.join(directory, 'child.log')
      script = "trap('TERM') { exit 23 }; STDOUT.write('ready'); STDOUT.flush; sleep 30"
      pid = processes.start([RbConfig.ruby, '-e', script], log: log)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      until File.read(log).include?('ready')
        raise 'child failed to initialize' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end
      expect { processes.wait(pid, seconds: 0.05) }.to raise_error(PaygenShowcase::Failure, /exceeded/)
      expect(processes.records.first).to include('status' => 'EXITED', 'exit_code' => 23)
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
      processes.stop_all
    end
  end

  it 'detects, shrinks and replays an isolated mutant, then passes the identical trace through the ordinary CLI' do
    Dir.mktmpdir do |directory|
      project = Paygen::Project.init(File.expand_path('../../fixtures/novapay/openapi.yaml', __dir__), output: File.join(directory, 'project'))
      Paygen::Generator.new(project).generate
      before = Digest::SHA256.file(project.path('generated/novapay_service.rb')).hexdigest
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Isrc/lib', 'examples/showcase/mutation.rb', project.root, directory)
      expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
      summary = JSON.parse(stdout)
      expect(summary.fetch('shrunk_steps')).to be < summary.fetch('original_steps')
      failed = JSON.parse(File.read(File.join(directory, 'mutant-replay.json')))
      expect(failed.dig('failure', 'invariant')).to eq('duplicate_payout')
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Isrc/lib', 'src/bin/paygen', 'fuzz', project.root,
                                            '--replay', File.join(directory, 'mutant-trace.json'))
      expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
      fixed = JSON.parse(stdout)
      expect(fixed).to include('success' => true, 'failure' => nil, 'trace' => failed.fetch('trace'),
                              'profile_sha256' => failed.fetch('profile_sha256'))
      expect(Digest::SHA256.file(project.path('generated/novapay_service.rb')).hexdigest).to eq(before)
      expect(Paygen::Generator.new(project).diff).to be_empty
    end
  end
end
