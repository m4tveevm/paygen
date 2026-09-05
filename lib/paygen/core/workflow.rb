# frozen_string_literal: true

require 'json'
require 'psych'
require 'json_schemer'
require 'janeway'
require 'strscan'
require 'timeout'
require 'uri'
require_relative '../runtime/security'

module Paygen
  module Core
    # Arazzo 1.1 validation and deterministic HTTP workflow execution. Sources
    # are explicitly supplied, so merely importing a workflow never fetches or
    # executes anything. Unsupported execution dialects fail with a named error.
    class Workflow
      HTTP_METHODS = %w[get put post delete options head patch trace].freeze
      MAX_STEPS = 1_000
      MAX_NESTING = 16
      SCHEMA_PATH = File.expand_path('schemas/arazzo-1.1.json', __dir__)
      attr_reader :document

      def initialize(document, sources: {}, transport: nil, sleeper: nil)
        @document = document
        @sources = sources.transform_keys(&:to_s)
        @transport = transport || Paygen::Runtime::HTTPTransport.new
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      end

      def self.import(path_or_url, **options)
        new(Input.read(path_or_url), **options).tap(&:validate!)
      end

      def export(format: :yaml)
        validate!
        case format.to_s
        when 'json' then JSON.pretty_generate(@document) + "\n"
        when 'yaml', 'yml' then Psych.dump(JSON.parse(JSON.generate(@document)))
        else invalid('ARAZZO_FORMAT', 'Export format must be JSON or YAML')
        end
      end

      def validate!
        invalid('ARAZZO_INVALID', 'Arazzo document must be an object') unless @document.is_a?(Hash)
        unless @document['arazzo'].is_a?(String) && @document['arazzo'].match?(/\A1\.1\.\d+\z/)
          invalid('ARAZZO_VERSION', 'Expected Arazzo 1.1.x')
        end
        schema = JSON.parse(File.read(SCHEMA_PATH))
        errors = Timeout.timeout(10) { JSONSchemer.schema(schema, ref_resolver: method(:schema_reference)).validate(@document).take(50) }
        unless errors.empty?
          raise Error.new('Arazzo document is invalid', code: 'ARAZZO_INVALID', exit_code: 3,
                          details: { 'errors' => errors.map { |e| { 'path' => e['data_pointer'], 'rule' => e['type'] } } })
        end
        unique!(@document.fetch('sourceDescriptions'), 'name')
        unique!(@document.fetch('workflows'), 'workflowId')
        @document.fetch('workflows').each do |workflow|
          unique!(workflow.fetch('steps'), 'stepId')
          validate_parameters!(workflow.fetch('parameters', []))
          workflow.fetch('dependsOn', []).each { |reference| validate_workflow_reference!(reference) }
          %w[successActions failureActions].each { |field| validate_actions!(workflow.fetch(field, []), workflow) }
          workflow['steps'].each do |step|
            validate_parameters!(step.fetch('parameters', []))
            step.fetch('dependsOn', []).each { |reference| validate_step_dependency!(workflow, reference) }
            %w[onSuccess onFailure].each do |key|
              validate_actions!(step.fetch(key, []), workflow)
            end
            validate_workflow_reference!(step['workflowId']) if step['workflowId']
            validate_operation_reference!(step)
          end
        end
        self
      rescue Timeout::Error
        Input.fail_security('ARAZZO_COMPLEXITY', 'Arazzo validation exceeded the time limit')
      end

      def run(workflow_id, inputs: {}, seed: 0)
        validate!
        state = { 'remaining' => MAX_STEPS, 'workflows' => {}.compare_by_identity, 'seed' => Integer(seed), 'trace' => [] }
        execute(workflow_id, inputs, state, [])
      end

      private

      # Resolve only bundled JSON Schema meta resources required by the
      # official Arazzo schema. No schema URL can trigger a network download.
      def schema_reference(uri)
        return JSONSchemer.draft202012.value if uri.to_s == 'https://json-schema.org/draft/2020-12/schema'
        JSONSchemer::Draft202012::Meta::SCHEMAS.fetch(uri) do
          invalid('ARAZZO_SCHEMA_REF', 'Unrecognized external schema reference')
        end
      end

      # Check identities throughout the supplied document before any step can
      # produce an HTTP side effect. Unbound external sources remain deferred:
      # import/validate never follows source-description URLs.
      def validate_workflow_reference!(reference)
        match = reference.match(/\A\$sourceDescriptions\.([^.]+)\.(.+)\z/)
        return find_workflow(reference) unless match
        declaration = source_declaration(match[1])
        if declaration['type'] && declaration['type'] != 'arazzo'
          invalid('ARAZZO_SOURCE', 'Workflow reference must name an Arazzo source')
        end
        return unless supplied_source?(declaration)
        source = bound_source(declaration)
        unless source.is_a?(Hash) && source.key?('arazzo') && source['workflows'].is_a?(Array)
          invalid('ARAZZO_SOURCE', 'Supplied workflow source must be an Arazzo document')
        end
        source['workflows'].find { |workflow| workflow.is_a?(Hash) && workflow['workflowId'] == match[2] } ||
          invalid('ARAZZO_WORKFLOW_REF', 'Unknown workflowId in the supplied Arazzo source')
      end

      def validate_step_reference!(workflow, step_id)
        return unless workflow # An external workflow was declared but not supplied.
        unless workflow.fetch('steps', []).any? { |step| step.is_a?(Hash) && step['stepId'] == step_id }
          invalid('ARAZZO_STEP_REF', 'Unknown stepId in the referenced workflow')
        end
      end

      def validate_step_dependency!(workflow, reference)
        if (match = reference.match(/\A\$workflows\.([^.]+)\.steps\.([^.]+)\z/))
          validate_step_reference!(find_workflow(match[1]), match[2])
        elsif (match = reference.match(/\A\$sourceDescriptions\.([^.]+)\.([^.]+)\.steps\.([^.]+)\z/))
          target = validate_workflow_reference!("$sourceDescriptions.#{match[1]}.#{match[2]}")
          validate_step_reference!(target, match[3])
        else
          validate_step_reference!(workflow, reference)
        end
      end

      def validate_operation_reference!(step)
        return if step['workflowId'] || step.key?('action') || step.key?('channelPath')
        if step['operationPath']
          match = step['operationPath'].match(/\A\{\$sourceDescriptions\.([^.]+)\.url\}#(\/.*)\z/)
          # Other URI forms can be imported; the HTTP executor rejects them.
          return unless match
          declaration = source_declaration(match[1])
        elsif (match = step['operationId']&.match(/\A\$sourceDescriptions\.([^.]+)\.(.+)\z/))
          declaration = source_declaration(match[1])
        else
          candidates = @document['sourceDescriptions'].reject { |source| source['type'] == 'arazzo' }
          invalid('ARAZZO_OPERATION_ID', 'Qualify operationId when multiple API sources are declared') unless candidates.size == 1
          declaration = candidates.first
        end
        return if declaration['type'] == 'asyncapi' || !supplied_source?(declaration)
        operation_for(step)
      end

      def execute(workflow_id, inputs, state, stack)
        Input.fail_security('ARAZZO_DEPTH', 'Workflow nesting exceeds the limit') if stack.length >= MAX_NESTING
        identity = [@document.object_id, workflow_id]
        Input.fail_security('ARAZZO_CYCLE', 'Recursive workflow dependency detected') if stack.include?(identity)
        workflow = find_workflow(workflow_id)
        validate_inputs!(workflow, inputs)
        document_workflows = (state['workflows'][@document] ||= {})
        context = { 'inputs' => inputs, 'steps' => {}, 'workflows' => document_workflows,
                    'components' => @document.fetch('components', {}), 'self' => @document['$self'],
                    'sourceDescriptions' => @document.fetch('sourceDescriptions').to_h { |source| [source['name'], source] } }
        document_workflows[workflow_id] = { 'inputs' => inputs, 'outputs' => {}, 'steps' => context['steps'] }
        workflow.fetch('dependsOn', []).each do |dependency|
          outcome = invoke_workflow(dependency, inputs, state, stack + [identity])
          return result(workflow_id, false, context, workflow, state) unless outcome['success']
        end
        index = 0
        retries = Hash.new(0)
        steps = workflow.fetch('steps')
        success = true
        while index < steps.length
          step = steps[index]
          success = execute_step(workflow, step, context, state, stack + [identity])
          actions = merged_actions(workflow, step, success)
          action = actions.find { |candidate| criteria_met?(candidate.fetch('criteria', []), context) }
          if action
            case action['type']
            when 'end'
              break
            when 'goto'
              if action['workflowId']
                values = action_inputs(action, context)
                return invoke_workflow(action['workflowId'], values, state, stack + [identity])
              end
              index = steps.index { |candidate| candidate['stepId'] == action['stepId'] }
              invalid('ARAZZO_STEP_REF', 'Action references an unknown step') unless index
              next
            when 'retry'
              retry_key = [step['stepId'], action['name']]
              limit = action.fetch('retryLimit', 1)
              delay = action.fetch('retryAfter', 0)
              Input.fail_security('ARAZZO_RETRY_LIMIT', 'Retry policy exceeds execution bounds') if limit > 100 || delay > 60
              break if retries[retry_key] >= limit
              retries[retry_key] += 1
              break unless recover(action, workflow, context, state, stack + [identity], [])
              @sleeper.call(delay) if delay.positive?
              next
            end
          end
          break unless success
          index += 1
        end
        result(workflow_id, success, context, workflow, state)
      end

      def execute_step(workflow, step, context, state, stack)
        state['remaining'] -= 1
        Input.fail_security('ARAZZO_LIMIT', 'Workflow step budget exhausted') if state['remaining'].negative?
        check_dependencies!(step, context)
        parameters = merge_parameters(workflow.fetch('parameters', []), step.fetch('parameters', []))
        if step['workflowId']
          values = parameters.to_h { |parameter| [parameter['name'], evaluate(parameter['value'], context)] }
          nested = invoke_workflow(step['workflowId'], values, state, stack)
          context['response'] = { 'body' => nested['outputs'], 'header' => {} }
          context['statusCode'] = nested['success'] ? 200 : 500
          success = nested['success']
        else
          execute_http(step, parameters, context)
          success = context['statusCode'].positive?
        end
        success &&= criteria_met?(step.fetch('successCriteria', []), context)
        outputs = success ? evaluate(step.fetch('outputs', {}), context) : {}
        context['steps'][step['stepId']] = { 'outputs' => outputs, 'success' => success }
        state['trace'] << { 'workflowId' => workflow['workflowId'], 'stepId' => step['stepId'],
                            'success' => success, 'statusCode' => context['statusCode'] }
        success
      end

      # A retry may execute a recovery workflow or step before returning to the
      # failed step. Recovery shares outputs, parameter overrides, action rules,
      # the global step budget and depth guards with ordinary execution.
      def recover(action, workflow, context, state, stack, recovery_stack)
        if action['workflowId']
          return invoke_workflow(action['workflowId'], action_inputs(action, context), state, stack)['success']
        end
        return true unless action['stepId']
        Input.fail_security('ARAZZO_DEPTH', 'Recovery nesting exceeds the limit') if recovery_stack.length >= MAX_NESTING
        if recovery_stack.include?(action['stepId'])
          Input.fail_security('ARAZZO_CYCLE', 'Recursive recovery step detected')
        end
        step_id = action['stepId']
        retries = Hash.new(0)
        loop do
          step = workflow['steps'].find { |candidate| candidate['stepId'] == step_id }
          invalid('ARAZZO_STEP_REF', 'Retry action references an unknown step') unless step
          success = execute_step(workflow, step, context, state, stack)
          next_action = merged_actions(workflow, step, success).find do |candidate|
            criteria_met?(candidate.fetch('criteria', []), context)
          end
          return success unless next_action
          case next_action['type']
          when 'end' then return success
          when 'goto'
            if next_action['workflowId']
              return invoke_workflow(next_action['workflowId'], action_inputs(next_action, context), state, stack)['success']
            end
            step_id = next_action['stepId']
          when 'retry'
            key = [step_id, next_action['name']]
            limit = next_action.fetch('retryLimit', 1)
            delay = next_action.fetch('retryAfter', 0)
            Input.fail_security('ARAZZO_RETRY_LIMIT', 'Retry policy exceeds execution bounds') if limit > 100 || delay > 60
            return false if retries[key] >= limit
            retries[key] += 1
            return false unless recover(next_action, workflow, context, state, stack, recovery_stack + [step_id])
            @sleeper.call(delay) if delay.positive?
          end
        end
      end

      def result(id, success, context, workflow, state)
        outputs = success ? evaluate(workflow.fetch('outputs', {}), context) : {}
        context['workflows'][id]['outputs'] = outputs
        { 'workflowId' => id, 'success' => success, 'outputs' => outputs,
          'steps' => context['steps'], 'trace' => state['trace'].dup, 'seed' => state['seed'] }
      end

      def invoke_workflow(reference, inputs, state, stack)
        match = reference.match(/\A\$sourceDescriptions\.([^.]+)\.(.+)\z/)
        return execute(reference, inputs, state, stack) unless match
        source = bound_source(source_declaration(match[1]))
        invalid('ARAZZO_SOURCE', 'Nested Arazzo source must be supplied explicitly') unless source.is_a?(Hash) && source.key?('arazzo')
        child = self.class.new(source, sources: @sources, transport: @transport, sleeper: @sleeper)
        child.validate!
        child.send(:execute, match[2], inputs, state, stack)
      end

      def find_workflow(id)
        @document.fetch('workflows', []).find { |workflow| workflow['workflowId'] == id } ||
          invalid('ARAZZO_WORKFLOW_REF', 'Unknown workflowId')
      end

      def validate_inputs!(workflow, inputs)
        invalid('ARAZZO_INPUTS', 'Workflow inputs must be an object') unless inputs.is_a?(Hash)
        return unless workflow['inputs']
        index = @document['workflows'].index(workflow)
        # Input schemas can reference other components, JSON Pointer locations,
        # and anchors within this document. Network refs remain disabled.
        schema = JSONSchemer.schema(@document).ref("#/workflows/#{index}/inputs")
        errors = schema.validate(inputs).take(20)
        invalid('ARAZZO_INPUTS', 'Workflow inputs do not satisfy the input schema') unless errors.empty?
      rescue JSONSchemer::UnknownRef
        invalid('ARAZZO_INPUT_REF', 'Workflow input schema has an unresolved reference')
      end

      def execute_http(step, parameters, context)
        unsupported('AsyncAPI broker operations') if step.key?('action') || step.key?('channelPath')
        source, path, method, operation, path_item = operation_for(step)
        server = (operation['servers'] || path_item['servers'] || source['servers'] || []).first
        invalid('ARAZZO_SERVER', 'HTTP operation requires an absolute server URL') unless server.is_a?(Hash)
        base = server.fetch('url')
        server.fetch('variables', {}).each { |name, settings| base = base.gsub("{#{name}}", settings.fetch('default').to_s) }
        path = path.dup
        headers = {}
        query = []
        cookies = []
        request_context = { 'header' => headers, 'path' => {}, 'query' => {} }
        available = (path_item.fetch('parameters', []) + operation.fetch('parameters', [])).to_h { |parameter| [[parameter['name'], parameter['in']], parameter] }
        parameters.each do |parameter|
          name = parameter['name']
          location = parameter['in']
          definition = available[[name, location]]
          invalid('ARAZZO_PARAMETER', 'Workflow parameter is not declared by its OpenAPI operation') unless definition
          value = evaluate(parameter['value'], context)
          if value.is_a?(Hash) || value.is_a?(Array)
            unsupported('Object and array OpenAPI parameter serialization')
          end
          case location
          when 'path'
            request_context['path'][name] = value
            path = path.gsub("{#{name}}", URI.encode_www_form_component(value.to_s).gsub('+', '%20'))
          when 'query'
            request_context['query'][name] = value
            query << [name, value]
          when 'header'
            invalid('ARAZZO_HEADER', 'Header name/value contains control characters') if [name, value.to_s].any? { |text| text.match?(/[\x00-\x1f\x7f]/) }
            headers[name] = value.to_s
          when 'cookie'
            cookies << "#{URI.encode_www_form_component(name)}=#{URI.encode_www_form_component(value.to_s)}"
          else
            unsupported("Parameter location #{location}")
          end
        end
        invalid('ARAZZO_PARAMETER', 'A required path parameter was not supplied') if path.match?(/\{[^}]+\}/)
        headers['Cookie'] = cookies.join('; ') unless cookies.empty?
        body_spec = step['requestBody']
        body = nil
        if body_spec
          content_type = body_spec['contentType'] || operation.dig('requestBody', 'content')&.keys&.first || 'application/json'
          payload = evaluate(body_spec['payload'], context)
          if content_type.split(';').first == 'application/json' && payload.is_a?(String)
            begin
              payload = JSON.parse(payload)
            rescue JSON::ParserError
              invalid('ARAZZO_PAYLOAD', 'JSON request payload is invalid')
            end
          end
          payload = replace_payload(payload, body_spec.fetch('replacements', []), context)
          request_context['body'] = payload
          headers['Content-Type'] = content_type
          body = case content_type.split(';').first
                 when 'application/json' then JSON.generate(payload)
                 when 'application/x-www-form-urlencoded' then payload.is_a?(String) ? payload : URI.encode_www_form(form_pairs(payload))
                 else
                   unsupported("Request media type #{content_type}") unless payload.is_a?(String)
                   payload
                 end
        end
        url = base.sub(%r{/\z}, '') + path
        url += (url.include?('?') ? '&' : '?') + URI.encode_www_form(query) unless query.empty?
        context['request'] = request_context
        context['url'] = url
        context['method'] = method.upcase
        invalid('ARAZZO_TRANSPORT', 'Supply an HTTP transport to run workflows') unless @transport
        timeout = step.fetch('timeout', 30_000) / 1000.0
        Input.fail_security('ARAZZO_TIMEOUT', 'Step timeout must be between 1 ms and 60 seconds') unless timeout.positive? && timeout <= 60
        response = Timeout.timeout(timeout) { @transport.request(method: method.upcase, url: url, headers: headers, body: body) }
        response = response.transform_keys(&:to_s)
        response_body = response['body']
        response_body = JSON.parse(response_body) if response_body.is_a?(String) && !response_body.empty?
        context['statusCode'] = response.fetch('status').to_i
        context['response'] = { 'body' => response_body, 'header' => response.fetch('headers', {}).transform_keys { |key| key.to_s.downcase } }
      rescue JSON::ParserError
        context['statusCode'] = response.fetch('status').to_i
        context['response'] = { 'body' => response['body'], 'header' => response.fetch('headers', {}).transform_keys { |key| key.to_s.downcase } }
      rescue Paygen::Runtime::SecurityError
        Input.fail_security('ARAZZO_SSRF', 'Workflow transport denied an unsafe request')
      rescue Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError
        context['statusCode'] = 0
        context['response'] = { 'body' => nil, 'header' => {} }
      end

      def form_pairs(value, prefix = nil, depth = 0)
        Input.fail_security('ARAZZO_DEPTH', 'Form payload nesting exceeds the limit') if depth > Input::MAX_DEPTH
        case value
        when Hash
          value.flat_map { |key, child| form_pairs(child, prefix ? "#{prefix}[#{key}]" : key.to_s, depth + 1) }
        when Array
          value.each_with_index.flat_map { |child, index| form_pairs(child, "#{prefix}[#{index}]", depth + 1) }
        else
          [[prefix, value]]
        end
      end

      def operation_for(step)
        if step['operationPath']
          match = step['operationPath'].match(/\A\{\$sourceDescriptions\.([^.]+)\.url\}#(\/.*)\z/)
          invalid('ARAZZO_OPERATION_PATH', 'operationPath must reference a declared source URL and JSON Pointer') unless match
          source = source_document(match[1])
          operation = Input.pointer(source, match[2])
          path_tokens = URI::DEFAULT_PARSER.unescape(match[2]).split('/').drop(1).map { |part| part.gsub('~1', '/').gsub('~0', '~') }
          invalid('ARAZZO_OPERATION_PATH', 'operationPath must address an HTTP operation') unless path_tokens.size == 3 && path_tokens[0] == 'paths' && HTTP_METHODS.include?(path_tokens[2]) && operation.is_a?(Hash)
          return [source, path_tokens[1], path_tokens[2], operation, source['paths'][path_tokens[1]]]
        end
        reference = step['operationId']
        match = reference&.match(/\A\$sourceDescriptions\.([^.]+)\.(.+)\z/)
        source_names = @document['sourceDescriptions'].reject { |source| source['type'] == 'arazzo' }.map { |source| source['name'] }
        if match
          source_names = [match[1]]
          reference = match[2]
        elsif source_names.size != 1
          invalid('ARAZZO_OPERATION_ID', 'Qualify operationId when multiple API sources are declared')
        end
        found = []
        source_names.each do |name|
          source = source_document(name)
          source.fetch('paths', {}).each do |path, item|
            item.each do |method, operation|
              found << [source, path, method, operation, item] if HTTP_METHODS.include?(method) && operation.is_a?(Hash) && operation['operationId'] == reference
            end
          end
        end
        invalid('ARAZZO_OPERATION_ID', 'operationId must resolve to exactly one operation') unless found.size == 1
        found.first
      end

      def source_document(name)
        declaration = source_declaration(name)
        unsupported('AsyncAPI broker operations') if declaration['type'] == 'asyncapi'
        source = bound_source(declaration)
        invalid('ARAZZO_SOURCE', 'OpenAPI source must be supplied explicitly') unless source.is_a?(Hash) && source.key?('openapi')
        source
      end

      def source_declaration(name)
        @document['sourceDescriptions'].find { |source| source['name'] == name } ||
          invalid('ARAZZO_SOURCE', 'Undeclared source description')
      end

      def supplied_source?(declaration)
        @sources.key?(declaration['name']) || @sources.key?(declaration['url'])
      end

      def bound_source(declaration)
        @sources.fetch(declaration['name']) { @sources[declaration['url']] }
      end

      def check_dependencies!(step, context)
        step.fetch('dependsOn', []).each do |dependency|
          record = if dependency.start_with?('$')
                     evaluate(dependency, context)
                   else
                     context['steps'][dependency]
                   end
          invalid('ARAZZO_DEPENDENCY', 'A step dependency has not completed successfully') unless record.is_a?(Hash) && record['success']
        end
      end

      def merged_actions(workflow, step, success)
        global = workflow.fetch(success ? 'successActions' : 'failureActions', []).map { |item| reusable(item) }
        local = step.fetch(success ? 'onSuccess' : 'onFailure', []).map { |item| reusable(item) }
        (global + local).each_with_object({}) { |action, result| result[action['name']] = action }.values
      end

      def action_inputs(action, context)
        action.fetch('parameters', []).map { |item| reusable(item) }.to_h { |parameter| [parameter['name'], evaluate(parameter['value'], context)] }
      end

      def merge_parameters(global, local)
        (global + local).map { |parameter| reusable(parameter) }.each_with_object({}) do |parameter, result|
          result[[parameter['name'], parameter['in']]] = parameter
        end.values
      end

      def reusable(object)
        return object unless object.is_a?(Hash) && object['reference']
        match = object['reference'].match(/\A\$components\.(parameters|successActions|failureActions)\.(.+)\z/)
        invalid('ARAZZO_COMPONENT', 'Reusable object must reference local components') unless match
        target = @document.dig('components', match[1], match[2])
        invalid('ARAZZO_COMPONENT', 'Reusable object references a missing component') unless target.is_a?(Hash)
        object.key?('value') ? target.merge('value' => object['value']) : target
      end

      def evaluate(value, context)
        case value
        when Hash
          return select_value(value, context) if value.key?('selector') && value.key?('context') && value.key?('type')
          value.transform_values { |child| evaluate(child, context) }
        when Array then value.map { |child| evaluate(child, context) }
        when String
          return expression(value, context) if value.start_with?('$')
          interpolate(value, context)
        else value
        end
      end

      def interpolate(value, context)
        value.gsub(/\{(\$[^{}]+)\}/) do
          resolved = expression(Regexp.last_match(1), context)
          resolved.is_a?(Hash) || resolved.is_a?(Array) ? JSON.generate(resolved) : resolved.to_s
        end
      end

      def expression(expression, context)
        base, pointer = expression.split('#', 2)
        value = if %w[$statusCode $url $method $self].include?(base)
                  context[base.delete_prefix('$')]
                elsif (match = base.match(/\A\$(response|request)\.header\.(.+)\z/))
                  headers = context.dig(match[1], 'header') || {}
                  pair = headers.find { |key, _| key.casecmp?(match[2]) }
                  pair && pair[1]
                elsif (match = base.match(/\A\$(inputs|outputs)\.(.+)\z/)) && context[match[1]].is_a?(Hash) && context[match[1]].key?(match[2])
                  context[match[1]][match[2]]
                elsif (match = base.match(/\A\$steps\.([\w-]+)\.outputs\.(.+)\z/)) && context.dig('steps', match[1], 'outputs')&.key?(match[2])
                  context.dig('steps', match[1], 'outputs', match[2])
                elsif (match = base.match(/\A\$workflows\.([\w-]+)\.(inputs|outputs|steps)\.(.+)\z/)) && context.dig('workflows', match[1], match[2])&.key?(match[3])
                  context.dig('workflows', match[1], match[2], match[3])
                else
                  matches = Janeway.enum_for('$.' + base.delete_prefix('$'), context).search
                  invalid('ARAZZO_EXPRESSION', 'Runtime expression must resolve to one value') unless matches.size == 1
                  matches.first
                end
        pointer ? Input.pointer(value, pointer) : value
      rescue Janeway::Error
        invalid('ARAZZO_EXPRESSION', 'Invalid runtime expression')
      end

      def select_value(selector, context)
        source = expression(selector['context'], context)
        case expression_type(selector['type'])
        when 'jsonpointer' then Input.pointer(source, selector['selector'])
        when 'jsonpath'
          selected = Janeway.enum_for(selector['selector'], source).search
          selected.length == 1 ? selected.first : selected
        else unsupported('XPath selectors')
        end
      end

      def expression_type(value)
        return value if value.is_a?(String)
        if value['type'] == 'jsonpath' && value['version'] != 'rfc9535'
          unsupported('Legacy JSONPath expression dialects')
        end
        value['type']
      end

      def replace_payload(payload, replacements, context)
        return payload if replacements.empty?
        # Runtime expressions may return input or output objects by reference.
        # Request replacements must only modify the outgoing payload.
        payload = JSON.parse(JSON.generate(payload))
        replacements.each do |replacement|
          type = expression_type(replacement.fetch('targetSelectorType', 'jsonpointer'))
          value = JSON.parse(JSON.generate(evaluate(replacement['value'], context)))
          target = replacement['target']
          case type
          when 'jsonpointer'
            if target.empty?
              payload = value
              next
            end
            tokens = target.split('/', -1)
            key = tokens.pop.gsub('~1', '/').gsub('~0', '~')
            parent = Input.pointer(payload, tokens.join('/'))
            if parent.is_a?(Array)
              Input.pointer(parent, '/' + key)
              parent[key.to_i] = value
            elsif parent.is_a?(Hash) && parent.key?(key)
              parent[key] = value
            else
              invalid('ARAZZO_REPLACEMENT', 'Payload replacement target does not exist')
            end
          when 'jsonpath' then Janeway.enum_for(target, payload).replace { JSON.parse(JSON.generate(value)) }
          else unsupported('XPath payload replacements')
          end
        end
        payload
      end

      def criteria_met?(criteria, context)
        Timeout.timeout(2) do
          criteria.all? do |criterion|
            type = expression_type(criterion.fetch('type', 'simple'))
            condition = criterion['condition']
            if type == 'simple'
              Condition.new(condition, ->(reference) { expression(reference, context) }).evaluate
            else
              condition = interpolate(condition, context)
              source = expression(criterion['context'], context)
              case type
              when 'regex' then !source.nil? && Regexp.new(condition, timeout: 0.1).match?(source.to_s)
              when 'jsonpath' then !source.nil? && !Janeway.enum_for(condition, source).search.empty?
              else unsupported('XPath criteria')
              end
            end
          end
        end
      rescue Timeout::Error
        Input.fail_security('ARAZZO_COMPLEXITY', 'Criterion evaluation exceeded the time limit')
      rescue RegexpError, Janeway::Error
        false
      rescue Error => error
        raise unless %w[ARAZZO_CRITERION ARAZZO_EXPRESSION REF_MISSING].include?(error.code)
        false
      end


      def validate_parameters!(parameters)
        resolved = parameters.map { |parameter| reusable(parameter) }
        identities = resolved.map { |parameter| [parameter['name'], parameter['in']] }
        invalid('ARAZZO_PARAMETER', 'Duplicate parameter names and locations') unless identities.uniq.size == identities.size
      end

      def validate_actions!(actions, workflow)
        resolved = actions.map { |action| reusable(action) }
        unique!(resolved, 'name')
        resolved.each do |action|
          if action['workflowId'] && action['stepId']
            invalid('ARAZZO_ACTION', 'workflowId and stepId are mutually exclusive in actions')
          end
          validate_workflow_reference!(action['workflowId']) if action['workflowId']
          validate_step_reference!(workflow, action['stepId']) if action['stepId']
          parameters = action.fetch('parameters', []).map { |parameter| reusable(parameter) }
          invalid('ARAZZO_PARAMETER', 'Workflow action parameters must not set in') if parameters.any? { |parameter| parameter.key?('in') }
          validate_parameters!(parameters)
        end
      end

      def unique!(objects, key)
        values = objects.map { |object| object[key] }
        invalid('ARAZZO_DUPLICATE', "Duplicate #{key}") unless values.uniq.size == values.size
      end

      def unsupported(feature)
        raise Error.new("Unsupported workflow execution feature: #{feature}", code: 'ARAZZO_UNSUPPORTED', exit_code: 3)
      end

      def invalid(code, message)
        raise Error.new(message, code: code, exit_code: 3)
      end

      # A small parser for the Arazzo simple expression grammar. Deliberately
      # separate from Ruby: no eval, send, constants, calls, or arithmetic.
      class Condition
        def initialize(source, resolver)
          @scanner = StringScanner.new(source)
          @resolver = resolver
          @tokens = []
          tokenize
          @index = 0
        end

        def evaluate
          result = disjunction
          fail_condition unless @index == @tokens.length
          truthy(result)
        end

        private

        def tokenize
          until @scanner.eos?
            Input.fail_security('ARAZZO_COMPLEXITY', 'Too many criterion tokens') if @tokens.size > 1_000
            next if @scanner.scan(/\s+/)
            token = @scanner.scan(/&&|\|\||==|!=|<=|>=|[()!<>]/)
            if token
              @tokens << [token, token]
            elsif (text = @scanner.scan(/'(?:[^']|'')*'/))
              @tokens << ['value', text[1...-1].gsub("''", "'")]
            elsif (reference = @scanner.scan(/\$[A-Za-z_][A-Za-z0-9_.\-]*(?:\[\d+\][A-Za-z0-9_.\-]*)*(?:\#\/[^\s()!<>=&|]*)?/))
              @tokens << ['reference', reference]
            elsif (number = @scanner.scan(/-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/))
              @tokens << ['value', JSON.parse(number)]
            elsif (literal = @scanner.scan(/true\b|false\b|null\b/))
              @tokens << ['value', JSON.parse(literal)]
            else
              fail_condition
            end
          end
          Input.fail_security('ARAZZO_COMPLEXITY', 'Too many criterion tokens') if @tokens.size > 1_000
        end

        def disjunction
          left = conjunction
          while accept('||')
            right = conjunction
            left = truthy(left) || truthy(right)
          end
          left
        end

        def conjunction
          left = comparison
          while accept('&&')
            right = comparison
            left = truthy(left) && truthy(right)
          end
          left
        end

        def comparison
          left = unary
          operator = peek
          return left unless %w[== != < <= > >=].include?(operator)
          @index += 1
          right = unary
          left, right = normalize(left, right)
          case operator
          when '==' then left == right
          when '!=' then left != right
          when '<' then comparable?(left, right) && left < right
          when '<=' then comparable?(left, right) && left <= right
          when '>' then comparable?(left, right) && left > right
          when '>=' then comparable?(left, right) && left >= right
          end
        end

        def unary
          return !truthy(unary) if accept('!')
          if accept('(')
            value = disjunction
            fail_condition unless accept(')')
            return value
          end
          token = @tokens[@index]
          fail_condition unless token && %w[value reference].include?(token[0])
          @index += 1
          token[0] == 'reference' ? @resolver.call(token[1]) : token[1]
        end

        def normalize(left, right)
          return [left.downcase, right.downcase] if left.is_a?(String) && right.is_a?(String)
          if left.is_a?(Numeric) && right.is_a?(String) && right.match?(/\A-?\d+(?:\.\d+)?\z/)
            right = Float(right)
          elsif right.is_a?(Numeric) && left.is_a?(String) && left.match?(/\A-?\d+(?:\.\d+)?\z/)
            left = Float(left)
          end
          [left, right]
        end

        def comparable?(left, right)
          (left.is_a?(Numeric) && right.is_a?(Numeric)) || (left.is_a?(String) && right.is_a?(String))
        end

        def truthy(value)
          value != false && !value.nil? && value != 0 && value != ''
        end

        def peek
          @tokens[@index]&.first
        end

        def accept(value)
          return false unless peek == value
          @index += 1
          true
        end

        def fail_condition
          raise Error.new('Invalid Arazzo simple condition', code: 'ARAZZO_CRITERION', exit_code: 3)
        end
      end
    end
  end
end
