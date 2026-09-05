# frozen_string_literal: true
require 'tmpdir'
require_relative 'runtime/simulator'

module Paygen
  # An executable client of the local generated-adapter application. Provider
  # URLs and arbitrary OpenAPI names never become Bruno URLs or JavaScript.
  class Collection
    BRUNO_VERSION = '4.1.0'

    def initialize(project)
      @project = project.is_a?(Project) ? project : Project.new(project)
    end

    def export(output:, format: 'bruno')
      raise Error, 'Collection format must be bruno' unless format == 'bruno'

      @project.transaction do
        generator = Generator.new(@project)
        raise Error.new('Regenerate before exporting a collection', code: 'GENERATED_DRIFT', exit_code: 1) unless generator.diff.empty?

        rendered = generator.render(draft: @project.lock.fetch('draft', false), overrides: @project.lock.fetch('overrides', {}))
        config = JSON.parse(rendered.fetch('config.json'))
        raise Error.new('A diagnostic draft cannot run an adapter demo', code: 'SEMANTIC_BLOCKERS', exit_code: 4) if config['draft']

        destination = destination_path(output)
        files = collection_files(config).merge('fixtures.json' => rendered.fetch('fixtures.json'))
        FileUtils.mkdir_p(File.dirname(destination))
        # Rename a complete sibling directory so failures leave no partial bundle.
        staging = Dir.mktmpdir('.paygen-collection-', File.dirname(destination))
        begin
          files.each do |name, body|
            target = File.join(staging, name)
            FileUtils.mkdir_p(File.dirname(target))
            File.write(target, body)
          end
          raise Error, 'Collection destination already exists' if File.exist?(destination) || File.symlink?(destination)

          File.rename(staging, destination)
        ensure
          FileUtils.rm_rf(staging)
        end
        { 'status' => 'exported', 'format' => format, 'path' => destination, 'files' => files.keys.sort }
      end
    end

    private

    def destination_path(output)
      destination = File.expand_path(output)
      raise Error, 'Collection destination already exists' if File.exist?(destination) || File.symlink?(destination)

      ancestor = File.dirname(destination)
      ancestor = File.dirname(ancestor) until File.exist?(ancestor) || File.symlink?(ancestor)
      resolved = File.join(File.realpath(ancestor), Pathname.new(destination).relative_path_from(Pathname.new(ancestor)).to_s)
      root = File.realpath(@project.root)
      if resolved == root || resolved.start_with?(root + '/')
        raise Error, 'Collection destination cannot be inside the project'
      end
      destination
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise Error, 'Collection destination has an invalid parent'
    end

    def collection_files(config)
      @files = {}
      @sequence = 0
      @config = config
      simulator = Runtime::Simulator.new(config: config)
      @sample = simulator.sample_operation(id: 'bruno-operation')
      @callbacks = config.fetch('endpoints').key?('callback') && %w[hmac-sha256 stripe-v1].include?(config.dig('callback', 'signature', 'algorithm'))
      @cancel = config.fetch('endpoints').key?('cancel')
      @authenticated = config.dig('auth', 'type') && config.dig('auth', 'type') != 'none'

      request('Health', 'get', '/health', pre: <<~JS, tests: <<~JS)
        bru.setVar("operationId", "pg" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8));
      JS
        test("The local generated adapter demo is running", function () {
          expect(res.getStatus()).to.equal(200);
          expect(res.getBody().service).to.equal("paygen-adapter-demo");
          expect(res.getBody().offline).to.equal(true);
        });
      JS
      request('Initial evidence', 'get', '/evidence', tests: <<~JS)
        test("Capture the baseline for a repeatable run", function () {
          expect(res.getStatus()).to.equal(200);
          expect(res.getBody().created_count).to.be.a("number");
          expect(res.getBody().backend_events).to.be.an("array");
          bru.setVar("initialCreatedCount", res.getBody().created_count);
          bru.setVar("initialBackendEvents", res.getBody().backend_events.length);
        });
      JS
      request('Create operation', 'post', '/operations', pre: operation_body, tests: success_test + <<~JS)
        test("Capture the provider operation identity", function () {
          expect(res.getBody().provider_id).to.be.a("string").and.not.equal("");
          bru.setVar("providerId", res.getBody().provider_id);
        });
      JS
      request('Retry same operation', 'post', '/operations/{{operationId}}/retry', tests: success_test + <<~JS)
        test("Retry preserves the provider operation identity", function () {
          expect(res.getBody().provider_id).to.equal(bru.getVar("providerId"));
        });
      JS
      if @cancel
        request('Create operation for cancellation', 'post', '/operations', pre: operation_body(suffix: '-c'), tests: success_test)
        request('Cancel before settlement', 'post', '/operations/{{operationId}}-c/cancel', tests: success_test + <<~JS)
          test("Cancellation rejects the pending operation", function () {
            expect(res.getBody().status).to.equal("rejected");
          });
        JS
      end
      add_status_requests if config.fetch('endpoints').key?('status')
      add_callback_requests if @callbacks
      if @authenticated
        request('Reject invalid provider credentials', 'post', '/checks/invalid-auth', pre: operation_body(suffix: '-a'), tests: <<~JS)
          test("The generated adapter reaches strict provider authentication", function () {
            expect(res.getStatus()).to.equal(422);
            expect(res.getBody().success).to.equal(false);
            expect(res.getBody().error.http_status).to.equal(401);
          });
        JS
      end
      request('Final evidence', 'get', '/evidence', tests: <<~JS)
        test("Retry and rejected requests create no extra provider operation", function () {
          expect(res.getStatus()).to.equal(200);
          expect(res.getBody().created_count - bru.getVar("initialCreatedCount")).to.equal(#{@cancel ? 2 : 1});
        });
        test("Backend callback effects match the configured capability", function () {
          expect(res.getBody().backend_events.length - bru.getVar("initialBackendEvents")).to.equal(#{@callbacks && %w[approved rejected].include?(final_status) ? 1 : 0});
        });
      JS
      @files.merge(
        'bruno.json' => Paygen.json({ 'version' => '1', 'name' => 'Paygen local adapter verification', 'type' => 'collection', 'ignore' => ['node_modules', '.git'] }),
        'environments/local.bru' => "vars {\n  baseUrl: http://127.0.0.1:9293\n}\n",
        'collection.bru' => collection_guard,
        'README.md' => readme,
        'paygen-collection.json' => Paygen.json({ 'format' => 'bruno', 'bruno_cli_version' => BRUNO_VERSION,
          'config_sha256' => Digest::SHA256.hexdigest(Paygen.json(config)), 'callback_checks' => @callbacks,
          'callback_algorithm' => config.dig('callback', 'signature', 'algorithm'),
          'authentication_check' => !!@authenticated, 'cancellation_check' => @cancel,
          'target' => 'generated-adapter-demo', 'scenario' => 'success' })
      )
    end

    def add_status_requests
      states = Array(@config.dig('simulator', 'scenarios', 'success', 'statuses'))
      count = [states.length, 1].max
      raise Error, 'Collection success scenario is too long' if count > 100

      count.times do |index|
        expected = index == count - 1 ? final_status : canonical_status(states[index])
        request("Read status #{index + 1}", 'get', '/operations/{{operationId}}', tests: success_test + <<~JS)
          test("Status polling preserves identity and the configured state", function () {
            expect(res.getBody().provider_id).to.equal(bru.getVar("providerId"));
            expect(res.getBody().status).to.equal(#{js_value(expected)});
          });
        JS
      end
    end

    def final_status
      states = Array(@config.dig('simulator', 'scenarios', 'success', 'statuses'))
      return canonical_status(states.last) unless states.empty?

      @config.fetch('status_mapping', {}).values.any? { |value| (value.is_a?(Hash) ? value['status'] : value) == 'approved' } ? 'approved' : 'in_progress'
    end

    def canonical_status(state)
      value = @config.fetch('status_mapping', {})[state]
      value.is_a?(Hash) ? value.fetch('status', 'unknown') : value || 'unknown'
    end

    def add_callback_requests
      request('Obtain signed local callback', 'get', '/events/{{operationId}}', tests: <<~JS)
        test("The simulator provides exact callback bytes and signature headers", function () {
          expect(res.getStatus()).to.equal(200);
          const events = res.getBody().events;
          expect(events).to.be.an("array").and.not.be.empty;
          const event = events[events.length - 1];
          expect(event.raw_body).to.be.a("string");
          expect(event.headers).to.be.an("object");
          expect(Object.keys(event.headers).length).to.be.greaterThan(0);
          bru.setVar("callbackEvent", JSON.stringify(event));
        });
      JS
      request('Reject invalid callback signature', 'post', '/callbacks', pre: callback_body(invalid: true), raw: true, tests: <<~JS)
        test("Invalid signatures cannot approve an operation", function () {
          expect(res.getStatus()).to.equal(422);
          expect(res.getBody().success).to.equal(false);
          expect(res.getBody().error.code).to.equal("invalid_signature");
        });
      JS
      request('Apply signed callback', 'post', '/callbacks', pre: callback_body, raw: true, tests: success_test + <<~JS)
        test("The signed callback settles the expected provider operation", function () {
          expect(res.getBody().provider_id).to.equal(bru.getVar("providerId"));
          expect(res.getBody().status).to.equal(#{js_value(final_status)});
        });
      JS
      request('Ignore duplicate callback', 'post', '/callbacks', pre: callback_body, raw: true, tests: success_test + <<~JS)
        test("A repeated delivery has no second backend effect", function () {
          expect(res.getBody().ignored).to.equal("duplicate");
          expect(res.getBody().status).to.equal(#{js_value(final_status)});
        });
      JS
    end

    def operation_body(suffix: '')
      <<~JS
        const operation = #{js_value(@sample)};
        operation.id = bru.getVar("operationId") + #{js_value(suffix)};
        req.setBody(operation);
      JS
    end

    def callback_body(invalid: false)
      <<~JS
        const event = JSON.parse(bru.getVar("callbackEvent"));
        if (typeof event.raw_body !== "string" || event.raw_body.length > 1048576) throw new Error("Invalid local callback bytes");
        req.setBody(event.raw_body);
        Object.keys(event.headers).forEach(function (name) {
          if (!/^[A-Za-z0-9-]+$/.test(name) || /^(host|content-length|content-type|authorization|cookie)$/i.test(name)) throw new Error("Invalid callback header name");
          const value = String(event.headers[name]);
          if (/[\\r\\n]/.test(value)) throw new Error("Invalid callback header value");
          req.setHeader(name, #{invalid ? '"intentionally-invalid"' : 'value'});
        });
      JS
    end

    def success_test
      <<~JS
        test("The adapter returns a successful result", function () {
          expect(res.getStatus()).to.equal(200);
          expect(res.getBody().success).to.equal(true);
        });
      JS
    end

    def request(name, method, path, pre: nil, tests:, raw: false)
      @sequence += 1
      body = method == 'post' ? (raw ? 'text' : 'json') : 'none'
      blocks = ["meta {\n  name: #{name}\n  type: http\n  seq: #{@sequence}\n}",
                "#{method} {\n  url: {{baseUrl}}#{path}\n  body: #{body}\n  auth: none\n}"]
      if method == 'post'
        blocks << "headers {\n  Content-Type: application/json\n}"
        blocks << "body:#{body} {\n  {}\n}"
      end
      blocks << "script:pre-request {\n#{indent(pre)}}" if pre
      blocks << "tests {\n#{indent(tests)}}"
      filename = format('%02d-%s.bru', @sequence, name.downcase.tr(' ', '-'))
      @files[filename] = blocks.join("\n\n") + "\n"
    end

    def indent(value)
      value.lines.map { |line| '  ' + line }.join
    end

    # Encode all template delimiters inside JSON data. Untrusted schema examples
    # must remain values even when Bruno interpolates variables before scripts.
    def js_value(value)
      encoded = JSON.generate(JSON.generate(value, ascii_only: true), ascii_only: true)
      encoded = encoded.gsub('{', '\\u007b').gsub('}', '\\u007d').gsub('<', '\\u003c').gsub('>', '\\u003e')
      "JSON.parse(#{encoded})"
    end

    def collection_guard
      <<~'BRU'
        script:pre-request {
          const baseUrl = bru.getEnvVar("baseUrl");
          const match = /^http:\/\/127\.0\.0\.1:([0-9]{1,5})$/.exec(baseUrl || "");
          if (!match || Number(match[1]) < 1 || Number(match[1]) > 65535) throw new Error("This collection requires the local Paygen adapter demo");
          const operationId = bru.getVar("operationId");
          if (operationId !== undefined && !/^[A-Za-z0-9_-]{1,100}$/.test(operationId)) throw new Error("Invalid local operation identity");
        }
      BRU
    end

    def readme
      <<~MARKDOWN
        # Local generated-adapter verification

        This collection calls `paygen demo PROJECT`, which invokes the generated Ruby
        adapter, its strict provider simulator, and the reference backend callback hooks.
        All provider credentials and webhook keys are synthetic and held by the demo.
        No bank connection, real payment, or external callback verification is performed.

        ## Run

        Start the demo with the generated project in another terminal:

        ```sh
        paygen demo PROJECT --port 9293
        ```

        From this collection directory, use Bruno CLI #{BRUNO_VERSION}:

        ```sh
        bru run --env local --noproxy --bail --reporter-json results.json --reporter-junit results.xml
        ```

        The repository pins the tested CLI and audited dependency overrides in
        `tools/bruno`; its README explains installation and the regression runner.
        Generation needs only Ruby; Bruno is required to execute the collection. You
        can also open this directory in the Bruno application and run the collection
        in sequence with the `local` environment. These are supported classic `.bru`
        files. Bruno also supports OpenCollection YAML; this exporter explicitly emits
        `.bru`. Set `baseUrl` to `http://127.0.0.1:PORT` if using another local port.
        The collection rejects non-loopback targets and requires the default `success`
        scenario. Run it sequentially, without `--parallel`. Each run gets fresh IDs;
        the demo has bounded in-memory capacity and resets when restarted.

        ## Evidence and scope

        The requests verify create, a safe retry, configured status polling#{@cancel ? ', and cancellation of a separate pending operation' : ''}.
        Final evidence checks that retry and rejected requests created no extra provider
        operations. #{ @authenticated ? 'Bad provider credentials must fail with HTTP 401 inside the adapter result.' : 'This profile has no provider authentication, so an invalid-credentials check is omitted.' }

        #{ @callbacks ? 'Signed callbacks use exact raw bytes and headers obtained from the local simulator. The collection rejects an invalid signature, applies one valid terminal delivery, then confirms that its duplicate has no second backend effect.' : 'Callback checks are omitted because this profile has no supported local HMAC or Stripe signature configuration. Provider-side verification hooks require a separate application implementation; this collection does not claim to test them.' }

        `fixtures.json` is the matching generated fixture bundle. `paygen-collection.json`
        records the effective configuration hash, selected checks, and tested Bruno CLI
        version. These checks demonstrate adapter behavior against its configured local
        contract; independent official examples and provider sandbox tests are still
        needed to establish that the profile describes the real bank correctly.

        Format and execution references: [Bruno language](https://docs.usebruno.com/bru-lang/overview),
        [CLI options](https://docs.usebruno.com/bru-cli/commandOptions), and
        [request chaining](https://docs.usebruno.com/testing/script/request-chaining).
      MARKDOWN
    end
  end
end
