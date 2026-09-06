# frozen_string_literal: true

require 'paygen'
require 'openssl'
require_relative 'support'

module PaygenShowcase
  class Runner
    PROVIDERS = %w[novapay stripe paypal adyen].freeze

    def initialize(output = nil, port: ENV.fetch('PAYGEN_DEMO_PORT', '9293'))
      @root = File.expand_path('../..', __dir__)
      @output = File.expand_path(output || "tmp/showcase-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}", @root)
      raise Failure, 'port must be an integer from 0 to 65535 (0 selects a free port)' unless port.to_s.match?(/\A\d+\z/) && Integer(port).between?(0, 65_535)

      @port = Integer(port)
      @processes = Processes.new
      @commands = []
      @checks = []
    end

    def run
      raise Failure, 'output must be a new or empty directory' if File.exist?(@output) && (!File.directory?(@output) || !Dir.empty?(@output))

      FileUtils.mkdir_p(@output)
      @started = true
      trap('INT') { raise Interrupt }
      trap('TERM') { raise Interrupt }
      record_revision
      snapshot = %w[src/lib src/bin src/recipes fixtures examples/showcase].to_h { |name| [name, hashes(File.join(@root, name))] }
      snapshot['dependencies'] = %w[src/Gemfile src/Gemfile.lock src/paygen.gemspec].to_h { |name| [name, Digest::SHA256.file(File.join(@root, name)).hexdigest] }
      save('source-snapshot-sha256.json', snapshot)
      cli('doctor', 'doctor')
      save('environment.json', 'ruby' => RUBY_VERSION, 'platform' => RUBY_PLATFORM,
           'bundler' => Bundler::VERSION, 'seed' => 4242, 'network' => 'synthetic loopback only')
      puts 'S1: initialize four focused contracts and prove byte-identical regeneration'
      PROVIDERS.each { |provider| generate(provider) }
      puts 'S2: execute four generated adapters through real loopback application HTTP'
      PROVIDERS.each { |provider| exercise_provider(provider) }
      puts 'S3: independent malformed wire requests against a strict HTTP provider'
      wire_contract
      puts 'S4: profile + Overlay semantic adaptation; preserve source and user extension'
      adaptation
      puts 'S5: disposable mutant failure -> shrink -> replay -> unmodified adapter replay'
      mutation
      cli('fuzz', 'fuzz', project('novapay'), '--seed', '4242', '--cases', '12', '--steps', '8')
      check('bounded_fuzz', read('fuzz.json')['success'] == true)
      @processes.stop_all
      check('owned_processes_stopped', @processes.records.none? { |record| record['status'] == 'RUNNING' })
      save('summary.json', 'status' => 'PASS', 'checks' => @checks,
           'scope' => 'Synthetic loopback adapter/simulator evidence; not PSP sandbox, settlement, installation harness, or PCI certification.')
      puts "PASS: #{@checks.length} assertions; reports: #{@output}"
    rescue StandardError, Interrupt => e
      save('summary.json', 'status' => 'FAIL', 'error' => "#{e.class}: #{e.message}", 'checks' => @checks) if @started
      raise
    ensure
      @processes.stop_all
      if @started
        save('commands.json', @commands)
        save('processes.json', @processes.records)
      end
    end

    private

    def project(provider)
      File.join(@output, provider)
    end

    def save(name, value)
      File.write(File.join(@output, name), Paygen.json(value))
    end

    def read(name)
      JSON.parse(File.read(File.join(@output, name)))
    end

    def record_revision
      if File.exist?(File.join(@root, '.git'))
        command('tested-sha', ['git', 'rev-parse', 'HEAD'], suffix: 'txt')
        command('dirty-state', ['git', 'status', '--porcelain'], suffix: 'txt')
        save('source-revision.json', 'kind' => 'git_checkout', 'verified_git_checkout' => true)
      else
        # A container build declaration is useful provenance, not a verified
        # checkout. Snapshot hashes identify the actual code independently.
        revision = ENV['PAYGEN_SOURCE_SHA']
        revision = nil if revision.nil? || revision.empty? || revision == 'unknown'
        raise Failure, 'PAYGEN_SOURCE_SHA must be exactly 40 hexadecimal characters' if revision && !revision.match?(/\A[0-9a-fA-F]{40}\z/)
        dirty = ENV.fetch('PAYGEN_SOURCE_DIRTY', 'unknown')
        raise Failure, 'PAYGEN_SOURCE_DIRTY must be clean, dirty, unknown, 0 or 1' unless %w[clean dirty unknown 0 1].include?(dirty)
        dirty = { '0' => 'clean', '1' => 'dirty' }.fetch(dirty, dirty)
        File.write(File.join(@output, 'tested-sha.txt'), "#{revision || 'UNAVAILABLE: not a Git checkout; see source-snapshot-sha256.json'}\n")
        File.write(File.join(@output, 'dirty-state.txt'), "Build-declared: #{dirty}\n")
        save('source-revision.json', 'kind' => revision ? 'build_declared' : 'unavailable',
             'sha' => revision, 'dirty' => dirty, 'verified_git_checkout' => false)
      end
    end

    def check(id, condition)
      @checks << { 'id' => id, 'status' => condition ? 'PASS' : 'FAIL' }
      PaygenShowcase.assert(condition, id)
    end

    def command(name, argv, expected: 0, suffix: 'json')
      pid = @processes.start(argv, log: File.join(@output, "#{name}.#{suffix}"), stderr: File.join(@output, "#{name}.stderr"))
      result = @processes.wait(pid)
      @commands << { 'name' => name, 'argv' => argv, 'expected_exit' => expected, 'actual_exit' => result.exitstatus }
      check("command:#{name}", result.exitstatus == expected)
    end

    def cli(name, *arguments, expected: 0)
      command(name, [RbConfig.ruby, '-Isrc/lib', 'src/bin/paygen', *arguments], expected: expected)
    end

    def hashes(directory)
      Dir.glob(File.join(directory, '**', '*')).select { |path| File.file?(path) }.sort.to_h do |path|
        [path.delete_prefix("#{directory}/"), Digest::SHA256.file(path).hexdigest]
      end
    end

    def generate(provider)
      cli("#{provider}-inspect", 'inspect', "fixtures/#{provider}/openapi.yaml", '--profile', "fixtures/#{provider}/integration.yml", '--format', 'json')
      cli("#{provider}-init", 'init', "fixtures/#{provider}/openapi.yaml", '--output', project(provider))
      cli("#{provider}-configure", 'configure', project(provider))
      cli("#{provider}-generate", 'generate', project(provider))
      before = hashes(File.join(project(provider), 'generated'))
      cli("#{provider}-regenerate", 'generate', project(provider))
      check("#{provider}:byte_identical_regeneration", before == hashes(File.join(project(provider), 'generated')))
      save("#{provider}-artifact-sha256.json", before)
      cli("#{provider}-diff", 'diff', project(provider), '--check')
      command("#{provider}-syntax", [RbConfig.ruby, '-c', File.join(project(provider), 'generated', "#{provider}_service.rb")], suffix: 'txt')
    end

    def with_server(project_path, label, probe: false)
      socket = TCPServer.new('127.0.0.1', @port)
      port = socket.addr[1]
      socket.close
      argv = if probe
               [RbConfig.ruby, '-Isrc/lib', 'examples/showcase/provider_probe.rb', project_path, port.to_s]
             else
               [RbConfig.ruby, '-Isrc/lib', 'src/bin/paygen', 'demo', project_path, '--port', port.to_s]
             end
      pid = @processes.start(argv, log: File.join(@output, "#{label}-server.log"))
      client = Client.new(port)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        raise Failure, "#{label} exited before readiness" if @processes.poll(pid)
        begin
          ready = client.request('get', probe ? '/__evidence' : '/artifacts')
          if ready['http_status'] == 200
            unless probe
              provider = ready.dig('body', 'provider')
              expected = Digest::SHA256.file(File.join(project_path, 'generated', "#{provider}_service.rb")).hexdigest
              check("#{label}:loaded_generated_bytes", ready.dig('body', 'generated_service_sha256') == expected)
            end
            save("#{label}-readiness.json", ready.merge('port' => port))
            break
          end
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout
          # A bounded wait; never stop an unrelated listener to acquire the port.
        end
        raise Failure, "#{label} readiness exceeded 10 seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
      yield client
    rescue Errno::EADDRINUSE
      raise Failure, "port #{@port} is occupied; no existing process was stopped"
    ensure
      socket&.close unless socket&.closed?
      @processes.stop(pid) if pid
    end

    def observed(client, name, method, path, **arguments)
      result = client.request(method, path, **arguments)
      save("#{name}.json", result)
      result
    end

    def exercise_provider(provider)
      fixture = JSON.parse(File.read("fixtures/#{provider}/fixtures.json"))
      with_server(project(provider), provider) do |client|
        (provider == 'novapay' ? 3 : 1).times do |index|
          operation = fixture.fetch('operation').merge('id' => "showcase-#{provider}-#{index}")
          operation['amount'] = '1500.00' if provider == 'novapay'
          name = "#{provider}-run-#{index}"
          id = operation.fetch('id')
          before = client.request('get', '/evidence').fetch('body')
          created = observed(client, "#{name}-create", 'post', '/operations', payload: operation)
          check("#{name}:create", created['http_status'] == 200 && created.dig('body', 'success') == true && !created.dig('body', 'provider_id').nil?)
          retry_result = observed(client, "#{name}-retry", 'post', "/operations/#{id}/retry", payload: {})
          check("#{name}:stable_retry", retry_result['http_status'] == 200 && retry_result.dig('body', 'provider_id') == created.dig('body', 'provider_id'))
          status = observed(client, "#{name}-status", 'get', "/operations/#{id}")
          check("#{name}:status", status['http_status'] == 200 && status.dig('body', 'success') == true)
          callback(client, name, provider, id)
          after = observed(client, "#{name}-evidence", 'get', '/evidence').fetch('body')
          check("#{name}:one_provider_commit", after['created_count'] - before['created_count'] == 1)
          create_requests = after['requests'].drop(before['requests'].length).select { |request| request['role'] == 'create' }
          check("#{name}:one_create_wire_request", create_requests.length == 1 && create_requests.first['method'] == 'POST')
          if provider == 'novapay'
            expected_wire = { 'amount' => 150000, 'currency' => 'RUB', 'external_id' => id,
                              'recipient' => { 'type' => 'sbp', 'phone' => operation.dig('payout_requisite', 'sbp', 'phone'),
                                               'bank_code' => operation.dig('payout_requisite', 'sbp', 'bank_code') } }
            check("#{name}:independent_wire_amount", create_requests.first['body_sha256'] == Digest::SHA256.hexdigest(JSON.generate(Paygen.canonical(expected_wire))))
          end
          if provider == 'adyen'
            check("#{name}:booked_is_not_approved", status.dig('body', 'status') == 'in_progress')
          end
        end
        before = client.request('get', '/evidence').fetch('body')
        invalid = observed(client, "#{provider}-invalid-auth", 'post', '/checks/invalid-auth', payload: fixture.fetch('operation').merge('id' => 'invalid-auth'))
        check("#{provider}:invalid_auth", invalid['http_status'] == 422 && invalid.dig('body', 'error', 'code') == 'unauthorized')
        check("#{provider}:invalid_auth_no_commit", client.request('get', '/evidence').dig('body', 'created_count') == before['created_count'])
      end
    end

    def callback(client, name, provider, id)
      events = observed(client, "#{name}-events", 'get', "/events/#{id}").dig('body', 'events')
      check("#{name}:callback_available", events.is_a?(Array) && !events.empty?)
      event = events.last
      before = client.request('get', '/evidence').dig('body', 'backend_events').length
      invalid = observed(client, "#{name}-invalid-callback", 'post', '/callbacks', raw: event.fetch('raw_body'))
      check("#{name}:invalid_callback_rejected", invalid['http_status'] == 422)
      check("#{name}:invalid_callback_no_effect", client.request('get', '/evidence').dig('body', 'backend_events').length == before)
      if provider == 'paypal'
        check("#{name}:verification_hook_required", invalid.dig('body', 'success') == false)
        return # Genuine PayPal verification is intentionally unavailable offline.
      end
      headers = event.fetch('headers').to_h
      if provider == 'novapay'
        expected = OpenSSL::HMAC.hexdigest('SHA256', 'paygen-test-secret', event.fetch('raw_body'))
        check("#{name}:independent_hmac", headers['X-NovaPay-Signature'] == expected)
      end
      valid = observed(client, "#{name}-valid-callback", 'post', '/callbacks', raw: event.fetch('raw_body'), headers: headers)
      check("#{name}:verified_callback", valid['http_status'] == 200)
      duplicate = observed(client, "#{name}-duplicate-callback", 'post', '/callbacks', raw: event.fetch('raw_body'), headers: headers)
      check("#{name}:duplicate_callback", duplicate['http_status'] == 200)
      after = client.request('get', '/evidence').dig('body', 'backend_events').length
      expected_delta = %w[approved rejected reversed cancelled].include?(valid.dig('body', 'status')) ? 1 : 0
      check("#{name}:one_terminal_backend_effect", after - before == expected_delta)
    end

    def wire_contract
      with_server(project('novapay'), 'wire', probe: true) do |client|
        headers = { 'X-API-Key' => 'paygen-simulator-key' }
        body = { 'amount' => 150000, 'currency' => 'RUB', 'external_id' => 'wire-control',
                 'recipient' => { 'type' => 'sbp', 'phone' => '79001234567', 'bank_code' => '044525225' } }
        [body.reject { |key, _value| key == 'amount' }, body.merge('amount' => '150000'), body.merge('currency' => 'USD')].each_with_index do |invalid, index|
          response = observed(client, "wire-invalid-#{index}", 'post', '/v1/payouts', payload: invalid, headers: headers)
          check("wire:negative_schema_#{index}", response['http_status'] == 400 && response.dig('body', 'error', 'code') == 'invalid_request_body')
        end
        check('wire:no_invalid_mutation', observed(client, 'wire-before-control', 'get', '/__evidence').dig('body', 'created_count') == 0)
        valid = observed(client, 'wire-valid-control', 'post', '/v1/payouts', payload: body, headers: headers)
        check('wire:positive_control', valid['http_status'] == 201)
        check('wire:positive_control_commit', observed(client, 'wire-final-evidence', 'get', '/__evidence').dig('body', 'created_count') == 1)
      end
    end

    def adaptation
      adapted = project('adapted-novapay')
      FileUtils.cp_r(project('novapay'), adapted)
      source_before = hashes(File.join(adapted, 'source'))
      File.write(File.join(adapted, 'extensions/showcase-note.md'), "User-owned presenter note: retain this file during regeneration.\n")
      extensions_before = hashes(File.join(adapted, 'extensions'))
      cli('adapt-profile', 'configure', adapted, '--set', 'amount.minimum=200000')
      cli('adapt-overlay', 'patch', 'replace', adapted, '$.components.schemas.CreatePayoutRequest.properties.amount.minimum', '--value', '200000')
      example = "$['paths']['/payouts']['post']['responses']['422']['content']['application/json']['example']['error']"
      cli('adapt-error-example', 'patch', 'replace', adapted, "#{example}['message']", '--value', JSON.generate('Amount must be at least 200000 kopecks'))
      cli('adapt-detail-example', 'patch', 'replace', adapted, "#{example}['details'][0]['message']", '--value', JSON.generate('minimum is 200000'))
      cli('adapt-generate', 'generate', adapted)
      cli('adapt-diff', 'diff', adapted, '--check')
      check('adapt:source_immutable', hashes(File.join(adapted, 'source')) == source_before)
      check('adapt:extensions_preserved', hashes(File.join(adapted, 'extensions')) == extensions_before)
      config = JSON.parse(File.read(File.join(adapted, 'generated/config.json')))
      check('adapt:profile_and_schema_agree', config.dig('amount', 'minimum') == 200000 && config.dig('endpoints', 'create', 'request_schema', 'properties', 'amount', 'minimum') == 200000)
      check('adapt:generated_docs_updated', File.read(File.join(adapted, 'generated/INTEGRATION.md')).include?('Minimum provider units: 200000'))
      examples = File.read(File.join(adapted, 'generated/fixtures.json'))
      check('adapt:explicit_source_examples_updated', examples.include?('minimum is 200000') && !examples.include?('minimum is 100000'))
      with_server(adapted, 'adapted') do |client|
        operation = JSON.parse(File.read('fixtures/novapay/fixtures.json')).fetch('operation')
        invalid = observed(client, 'adapt-old-minimum', 'post', '/operations', payload: operation.merge('id' => 'adapt-rejected', 'amount' => '1500.00'))
        check('adapt:old_amount_rejected', invalid['http_status'] == 422)
        check('adapt:rejected_before_commit', client.request('get', '/evidence').dig('body', 'created_count') == 0)
        valid = observed(client, 'adapt-new-minimum', 'post', '/operations', payload: operation.merge('id' => 'adapt-accepted', 'amount' => '2000.00'))
        check('adapt:new_amount_accepted', valid['http_status'] == 200)
      end
      drift = project('drift-project')
      FileUtils.cp_r(project('novapay'), drift)
      File.open(File.join(drift, 'generated/novapay_service.rb'), 'a') { |file| file.puts "\n# deliberate disposable presenter edit" }
      cli('drift-refusal', 'generate', drift, expected: 1)
      check('adapt:explicit_drift_diagnostic', File.read(File.join(@output, 'drift-refusal.stderr')).include?('GENERATED_DRIFT'))
      save('adaptation.json', 'policy' => 'Synthetic changed contract, not a claim that NovaPay changed its minimum.',
           'before_minor' => 100000, 'after_minor' => 200000, 'source_sha256' => source_before,
           'overlay' => 'adapted-novapay/overlays/999-user.yaml')
    end

    def mutation
      before = hashes(File.join(project('novapay'), 'generated'))
      command('mutant-summary', [RbConfig.ruby, '-Isrc/lib', 'examples/showcase/mutation.rb', project('novapay'), @output])
      cli('fixed-replay', 'fuzz', project('novapay'), '--replay', File.join(@output, 'mutant-trace.json'))
      fixed = read('fixed-replay.json')
      mutant = read('mutant-replay.json')
      check('mutation:identical_profile', fixed['profile_sha256'] == mutant['profile_sha256'])
      check('mutation:identical_trace', fixed['trace'] == mutant['trace'])
      check('mutation:fixed_pass', fixed['success'] == true && fixed['failure'].nil?)
      check('mutation:generated_bytes_unchanged', hashes(File.join(project('novapay'), 'generated')) == before)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    PaygenShowcase::Runner.new(ARGV[0]).run
  rescue StandardError, Interrupt => error
    warn "showcase: #{error.class}: #{error.message}"
    exit 1
  end
end
