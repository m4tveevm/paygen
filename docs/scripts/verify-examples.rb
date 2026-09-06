# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'socket'
require 'tmpdir'
require 'timeout'

# The marked Markdown fences are the commands under test, not a second copy.
module DocsExamples
  ROOT = File.expand_path('../..', __dir__)
  DATASETS = {
    'novapay' => ['fixtures/novapay/openapi.yaml'],
    'paypal' => ['fixtures/paypal/openapi.yaml'],
    'stripe' => ['fixtures/stripe/openapi.yaml'],
    'adyen' => ['fixtures/adyen/openapi.yaml'],
    'native-paystack' => ['fixtures/native-paystack/openapi.yaml', 'fixtures/native-paystack/profile.yml'],
    'native-paypal' => ['fixtures/native-paypal/openapi.json', 'fixtures/native-paypal/profile.yml'],
    'raiffeisen_payouts' => ['fixtures/raiffeisen_payouts/upstream/openapi.json', 'fixtures/raiffeisen_payouts/integration.yml']
  }.freeze

  class Runner
    attr_reader :output

    def initialize
      FileUtils.mkdir_p(File.join(ROOT, 'tmp/docs-examples'))
      @output = Dir.mktmpdir('run.', File.join(ROOT, 'tmp/docs-examples'))
      @events = []
      @env = { 'PAYGEN_EXAMPLES_DIR' => output, 'PAYGEN_DEMO_PORT' => free_port, 'PAYGEN_SIMULATOR_PORT' => free_port }
      @cli = [RbConfig.ruby, File.join(ROOT, 'src/bin/paygen')]
    end

    def free_port
      socket = TCPServer.new('127.0.0.1', 0)
      socket.addr[1].to_s
    ensure
      socket&.close
    end

    def check(condition, message)
      raise message unless condition
      puts "PASS #{message}"
      @events << { 'kind' => 'assertion', 'output' => "PASS #{message}" }
    end

    def read(name) = JSON.parse(File.read(File.join(output, name)))

    def capture(command, name, expected = 0)
      stdout_path, stderr_path = %w[stdout stderr].map { |stream| File.join(output, "#{name}.#{stream}") }
      pid = Process.spawn(@env, *command, chdir: ROOT, out: stdout_path, err: stderr_path, pgroup: true)
      begin
        status = Timeout.timeout(60) { Process.wait2(pid).last }
      rescue Timeout::Error
        Process.kill('KILL', -pid)
        Process.wait(pid)
        raise "#{name}: exceeded 60 seconds; owned process group stopped"
      end
      out, err = [stdout_path, stderr_path].map { |path| File.read(path) }
      File.write(File.join(output, "#{name}.log"), out + err)
      @events << { 'kind' => 'command', 'name' => name, 'command' => command.last,
                   'stdout' => out, 'stderr' => err, 'exit' => status.exitstatus }
      check(status.exitstatus == expected, "#{name}: exit #{expected}")
      if expected == 4
        error = JSON.parse(err)
        check(error.dig('error', 'code') == 'SEMANTIC_BLOCKERS', "#{name}: semantic refusal")
      end
      out
    end

    def stop_server
      return unless @pid
      Process.kill('TERM', -@pid)
      Timeout.timeout(5) { Process.wait(@pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      Process.kill('KILL', -@pid)
      Process.wait(@pid)
    ensure
      @pid = nil
    end

    def start_server(command, name)
      stop_server
      port = @env.fetch(name == 'demo' ? 'PAYGEN_DEMO_PORT' : 'PAYGEN_SIMULATOR_PORT')
      log = File.join(output, "#{name}-server.log")
      @pid = Process.spawn(@env, 'bash', '-euo', 'pipefail', '-c', "exec #{command.strip}",
                           chdir: ROOT, out: log, err: [:child, :out], pgroup: true)
      Timeout.timeout(15) do
        loop do
          raise "#{name} exited: #{File.read(log)}" if Process.waitpid(@pid, Process::WNOHANG)
          begin
            TCPSocket.new('127.0.0.1', port.to_i).close
            break
          rescue Errno::ECONNREFUSED
            sleep 0.05
          end
        end
      end
      @events << { 'kind' => 'server', 'name' => name, 'command' => command, 'output' => File.read(log) }
      check(true, "#{name}: loopback server listening")
    end

    def walkthrough
      page = File.read(File.join(ROOT, 'docs/content/dataset-walkthrough.md'))
      blocks = page.scan(/<!-- verify(-server)?: ([a-z-]+)(?: exit=(\d+))? -->\n```bash\n(.*?)\n```/m)
      check(blocks.length == 15, 'all 15 walkthrough blocks discovered')
      blocks.each do |server, name, expected, command|
        if server
          start_server(command, name)
          next
        end
        stop_server if name == 'unknown-init'
        capture(['bash', '-euo', 'pipefail', '-c', command], name, (expected || '0').to_i)
        case name
        when 'known-init'
          check(read('known-review.json')['ready'] == true, 'reviewed recipe ready')
        when 'known-generate'
          verification('known-verify.json')
        when 'known-export'
          check(File.file?(File.join(output, 'guide/index.html')), 'portable HTML exists')
          check(File.file?(File.join(output, 'adapter/novapay_service.rb')), 'detached adapter exists')
        when 'demo-payment'
          create, retry_result = read('create.json'), read('retry.json')
          check(create['success'] && create['status'] == 'in_progress', 'create accepted, not settled')
          check(create['provider_id'] && retry_result['provider_id'] == create['provider_id'], 'retry preserves provider identity')
          check(read('poll-1.json')['status'] == 'in_progress' && read('poll-2.json')['status'] == 'approved', 'polls reach confirmed settlement')
          check(read('evidence.json')['created_count'] == 1, 'exactly one provider payout')
        when 'serve-client'
          verification('http-verify.json')
        when 'unknown-init'
          @source_hash = Digest::SHA256.file(File.join(output, 'unknown/source/openapi.json')).hexdigest
          check(read('unknown-review.json')['ready'] == false, 'unknown contract requires operator')
          candidates = read('unknown-review.json').dig('candidates', 'create').map { |candidate| candidate['operation_id'] }
          check(%w[createPayout createPayoutPreview].all? { |id| candidates.include?(id) }, 'both creation candidates visible')
        when 'unknown-draft'
          check(Dir[File.join(output, 'unknown/generated/*_service.rb')].empty?, 'draft has no executable adapter')
        when 'partial-review'
          report = read('partial-review.json')
          check(report['ready'] == false && report['diagnostics'].any? { |d| d['code'] == 'OPERATOR_REVIEW_REQUIRED' }, 'partial answers cannot approve inferred fields')
        when 'resolved-review'
          check(read('resolved-review.json')['ready'] == true, 'explicit answers resolve review')
          verification('resolved-verify.json')
          check(@source_hash == Digest::SHA256.file(File.join(output, 'unknown/source/openapi.json')).hexdigest, 'operator decisions preserve pinned source bytes')
        end
      end
    ensure
      stop_server
    end

    def verification(file)
      report = read(file)
      check(report['success'] == true && report['failed'] == 0, "#{file}: adapter checks pass")
    end

    def hashes(directory)
      Dir.glob(File.join(directory, '**/*')).select { |path| File.file?(path) }.sort.to_h do |path|
        [path.delete_prefix(directory + '/'), Digest::SHA256.file(path).hexdigest]
      end
    end

    def datasets
      DATASETS.each do |name, (source, profile)|
        manifests = 2.times.map do |index|
          base = File.join(output, "#{name}-#{index}")
          args = ['init', source, '--output', base]
          args += ['--profile', profile] if profile
          capture(@cli + args, "#{name}-#{index}-init")
          capture(@cli + ['generate', base], "#{name}-#{index}-generate")
          capture(@cli + ['diff', base, '--check'], "#{name}-#{index}-diff")
          %w[html md].each do |format|
            capture(@cli + ['docs', base, '--format', format, '--output', "#{base}-#{format}"], "#{name}-#{index}-#{format}")
          end
          capture(@cli + ['collection', base, '--output', "#{base}-bruno"], "#{name}-#{index}-bruno")
          if index.zero?
            report = JSON.parse(capture(@cli + ['verify', base, '--seed', '42'], "#{name}-verify"))
            check(report['success'] == true && report['failed'] == 0, "#{name}: dataset verification")
          end
          { 'generated' => hashes("#{base}/generated"), 'html' => hashes("#{base}-html"),
            'md' => hashes("#{base}-md"), 'bruno' => hashes("#{base}-bruno") }
        end
        check(manifests[0] == manifests[1], "#{name}: independent builds byte-identical")
        File.write(File.join(output, "#{name}-manifest.json"), JSON.pretty_generate(manifests[0]) + "\n")
      end
    end

    def run
      walkthrough
      datasets
      @success = true
    ensure
      File.write(File.join(output, 'recording.json'), JSON.pretty_generate(@events) + "\n")
      File.write(File.join(output, 'report.json'), JSON.pretty_generate('success' => @success == true, 'datasets' => DATASETS.keys) + "\n")
      puts "Evidence: #{output}"
    end
  end
end

DocsExamples::Runner.new.run if $PROGRAM_NAME == __FILE__
