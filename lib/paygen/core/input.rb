# frozen_string_literal: true

require 'json'
require 'psych'
require 'net/http'
require 'uri'
require 'resolv'
require 'ipaddr'
require 'timeout'
require 'json_schemer'

module Paygen
  module Core
    # Strict JSON-compatible YAML ingestion and bounded, explicitly local refs.
    # HTTPS downloads pin the validated DNS answer for the TLS connection.
    class Input
      MAX_BYTES = 10 * 1024 * 1024
      MAX_NODES = 100_000
      MAX_DEPTH = 100
      MAX_REFS = 1_000
      MAX_DOCUMENTS = 32
      DENIED_NETWORKS = %w[
        0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
        172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16
        198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
        ::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 64:ff9b:1::/48
        100::/64 2001::/23 2001:db8::/32 2002::/16 fc00::/7 fe80::/10 ff00::/8
      ].map { |cidr| IPAddr.new(cidr) }.freeze

      class << self
        def load(path_or_url, stdin: $stdin)
          source = path_or_url.to_s
          document = read(source, stdin: stdin)
          base_dir = source == '-' || source.match?(/\Ahttps?:/i) ? nil : File.dirname(File.realpath(source))
          resolved = resolve(document, base_dir: base_dir)
          validate!(resolved)
        rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
          raise Error.new("Cannot read source: #{e.class}", code: 'INPUT_IO', exit_code: 2)
        end

        def read(path_or_url, stdin: $stdin)
          source = path_or_url.to_s
          fail_security('INPUT_PATH', 'Input path contains a NUL byte') if source.include?("\0")
          text = if source == '-'
                   bounded_read(stdin)
                 elsif source.match?(/\A[a-z][a-z0-9+.-]*:/i)
                   fetch_https(source)
                 else
                   File.open(source, 'rb') { |file| bounded_read(file) }
                 end
          parse(text)
        rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
          raise Error.new("Cannot read source: #{e.class}", code: 'INPUT_IO', exit_code: 2)
        end

        def parse(text)
          fail_security('INPUT_SIZE', 'Input exceeds the 10 MiB limit') if text.bytesize > MAX_BYTES
          text = text.dup.force_encoding(Encoding::UTF_8)
          fail_input('INPUT_ENCODING', 'Input must be valid UTF-8') unless text.valid_encoding?
          stream = Psych.parse_stream(text)
          fail_input('INPUT_DOCUMENTS', 'Exactly one YAML/JSON document is required') unless stream.children.length == 1
          counter = [0]
          value = convert_node(stream.children.first.root, 0, counter)
          fail_input('INPUT_TYPE', 'Document root must be an object') unless value.is_a?(Hash)
          value
        rescue Psych::Exception
          fail_input('INPUT_PARSE', 'Invalid YAML or JSON syntax')
        end

        def validate!(document)
          version = document.is_a?(Hash) && document['openapi']
          unless version.is_a?(String) && version.match?(/\A3\.[01]\.\d+\z/)
            fail_input('OAS_VERSION', 'Expected OpenAPI 3.0.x or 3.1.x')
          end
          # JSONSchemer embeds the official OAS meta schemas. Its default ref
          # resolver refuses network IO; all document refs were resolved above.
          errors = Timeout.timeout(10) { JSONSchemer.openapi(document).validate.take(50) }
          unless errors.empty?
            details = errors.map { |e| { 'path' => e['data_pointer'], 'rule' => e['type'] } }
            raise Error.new('OpenAPI document is invalid', code: 'OAS_INVALID', exit_code: 3,
                            details: { 'errors' => details })
          end
          document
        rescue Timeout::Error
          fail_security('INPUT_COMPLEXITY', 'OpenAPI validation exceeded the time limit')
        end

        def resolve(document, base_dir: nil)
          Resolver.new(document, base_dir: base_dir).resolve
        end

        # Keep root-document pointers so source overlays retain their intended
        # locations, while resolving external refs in their own document scope.
        # Call resolve+validate! separately to validate cycles and target shapes.
        def bundle(document, base_dir: nil)
          Resolver.new(document, base_dir: base_dir, preserve_internal: true).resolve
        end

        # RFC 6901 pointer lookup; missing is different from a JSON null value.
        def pointer(document, fragment)
          decoded = URI::DEFAULT_PARSER.unescape(fragment.to_s)
          return document if decoded.empty?
          unless decoded.start_with?('/')
            matches = []
            queue = [document]
            until queue.empty?
              node = queue.pop
              if node.is_a?(Hash)
                matches << node if node['$anchor'] == decoded
                queue.concat(node.values)
              elsif node.is_a?(Array)
                queue.concat(node)
              end
            end
            fail_input('REF_ANCHOR', 'Reference anchor must identify exactly one schema') unless matches.size == 1
            return matches.first
          end
          decoded.split('/', -1).drop(1).reduce(document) do |value, token|
            fail_input('REF_POINTER', 'Invalid JSON Pointer escape') if token.match?(/~(?![01])/)
            key = token.gsub('~1', '/').gsub('~0', '~')
            if value.is_a?(Hash) && value.key?(key)
              value[key]
            elsif value.is_a?(Array) && key.match?(/\A(?:0|[1-9]\d*)\z/) && key.to_i < value.length
              value[key.to_i]
            else
              fail_input('REF_MISSING', 'JSON Pointer target does not exist')
            end
          end
        end

        def public_addresses(host)
          addresses = Timeout.timeout(5) { Resolv.getaddresses(host) }
          fail_security('SSRF_DENIED', 'URL host has no public DNS address') if addresses.empty?
          addresses.each do |address|
            ip = IPAddr.new(address)
            fail_security('SSRF_DENIED', 'Private or special-purpose network addresses are denied') if DENIED_NETWORKS.any? { |net| net.include?(ip) }
          end
          addresses
        rescue Resolv::ResolvError, IPAddr::InvalidAddressError, Timeout::Error
          fail_security('SSRF_DENIED', 'Unable to validate URL host')
        end

        def https_uri(url)
          uri = URI.parse(url)
          unless uri.is_a?(URI::HTTPS) && uri.host && uri.port == 443 && !uri.userinfo && !uri.fragment
            fail_security('SSRF_DENIED', 'Only HTTPS URLs on port 443 without userinfo or fragments are allowed')
          end
          uri
        rescue URI::InvalidURIError
          fail_security('SSRF_DENIED', 'Invalid source URL')
        end

        def fetch_https(url, redirects: 0)
          fail_security('INPUT_REDIRECTS', 'Too many redirects') if redirects > 3
          uri = https_uri(url)
          address = public_addresses(uri.hostname).first
          http = Net::HTTP.new(uri.hostname, uri.port, nil)
          http.ipaddr = address
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.open_timeout = 5
          http.read_timeout = 10
          http.write_timeout = 5
          next_url = nil
          body = +''
          Timeout.timeout(20) do
            http.start do |connection|
              request = Net::HTTP::Get.new(uri.request_uri, 'Accept-Encoding' => 'identity')
              connection.request(request) do |response|
                if response.is_a?(Net::HTTPRedirection)
                  fail_input('INPUT_HTTP', 'Redirect response has no Location') unless response['location']
                  next_url = URI.join(uri.to_s, response['location']).to_s
                elsif response.is_a?(Net::HTTPSuccess)
                  encoding = response['content-encoding']
                  fail_input('INPUT_ENCODING', 'Compressed source responses are not accepted') if encoding && encoding != 'identity'
                  response.read_body do |chunk|
                    body << chunk
                    fail_security('INPUT_SIZE', 'Input exceeds the 10 MiB limit') if body.bytesize > MAX_BYTES
                  end
                else
                  fail_input('INPUT_HTTP', "Source returned HTTP #{response.code}")
                end
              end
            end
          end
          next_url ? fetch_https(next_url, redirects: redirects + 1) : body
        rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
          fail_input('INPUT_HTTP', 'HTTPS source download failed')
        end

        def fail_input(code, message)
          raise Error.new(message, code: code, exit_code: 3)
        end

        def fail_security(code, message)
          raise Error.new(message, code: code, exit_code: 5)
        end

        private

        def bounded_read(io)
          text = io.read(MAX_BYTES + 1) || ''
          fail_security('INPUT_SIZE', 'Input exceeds the 10 MiB limit') if text.bytesize > MAX_BYTES
          text
        end

        def convert_node(node, depth, counter)
          fail_security('INPUT_DEPTH', 'Document nesting exceeds the limit') if depth > MAX_DEPTH
          counter[0] += 1
          fail_security('INPUT_NODES', 'Document node count exceeds the limit') if counter[0] > MAX_NODES
          fail_input('INPUT_PARSE', 'Empty document') unless node
          fail_security('YAML_TAG', 'YAML object tags are not allowed') if node.respond_to?(:tag) && node.tag && !node.tag.start_with?('tag:yaml.org,2002:')
          case node
          when Psych::Nodes::Mapping
            fail_security('YAML_TAG', 'Nonstandard YAML mapping tag') if node.tag && node.tag != 'tag:yaml.org,2002:map'
            node.children.each_slice(2).each_with_object({}) do |(key, value), hash|
              fail_input('INPUT_KEY', 'Mapping keys must be scalars') unless key.is_a?(Psych::Nodes::Scalar)
              fail_security('YAML_TAG', 'Mapping keys cannot carry object tags') if key.tag && key.tag != 'tag:yaml.org,2002:str'
              name = key.value
              fail_security('YAML_MERGE', 'YAML merge keys are not allowed') if name == '<<'
              fail_input('INPUT_DUPLICATE', 'Duplicate mapping key') if hash.key?(name)
              hash[name] = convert_node(value, depth + 1, counter)
            end
          when Psych::Nodes::Sequence
            fail_security('YAML_TAG', 'Nonstandard YAML sequence tag') if node.tag && node.tag != 'tag:yaml.org,2002:seq'
            node.children.map { |child| convert_node(child, depth + 1, counter) }
          when Psych::Nodes::Scalar
            scalar(node)
          when Psych::Nodes::Alias
            fail_security('YAML_ALIAS', 'YAML aliases are not allowed')
          else
            fail_input('INPUT_PARSE', 'Unsupported YAML node')
          end
        end

        # YAML 1.2 core scalar rules restricted to finite, JSON-shaped values.
        # Dates, yes/no, and leading-zero identifiers remain strings.
        def scalar(node)
          allowed = %w[str int float bool null]
          tag = node.tag&.delete_prefix('tag:yaml.org,2002:')
          fail_security('YAML_TAG', 'Unsupported YAML scalar tag') if tag && !allowed.include?(tag)
          return node.value if tag == 'str' || (node.quoted && !tag)
          value = node.value
          return nil if value.empty? || value.match?(/\A(?:null|Null|NULL|~)\z/)
          return true if value.match?(/\A(?:true|True|TRUE)\z/)
          return false if value.match?(/\A(?:false|False|FALSE)\z/)
          fail_security('INPUT_NUMBER', 'Numeric scalar exceeds the resource limit') if value.bytesize > 1024 && value.match?(/\A[-+0-9.eE]+\z/)
          return Integer(value, 10) if value.match?(/\A-?(?:0|[1-9]\d*)\z/)
          if value.match?(/\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\z/)
            result = Float(value)
            fail_input('INPUT_NUMBER', 'Numbers must be finite') unless result.finite?
            return result
          end
          fail_input('INPUT_NUMBER', 'Numbers must be finite') if value.match?(/\A[+.-]*(?:inf|nan)\z/i)
          fail_input('INPUT_SCALAR', 'Explicit scalar tag does not match a JSON value') if tag
          value
        end
      end

      class Resolver
        def initialize(document, base_dir:, preserve_internal: false)
          @preserve_internal = preserve_internal
          @document = document
          @base_dir = base_dir && File.realpath(base_dir)
          @documents = { '<root>' => document }
          @refs = 0
          @nodes = 0
        end

        def resolve
          visit(@document, '<root>', [], 0, false)
        end

        private

        def visit(value, location, stack, depth, schema_context, map_container = false)
          @nodes += 1
          Input.fail_security('REF_LIMIT', 'Resolved document exceeds resource limits') if @nodes > MAX_NODES || depth > MAX_DEPTH
          case value
          when Hash
            if !map_container && value.key?('$dynamicRef')
              Input.fail_input('REF_DYNAMIC_UNSUPPORTED', 'Dynamic references require explicit schema normalization')
            end
            if !map_container && value.key?('$ref')
              resolve_ref(value, location, stack, depth, schema_context)
            else
              value.each_with_object({}) do |(key, child), hash|
                if !map_container && (%w[example value].include?(key) || (schema_context && %w[default enum const].include?(key)) || key.start_with?('x-'))
                  hash[key] = child
                  next
                end
                child_schema = schema_context || key == 'schema' || key == 'schemas' || key == '$defs'
                child_map = %w[properties patternProperties dependentSchemas $defs schemas].include?(key)
                hash[key] = visit(child, location, stack, depth + 1, child_schema, child_map)
              end
            end
          when Array
            value.map { |child| visit(child, location, stack, depth + 1, schema_context) }
          else
            value
          end
        end

        def resolve_ref(value, location, stack, depth, schema_context)
          @refs += 1
          Input.fail_security('REF_LIMIT', 'Too many expanded references') if @refs > MAX_REFS
          ref = value['$ref']
          Input.fail_input('REF_TYPE', 'Reference must be a string') unless ref.is_a?(String) && !ref.empty?
          resource, fragment = ref.split('#', 2)
          if @preserve_internal && location == '<root>' && resource.empty?
            return value.each_with_object({}) do |(key, child), result|
              result[key] = key == '$ref' ? child : visit(child, location, stack, depth + 1, schema_context)
            end
          end
          target_location = resource.empty? ? location : local_resource(resource, location)
          identity = [target_location, fragment.to_s]
          Input.fail_security('REF_CYCLE', 'Cyclic references are not supported by the generator') if stack.include?(identity)
          target = Input.pointer(@documents.fetch(target_location), fragment)
          resolved = visit(target, target_location, stack + [identity], depth + 1, schema_context)
          siblings = value.reject { |key, _| key == '$ref' }
          return resolved if siblings.empty? || @document['openapi'].to_s.start_with?('3.0.')
          if schema_context
            # In 3.1 a schema ref and its siblings are conjunctive, not a merge.
            { 'allOf' => [resolved, visit(siblings, location, stack, depth + 1, true)] }
          elsif resolved.is_a?(Hash)
            resolved.merge(siblings.slice('summary', 'description'))
          else
            resolved
          end
        end

        def local_resource(resource, location)
          if !@base_dir || resource.start_with?('/', '\\') || resource.match?(/\A[a-z][a-z0-9+.-]*:/i)
            Input.fail_security('REF_EXTERNAL_DENIED', 'External references must be local files beneath the source directory')
          end
          decoded = URI::DEFAULT_PARSER.unescape(resource)
          Input.fail_security('REF_PATH', 'Invalid reference path') if decoded.include?("\0") || decoded.include?('\\')
          directory = location == '<root>' ? @base_dir : File.dirname(location)
          candidate = File.realpath(File.expand_path(decoded, directory))
          unless candidate.start_with?(@base_dir + File::SEPARATOR)
            Input.fail_security('REF_PATH', 'Reference escapes the source directory')
          end
          unless @documents.key?(candidate)
            Input.fail_security('REF_LIMIT', 'Too many referenced documents') if @documents.size >= MAX_DOCUMENTS
            @documents[candidate] = Input.read(candidate)
          end
          candidate
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
          Input.fail_input('REF_MISSING', 'Referenced file is missing or inaccessible')
        end
      end
    end
  end
end
