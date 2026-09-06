# frozen_string_literal: true

require 'cgi'
require 'openssl'
require 'base64'
require 'time'

module Paygen
  # All renderers consume the same reviewed IR. Examples are evidence with an
  # origin and a validation result, never an assertion of provider acceptance.
  class Documentation
    FIXTURE_TIME = 1_800_000_000

    def initialize(ir, example_builder:)
      @ir, @example_builder = ir, example_builder
      @config = ir.config
    end

    def markdown
      lines = ["# #{cell(@ir.document.dig('info', 'title'))} integration", '',
               'Generated from the pinned OpenAPI contract, ordered overlays and integration.yml.', '',
               '## Setup', '',
               'Supply credentials through your application secret store at runtime. No production credentials are generated.',
               'Load your Provider::BaseService before loading the generated service. The runtime is supplied by the Paygen gem or detached export.', '',
               '```ruby', "require './#{@config.fetch('provider')}_service'",
               "service = Provider::#{@config.fetch('class_name')}.new",
               'service.configure_paygen(', '  credentials: {']
      credential_names.each { |name| lines << "    #{name.dump} => ENV.fetch(#{environment_name(name).dump})," }
      lines += ['  },', "  mode: #{@config.fetch('mode', 'sandbox').dump}", ')', '```', '',
                'Use your BaseService constructor arguments where required. The default transport performs HTTPS requests to the configured provider; run the simulator or demo explicitly for offline tests.',
                'Object operations may expose provider_operation_id; legacy provider_id and provider_payment_id remain accepted. BaseService.check_conditions failures are returned before provider HTTP requests.', '',
                'Hash operations support the mapped fields directly. For model objects, explicitly permit additional trusted attribute roots (for example metadata) with configure_paygen(allowed_attributes: ["metadata"]). Profiles cannot grant method access.', '',
                '## Operations', '', '| Role | Method | URL template | Operation ID |', '| --- | --- | --- | --- |']
      @config.fetch('endpoints').each do |role, op|
        servers = Array(op['servers'])
        urls = if role == 'callback' || op['inbound']
                 ["application receiver: #{op['path']}"]
               elsif servers.empty?
                 [op['path']]
               else
                 servers.map { |server| "#{server_url(server).sub(%r{/$}, '')}#{op['path']}" }
               end
        urls.each { |url| lines << row(role, op['method'], url, op['operation_id']) }
      end
      lines += ['', 'Server variables use their declared defaults. Callback paths describe inbound contracts; your application chooses its own public receiver URL.', '',
                '## Authentication', '', *authentication_lines,
                '', '## Request mappings and parameters', '',
                'Mappings below are explicit reviewed profile facts. Required path, query and header parameters are validated before transport.', '',
                '```json', Paygen.json(@config.slice('request_encoding', 'request_mapping', 'parameter_mapping')).rstrip, '```', '',
                '## Amounts', '', "Input unit: #{cell(@config.dig('amount', 'input_unit') || 'major')}. Scale: #{cell(@config.dig('amount', 'scale'))}.",
                "Allowed currencies: #{cell(Array(@config.dig('amount', 'currencies')).join(', '))}.",
                "Minimum provider units: #{cell(@config.dig('amount', 'minimum'))}; maximum: #{cell(@config.dig('amount', 'maximum') || 'not declared')}.",
                'Use decimal strings or integers for monetary input. Floating point money is rejected.', '',
                '## Response correlation', '',
                'Response schema validity alone does not bind a response to this operation. The following optional profile rules explicitly bind response fields to operation fields before state mutation:', '',
                '```json', Paygen.json(@config.fetch('response_bindings', {})).rstrip, '```', '',
                'No rules means no additional correlation claim. A configured required field must be present and match; optional fields are ignored only when absent or null. Present mismatches fail closed. A mismatched create response requires reconciliation, not a blind retry.', '',
                '## Status mapping', '', '| Provider status | Canonical status |', '| --- | --- |']
      @config.fetch('status_mapping', {}).each { |provider, state| lines << row(provider, state.is_a?(Hash) ? state['status'] : state) }
      lines += ['', 'Unknown statuses do not approve operations. Batch success does not imply every item succeeded.', '',
                '## Idempotency and recovery', '',
                '```json', Paygen.json(@config.fetch('idempotency', {})).rstrip, '```', '',
                'Keep the same operation identity after timeouts. A timeout may mean the provider committed the operation. Reconcile status before deciding whether another create request is safe.',
                'The reconcile_before_retry strategy with no header does not claim provider-side deduplication: known successes are cached locally and ambiguous creates require reconciliation.',
                'The default state store is process-local. Supply a durable synchronized state store and coordinate workers before relying on recovery across restarts.', '',
                'An explicitly supplied state_store requires a stable state_namespace or account. Without one, execution and callbacks return state_namespace_required before effects. Keep the same namespace across credential rotation; use distinct namespaces for distinct merchant accounts.',
                'Known legacy state keys return state_migration_required. Quiesce old writers, reconcile uncertain payments, and migrate reviewed state before resuming. Never clear the store or change the namespace to bypass a reservation.', '',
                '## Webhooks', '', *callback_lines, '',
                '## Errors', '', '| Scope | HTTP | Classification | Action |', '| --- | --- | --- | --- |']
      errors = @config.fetch('errors', {})
      errors.reject { |key, _| key == 'roles' }.each { |code, rule| lines << error_row('all roles', code, rule) }
      errors.fetch('roles', {}).each do |role, rules|
        rules.each { |code, rule| lines << error_row(role, code, rule) }
      end
      lines += ['', 'Role-specific rules override the shared rule for that HTTP status.', '', *gateway_lines,
                '## Fixtures and local documentation', '',
                'fixtures.json retains all inline named request and response examples, plus separate synthesized candidates. source_pointer and origin identify the source of each case.',
                'External examples are listed by URL and are not fetched. schema_validation checks only the declared selected schema; it does not prove business validity or provider acceptance.',
                "Signed callback fixtures use public test credentials only and a fixed clock of #{FIXTURE_TIME} Unix seconds. Keep raw_body byte-for-byte; parsing and reserializing changes a signature.",
                'callback.cases are independent deliveries. adapter_validation records an actual offline run using a fresh adapter and its adapter_context (account, mode and clock); expected_adapter_result records that outcome. mapped_operation_status separately records the profile mapping. Replays and transition ordering require separate scenario tests.',
                'effective-openapi.json contains the full effective graph, including unselected operations and preserved local references. It describes the provider API, not the adapter demo HTTP API.',
                'Use paygen docs PROJECT --format html --output DIR for a local HTML bundle, or --format md for Markdown. Publication and access control belong to the owner of the integration.', '',
                '## Extensions and backend callback seam', '',
                'User-owned Ruby files live in extensions/. Load them explicitly after the generated service. YAML does not execute Ruby.',
                'Hooks: paygen_validate, paygen_request, paygen_response, paygen_status, paygen_verify_callback, paygen_callback_result, paygen_classify_error and paygen_retry_decision.',
                'The default callback result is returned without backend mutations. To use BaseService approve_operation(provider_id) and reject_operation(provider_id, error_code), explicitly opt in after checking your application contract:', '',
                '```ruby', "class Provider::#{@config.fetch('class_name')}", '  def paygen_callback_result(result, payload)',
                '    paygen_backend_callback_result(result, payload)', '  end', 'end', '```', '',
                'This seam runs after signature, identity, replay and transition checks, inside state_store.synchronize before the replay state is committed. Do not recursively call adapter operations using the same non-reentrant store from this hook.',
                'Your backend must make the mutation durable and idempotent; a generated adapter cannot infer its database transaction contract.', '',
                '## Provenance', '', 'provenance.json records the winning semantic source; config.json contains the effective configuration and diagnostics.json lists remaining issues.', '']
      lines.join("\n")
    end

    def fixtures
      semantic_request = semantic_create_request
      result = @config.fetch('endpoints').to_h do |role, operation|
        pointer = operation.fetch('source_pointer', '')
        media = operation.fetch('content_type', 'application/json')
        contents = operation.fetch('request_content', { media => operation.fetch('request_examples', {}) })
        request_examples = contents.flat_map do |content_type, content|
          examples(content, "#{pointer}/requestBody/content/#{pointer_token(content_type)}", content_type)
        end
        primary = request_examples.find { |item| item['content_type'] == media && item.key?('value') }
        unless primary
          value = role == 'create' && semantic_request ? semantic_request : @example_builder.call(operation.fetch('request_schema', {}))
          primary = candidate('synthesized', value, role == 'create' && semantic_request ? 'profile-mapping' : 'schema-synthesis', pointer, operation.fetch('request_schema', {}), media)
          request_examples << primary
        end
        responses = operation.fetch('responses', {}).to_h do |status, response|
          cases = response.fetch('content', {}).flat_map do |content_type, content|
            location = "#{pointer}/responses/#{pointer_token(status)}/content/#{pointer_token(content_type)}"
            found = examples(content, location, content_type)
            if found.empty?
              found << candidate('synthesized', @example_builder.call(content.fetch('schema', {})), 'schema-synthesis', location, content.fetch('schema', {}), content_type)
            end
            found
          end
          [status, cases]
        end
        entry = { 'request' => primary['value'], 'request_examples' => request_examples, 'response_examples' => responses }
        responses.each { |status, cases| entry["response_#{status}"] = cases.find { |item| item.key?('value') }&.fetch('value') }
        entry['cases'] = callback_cases(request_examples, operation) if role == 'callback'
        [role, entry]
      end
      if result['callback']
        result['callback']['fixture_credentials'] = callback_credentials
        result['callback']['fixture_clock_unix'] = FIXTURE_TIME
        result['callback']['independent_cases'] = true
      end
      result
    end

    # A deliberately small renderer: source HTML, Markdown links and code are
    # always escaped. No network resources, scripts or embedded source URLs run.
    def self.html(markdown)
      blocks = []
      fenced = false
      code = []
      table = []
      flush_table = lambda do
        unless table.empty?
          rows = table.reject { |line| line.match?(/\A\|[\s:|\-]+\|\z/) }.map do |line|
            line.sub(/\A\|/, '').sub(/\|\z/, '').split(/(?<!\\)\|/).map { |value| CGI.escapeHTML(CGI.unescapeHTML(value.strip.gsub('\\|', '|'))) }
          end
          header = rows.shift || []
          blocks << "<table><thead><tr>#{header.map { |value| "<th>#{value}</th>" }.join}</tr></thead><tbody>#{rows.map { |values| "<tr>#{values.map { |value| "<td>#{value}</td>" }.join}</tr>" }.join}</tbody></table>"
          table.clear
        end
      end
      markdown.each_line do |line|
        text = line.chomp
        if !fenced && text.start_with?('|')
          table << text
          next
        end
        flush_table.call
        if text.start_with?('```')
          if fenced
            blocks << "<pre><code>#{CGI.escapeHTML(code.join("\n"))}</code></pre>"
            code = []
          end
          fenced = !fenced
        elsif fenced
          code << text
        elsif (heading = text.match(/\A(\#{1,6}) (.*)\z/))
          level = heading[1].size
          blocks << "<h#{level}>#{CGI.escapeHTML(CGI.unescapeHTML(heading[2]))}</h#{level}>"
        elsif !text.empty?
          blocks << "<p>#{CGI.escapeHTML(CGI.unescapeHTML(text))}</p>"
        end
      end
      flush_table.call
      blocks << "<pre><code>#{CGI.escapeHTML(code.join("\n"))}</code></pre>" if fenced
      <<~HTML
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'">
        <title>Generated integration guide</title>
        <style>body{font:16px/1.6 system-ui,sans-serif;max-width:1000px;margin:3rem auto;padding:0 1.5rem;color:#182335;background:#fff}h1,h2{line-height:1.2}h2{margin-top:2.5rem}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f1f5f9;padding:.7rem 1rem;border-radius:.3rem}code{font-family:ui-monospace,monospace}a{color:#145bb8}table{width:100%;border-collapse:collapse;overflow-wrap:anywhere}th,td{text-align:left;vertical-align:top;padding:.5rem;border-bottom:1px solid #dbe1ea}th{background:#f1f5f9}nav{display:flex;gap:1rem;flex-wrap:wrap}</style></head>
        <body><nav aria-label="Bundle files"><a href="INTEGRATION.md">Markdown</a><a href="effective-openapi.json">Effective OpenAPI</a><a href="fixtures.json">Fixtures</a><a href="config.json">Configuration</a><a href="provenance.json">Provenance</a></nav><main>#{blocks.join("\n")}</main></body></html>
      HTML
    end

    private

    def cell(value) = CGI.escapeHTML(value.to_s).gsub('|', '\\|').gsub('`', '\\`').gsub(/[\r\n]/, ' ')
    def row(*values) = "| #{values.map { |value| cell(value) }.join(' | ')} |"
    def pointer_token(value) = value.to_s.gsub('~', '~0').gsub('/', '~1')
    def environment_name(name) = "PAYGEN_#{name.to_s.upcase.gsub(/[^A-Z0-9_]/, '_')}"

    def credential_names
      auth = @config.fetch('auth', {})
      names = if auth['type'] == 'basic'
                [auth.fetch('username', 'username'), auth.fetch('password', 'password')]
              elsif auth['type'] && auth['type'] != 'none'
                [auth.fetch('credential', auth['type'] == 'apiKey' ? 'api_key' : 'access_token')]
              else
                []
              end
      auth.fetch('headers', {}).each_value { |rule| names << (rule.is_a?(Hash) ? rule['credential'] : rule) }
      @config.fetch('parameter_mapping', {}).each_value do |role|
        role.each_value do |location|
          next unless location.is_a?(Hash)
          location.each_value { |rule| names << rule['credential'] if rule.is_a?(Hash) }
        end
      end
      names.concat(callback_credentials.keys).compact.uniq.sort
    end

    def authentication_lines
      auth = @config.fetch('auth', {})
      type = auth.fetch('type', 'none')
      lines = ["Authentication type: #{cell(type)}.", '', '| Location | Name | Runtime credential or constant |', '| --- | --- | --- |']
      case type
      when 'apiKey' then lines << row(auth.fetch('in', 'header'), auth.fetch('name', 'X-API-Key'), "credential: #{auth.fetch('credential', 'api_key')}")
      when 'basic' then lines << row('header', 'Authorization', "Basic base64(#{auth.fetch('username', 'username')}:#{auth.fetch('password', 'password')})")
      when 'bearer', 'oauth2', 'OAuth2' then lines << row('header', 'Authorization', "Bearer <#{auth.fetch('credential', 'access_token')}>")
      end
      auth.fetch('headers', {}).each do |header, rule|
        value = rule.is_a?(Hash) ? (rule.key?('value') ? "constant: #{rule['value']}" : "credential: #{rule['credential']}") : "credential: #{rule}"
        lines << row('header', header, value)
      end
      if type.downcase == 'oauth2'
        lines += ['', "Required scopes: #{cell(Array(auth['scopes']).join(', '))}.",
                  'An injected token_provider receives scopes: and account:. Obtain and refresh access tokens through your application authorization flow.']
        @ir.document.dig('components', 'securitySchemes')&.each_value do |scheme|
          scheme.fetch('flows', {}).each do |flow, data|
            %w[authorizationUrl tokenUrl refreshUrl].each { |key| lines << "#{cell(flow)} #{cell(key)}: #{cell(data[key])}." if data[key] }
          end
        end
      end
      lines
    end

    def callback_lines
      callback = @config.fetch('callback', {})
      return ['No callback operation is selected. Polling or an application callback contract must be reviewed separately.'] unless @config.dig('endpoints', 'callback')
      signature = callback.fetch('signature', {})
      lines = ['Pass the exact received bytes as raw_body together with the received headers to process_callback(payload, raw_body:, headers:).',
               "Algorithm: #{cell(signature['algorithm'])}; header: #{cell(signature.fetch('header', 'X-Signature'))}; digest encoding: #{cell(signature.fetch('encoding', 'hex'))}; key encoding: #{cell(signature.fetch('key_encoding', 'raw'))}.",
               "Rotation credential names: #{cell(callback_credentials.keys.join(', '))}."]
      case signature['algorithm']
      when 'hmac-sha256'
        prefix = signature.fetch('prefix', '')
        expression = 'encoded HMAC-SHA256(secret, raw_body)'
        expression = "#{cell(prefix)} + #{expression}" unless prefix.empty?
        lines << "Signed input: raw request bytes. Header value: #{expression}."
      when 'stripe-v1'
        lines << "Signed input: ASCII(timestamp) + '.' + raw request bytes. Header shape: t=timestamp,v1=digest. Timestamp tolerance: #{cell(signature.fetch('tolerance', 300))} seconds."
      when 'provider_verification'
        lines << 'Verification requires an explicit paygen_verify_callback(payload, raw_body:, headers:) extension. The default rejects every callback. Generated fixtures contain no fabricated provider verification evidence.'
      end
      lines += ['', 'Identity, event mapping and ordering:', '', '```json', Paygen.json(callback.reject { |key, _| key == 'signature' }).rstrip, '```']
      lines
    end

    def gateway_lines
      gateway = @config['gateway'] || @config['provider_gateway']
      return ['## Backend gateway', '', 'No gateway configuration is declared in the profile. Configure your backend gateway explicitly; Paygen does not infer its class or routing names.', ''] unless gateway
      ['## Backend gateway', '', 'Explicit profile gateway configuration (review against your backend constructor):', '', '```json', Paygen.json(gateway).rstrip, '```', '']
    end

    def error_row(scope, code, rule)
      row(scope, code, rule.is_a?(Hash) ? rule['code'] : rule, rule.is_a?(Hash) ? rule['action'] : '')
    end

    def server_url(server)
      return server.to_s unless server.is_a?(Hash)
      server.fetch('url', '').gsub(/\{([^{}]+)\}/) { |token| server.dig('variables', Regexp.last_match(1), 'default')&.to_s || token }
    end

    def semantic_create_request
      return nil if @ir.diagnostics.any? { |item| item['severity'] == 'blocker' }
      require_relative 'runtime/adapter'
      require_relative 'runtime/simulator'
      simulator = Runtime::Simulator.new(config: @config, seed: 0)
      adapter = fixture_adapter.configure_paygen(credentials: simulator.credentials, transport: simulator)
      adapter.send(:build_body, simulator.sample_operation(id: 'fixture-operation'), 'create')
    end

    def fixture_adapter
      require_relative 'runtime/adapter'
      config = @config
      @fixture_class ||= Class.new do
        const_set(:PAYGEN_CONFIG, config)
        include Runtime::Adapter
      end
      @fixture_class.new
    end

    def examples(content, pointer, media)
      schema = content.fetch('schema', {})
      values = []
      values << candidate('example', content['example'], 'openapi-example', "#{pointer}/example", schema, media) if content.key?('example')
      content.fetch('examples', {}).each do |name, example|
        location = "#{pointer}/examples/#{pointer_token(name)}"
        if example.key?('value')
          values << candidate(name, example['value'], 'openapi-example', location, schema, media)
        else
          values << { 'name' => name, 'origin' => 'openapi-external-example', 'source_pointer' => location,
                      'external_value' => example['externalValue'], 'available' => false, 'content_type' => media }
        end
      end
      values
    end

    def candidate(name, value, origin, pointer, schema, media)
      { 'name' => name, 'value' => value, 'origin' => origin, 'source_pointer' => pointer,
        'content_type' => media, 'schema_validation' => schema_validation(schema, value),
        'provider_acceptance_verified' => false }
    end

    def schema_validation(schema, value)
      return { 'checked' => false, 'reason' => 'no schema declared' } if schema.is_a?(Hash) && schema.empty?
      require 'json_schemer'
      normalized = fixture_adapter.send(:validation_schema, schema)
      issues = JSONSchemer.schema(normalized).validate(value).first(20)
      { 'checked' => true, 'valid' => issues.empty?, 'errors' => issues.map { |item| item.slice('data_pointer', 'schema_pointer', 'type') } }
    rescue StandardError => e
      { 'checked' => false, 'reason' => "schema checker: #{e.class.name}" }
    end

    def callback_credentials
      signature = @config.dig('callback', 'signature') || {}
      return {} unless %w[hmac-sha256 stripe-v1].include?(signature['algorithm'])
      value = signature['key_encoding'] == 'hex' ? 'ab' * 32 : 'paygen-public-fixture-secret'
      Array(signature.fetch('credentials', [signature.fetch('credential', 'callback_secret')])).to_h { |name| [name, value] }
    end

    def callback_cases(source_examples, operation)
      cases = source_examples.select { |item| item['value'].is_a?(Hash) }.map do |example|
        callback_case(example['name'], example['value'], example['origin'], example['source_pointer'], operation)
      end
      represented = cases.map { |item| item['expected_operation_status'] }
      %w[approved rejected].each do |canonical|
        next if represented.include?(canonical)
        status = @config.fetch('status_mapping', {}).find { |_external, mapped| (mapped.is_a?(Hash) ? mapped['status'] : mapped) == canonical }&.first
        next unless status
        payload = JSON.parse(JSON.generate(cases.first&.fetch('payload') || @example_builder.call(operation.fetch('request_schema', {})) || {}))
        next unless payload.is_a?(Hash)
        callback = @config.fetch('callback', {})
        write_path(payload, callback.fetch('id', 'id'), "fixture-#{canonical}")
        write_path(payload, callback.fetch('status', 'status'), status)
        event = callback.fetch('events', {}).find { |_name, value| value == status }&.first
        event ||= callback.fetch('events', {}).find { |_name, value| value.nil? }&.first
        write_path(payload, callback['event'], event) if event && callback['event']
        write_path(payload, callback['event_id'], "fixture-event-#{canonical}") if callback['event_id']
        write_path(payload, callback['mode_field'], callback.fetch('mode_values', {}).fetch(@config.fetch('mode', 'sandbox'), @config.fetch('mode', 'sandbox'))) if callback['mode_field']
        callback.fetch('constraints', {}).each { |path, value| write_path(payload, path, value) }
        cases << callback_case("synthesized_#{canonical}", payload, 'profile-status-synthesis', 'integration.yml#/callback', operation)
      end
      cases
    end

    def callback_case(name, payload, origin, pointer, operation)
      callback = @config.fetch('callback', {})
      status = read_path(payload, callback.fetch('status', 'status'))
      event = read_path(payload, callback.fetch('event', 'event'))
      status ||= callback.fetch('events', {})[event]
      mapped = @config.fetch('status_mapping', {})[status.to_s]
      expected = mapped.is_a?(Hash) ? mapped['status'] : mapped
      raw = JSON.generate(payload)
      signature = callback.fetch('signature', {})
      supported = %w[hmac-sha256 stripe-v1].include?(signature['algorithm'])
      headers = {}
      if supported && callback_credentials.any?
        secret = callback_credentials.values.first
        secret = [secret].pack('H*') if signature['key_encoding'] == 'hex'
        signed = signature['algorithm'] == 'stripe-v1' ? "#{FIXTURE_TIME}.#{raw}" : raw
        digest = OpenSSL::HMAC.digest('SHA256', secret, signed)
        encoded = signature.fetch('encoding', 'hex') == 'base64' ? Base64.strict_encode64(digest) : digest.unpack1('H*')
        value = signature['algorithm'] == 'stripe-v1' ? "t=#{FIXTURE_TIME},v1=#{encoded}" : "#{signature.fetch('prefix', '')}#{encoded}"
        headers[signature.fetch('header', 'X-Signature')] = value
      end
      context = { 'account' => callback['account_field'] ? read_path(payload, callback['account_field']) : nil,
                  'mode' => @config.fetch('mode', 'sandbox'), 'clock_unix' => FIXTURE_TIME }
      adapter = fixture_adapter.configure_paygen(credentials: callback_credentials, account: context['account'],
                                                 mode: context['mode'], clock: -> { Time.at(FIXTURE_TIME) })
      outcome = adapter.process_callback(payload, raw_body: raw, headers: headers)
      { 'name' => name, 'payload' => payload, 'raw_body' => raw, 'headers' => headers,
        'origin' => origin, 'source_pointer' => pointer, 'expected_operation_status' => outcome['status'],
        'mapped_operation_status' => expected || 'unknown', 'expected_adapter_result' => outcome,
        'adapter_validation' => { 'checked' => true, 'success' => outcome['success'] }, 'adapter_context' => context,
        'signature_generated' => !headers.empty?, 'requires_provider_verification' => signature['algorithm'] == 'provider_verification',
        'schema_validation' => schema_validation(operation.fetch('request_schema', {}), payload),
        'provider_acceptance_verified' => false }
    end

    def read_path(value, path)
      path.to_s.delete_prefix('$.').gsub(/\[(\d+)\]/, '.\\1').split('.').reduce(value) do |object, part|
        object.is_a?(Hash) ? object[part] : (object.is_a?(Array) && part.match?(/\A\d+\z/) ? object[part.to_i] : nil)
      end
    end

    def write_path(object, path, value)
      parts = path.to_s.delete_prefix('$.').gsub(/\[(\d+)\]/, '.\\1').split('.')
      cursor = object
      parts.each_with_index do |part, index|
        key = cursor.is_a?(Array) ? Integer(part, 10) : part
        if index == parts.size - 1
          cursor[key] = value
        else
          cursor[key] ||= parts[index + 1].match?(/\A\d+\z/) ? [] : {}
          cursor = cursor[key]
        end
      end
    end
  end
end
