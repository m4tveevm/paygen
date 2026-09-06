# frozen_string_literal: true

require 'json'
require 'digest'
require 'stringio'
require 'uri'
require_relative 'adapter'
require_relative 'simulator'
require_relative 'reference_provider'

module Paygen
  module Runtime
    # Local application boundary: HTTP -> generated adapter -> strict simulator.
    # It never accepts a provider URL or production credentials from a request.
    class Demo
      attr_reader :simulator

      def initialize(source:, config:, scenario: 'success', seed: 0)
        @config = config
        @source_sha256 = Digest::SHA256.hexdigest(source)
        @simulator = Simulator.new(config: config, scenario: scenario, seed: seed, strict_auth: true)
        @service = ReferenceProvider.load_service(source: source, class_name: config.fetch('class_name'))
        @adapter = new_adapter(simulator.credentials)
        @operations = {}
        @backend_events = []
        events = @backend_events
        @adapter.define_singleton_method(:approve_operation) do |id|
          events << { 'provider_id' => id, 'status' => 'approved' }
          { 'success' => true }
        end
        @adapter.define_singleton_method(:reject_operation) do |id, code|
          events << { 'provider_id' => id, 'status' => 'rejected', 'error_code' => code }
          { 'success' => true }
        end
        @adapter.define_singleton_method(:paygen_callback_result) do |result, payload|
          paygen_backend_callback_result(result, payload)
        end
        @mutex = Mutex.new
      end

      def call(env)
        @mutex.synchronize do
          method = env.fetch('REQUEST_METHOD')
          path = env.fetch('PATH_INFO', '/')
          return page if method == 'GET' && path == '/'
          return asset(path) if method == 'GET' && %w[/demo.css /demo.js].include?(path)
          return respond(200, { 'service' => 'paygen-adapter-demo', 'provider' => @config['provider'], 'offline' => true }) if method == 'GET' && path == '/health'
          return respond(200, artifact_summary) if method == 'GET' && path == '/artifacts'
          return respond(200, simulator.sample_operation(id: 'synthetic-demo-operation')) if method == 'GET' && path == '/sample'
          return respond(200, simulator.evidence.merge('backend_events' => @backend_events)) if method == 'GET' && path == '/evidence'
          if method == 'POST'
            return respond(415, { 'error' => 'Use application/json' }) unless env.fetch('CONTENT_TYPE', '').split(';').first == 'application/json'
            raw = env.fetch('rack.input', StringIO.new).read(1_048_577)
            return respond(413, { 'error' => 'payload_too_large' }) if raw.bytesize > 1_048_576
            payload = JSON.parse(raw)
            return respond(400, { 'error' => 'Expected an object' }) unless payload.is_a?(Hash)
            if path == '/callbacks'
              headers = env.filter_map { |key, value| [key.delete_prefix('HTTP_').tr('_', '-'), value] if key.start_with?('HTTP_') }.to_h
              return result_response(@adapter.process_callback(payload, raw_body: raw, headers: headers))
            end
            return create(payload) if path == '/operations'
            if path == '/checks/invalid-auth'
              credentials = simulator.credentials.transform_values { |_value| 'intentionally-invalid' }
              operation = payload.empty? ? simulator.sample_operation(id: 'invalid-auth') : payload
              return result_response(new_adapter(credentials).create_request(operation))
            end
          end
          segments = path.split('/').drop(1).map { |segment| URI.decode_www_form_component(segment) }
          if segments.size == 2 && segments.first == 'events' && method == 'GET'
            entry = @operations[segments.last]
            return respond(404, { 'error' => 'unknown_operation' }) unless entry
            return respond(200, { 'events' => simulator.callback_events(provider_id: entry.dig('result', 'provider_id')) })
          end
          return operation_action(method, segments) if segments.first == 'operations'
          respond(404, { 'error' => 'not_found' })
        end
      rescue JSON::ParserError, ArgumentError
        respond(400, { 'error' => 'invalid_request' })
      end

      private

      def artifact_summary
        {
          'generated_service' => "#{@config.fetch('provider')}_service.rb",
          'generated_service_sha256' => @source_sha256,
          'class_name' => @config.fetch('class_name'),
          'provider' => @config.fetch('provider'),
          'mode' => @config.fetch('mode', 'sandbox'),
          'roles' => @config.fetch('endpoints').keys.sort,
          'callback_verification' => @config.dig('callback', 'signature', 'algorithm'),
          'offline' => true
        }
      end

      def page
        body = File.binread(File.expand_path('demo/index.html', __dir__))
        [200, {
          'content-type' => 'text/html; charset=utf-8',
          'cache-control' => 'no-store',
          'content-security-policy' => "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'"
        }, [body]]
      end

      def asset(path)
        extension = File.extname(path)
        body = File.binread(File.expand_path("demo/#{File.basename(path)}", __dir__))
        type = extension == '.css' ? 'text/css; charset=utf-8' : 'text/javascript; charset=utf-8'
        [200, { 'content-type' => type, 'cache-control' => 'no-store', 'x-content-type-options' => 'nosniff' }, [body]]
      end

      def new_adapter(credentials)
        @service.new(credentials: credentials, transport: simulator, account: 'test-account',
                     mode: @config.fetch('mode', 'sandbox'),
                     clock: -> { Time.at(1_800_000_003) })
      end

      def create(operation)
        id = operation['id']
        return respond(400, { 'error' => 'operation id must be a nonempty string' }) unless id.is_a?(String) && !id.empty? && id.bytesize <= 200
        return respond(409, { 'error' => 'Use the retry route for an existing operation' }) if @operations.key?(id)
        return respond(503, { 'error' => 'demo_capacity' }) if @operations.size >= 1000
        result = @adapter.create_request(operation)
        @operations[id] = { 'operation' => operation, 'result' => result }
        result_response(result)
      end

      def operation_action(method, segments)
        entry = @operations[segments[1]]
        return respond(404, { 'error' => 'unknown_operation' }) unless entry
        operation = entry.fetch('operation').merge(entry.fetch('result').slice('provider_id', 'provider_item_id'))
        if method == 'POST' && segments.size == 3 && segments.last == 'retry'
          result = @adapter.create_request(entry.fetch('operation'))
          entry['result'] = result if result['success']
          return result_response(result)
        end
        role = if method == 'GET' && segments.size == 2
                 'status'
               elsif method == 'POST' && segments.size == 3 && segments.last == 'cancel'
                 'cancel'
               end
        return respond(404, { 'error' => 'not_found' }) unless role
        return respond(501, { 'error' => 'operation_not_configured' }) unless @config.fetch('endpoints').key?(role)
        result = role == 'status' ? @adapter.fetch_status(operation) : @adapter.cancel(operation)
        result_response(result)
      end

      def result_response(result)
        respond(result['success'] ? 200 : 422, result)
      end

      def respond(status, body)
        [status, { 'content-type' => 'application/json', 'cache-control' => 'no-store' }, [JSON.generate(body)]]
      end
    end
  end
end
