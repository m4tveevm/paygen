# frozen_string_literal: true

require 'digest'
require 'ipaddr'
require 'net/http'
require 'openssl'
require 'resolv'
require 'uri'

module Paygen
  module Runtime
    class SecurityError < StandardError; end

    # An injectable store may implement this same synchronized Hash interface
    # using a durable transaction. The built-in store is process-local only.
    class MemoryStateStore
      def initialize
        @mutex = Mutex.new
        @values = {}
      end

      def synchronize(&block)
        @mutex.synchronize { block.call(@values) }
      end
    end

    module Security
      PRIVATE_RANGES = %w[
        0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
        172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16
        198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4
        240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 2001:db8::/32
      ].map { |range| IPAddr.new(range) }.freeze
      SENSITIVE = /(?:authorization|api[_-]?key|secret|token|password|card|pan|phone|email|recipient|iban)/i

      module_function

      def secure_compare(left, right)
        return false unless left.is_a?(String) && right.is_a?(String)
        return false unless left.bytesize == right.bytesize

        OpenSSL.fixed_length_secure_compare(left, right)
      end

      def redact(value, secrets: [])
        case value
        when Hash
          value.to_h do |key, child|
            [key, key.to_s.match?(SENSITIVE) ? '[REDACTED]' : redact(child, secrets: secrets)]
          end
        when Array then value.map { |child| redact(child, secrets: secrets) }
        when String
          text = value.dup
          secrets.flatten.compact.map(&:to_s).reject(&:empty?).sort_by { |secret| -secret.length }.each do |secret|
            text.gsub!(secret, '[REDACTED]')
          end
          text.gsub(/(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/, '[REDACTED]')
        else value
        end
      end

      def uri(url, allow_local: false)
        parsed = URI.parse(url.to_s)
        raise SecurityError, 'URL must use HTTPS' unless parsed.is_a?(URI::HTTPS) ||
                                                                (allow_local && parsed.is_a?(URI::HTTP))
        raise SecurityError, 'URL must not contain credentials or fragments' if parsed.userinfo || parsed.fragment
        raise SecurityError, 'URL host is required' if parsed.host.to_s.empty?
        if parsed.scheme == 'http' && !%w[localhost 127.0.0.1 ::1].include?(parsed.hostname)
          raise SecurityError, 'Plain HTTP is permitted only for explicit loopback testing'
        end
        raise SecurityError, 'Invalid URL control character' if url.to_s.match?(/[\x00-\x20\x7f]/)

        parsed
      rescue URI::InvalidURIError
        raise SecurityError, 'Invalid URL'
      end

      def permitted_address?(address, allow_local: false)
        ip = IPAddr.new(address)
        ip = ip.native if ip.ipv4_mapped?
        return true if allow_local && (IPAddr.new('127.0.0.0/8').include?(ip) || ip == IPAddr.new('::1'))

        PRIVATE_RANGES.none? { |range| range.include?(ip) }
      rescue IPAddr::InvalidAddressError
        false
      end
    end

    # DNS is resolved once and the connection is pinned to that address. HTTPS
    # keeps the original host for certificate verification and SNI. Redirects
    # are returned to the adapter and never followed with provider credentials.
    class HTTPTransport
      def initialize(allow_local: false, open_timeout: 5, read_timeout: 15, maximum_bytes: 1_048_576)
        @allow_local = allow_local
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @maximum_bytes = maximum_bytes
      end

      def request(method:, url:, headers:, body:)
        target = Security.uri(url, allow_local: @allow_local)
        addresses = Resolv.getaddresses(target.hostname)
        raise SecurityError, 'Destination did not resolve' if addresses.empty?
        unless addresses.all? { |address| Security.permitted_address?(address, allow_local: @allow_local) }
          raise SecurityError, 'Destination resolves to a restricted address'
        end

        client = Net::HTTP.new(target.hostname, target.port, nil)
        client.ipaddr = addresses.first
        client.use_ssl = target.scheme == 'https'
        client.verify_mode = OpenSSL::SSL::VERIFY_PEER if client.use_ssl?
        client.open_timeout = @open_timeout
        client.read_timeout = @read_timeout
        client.write_timeout = @read_timeout
        client.max_retries = 0
        request = Net::HTTPGenericRequest.new(method.to_s.upcase, !body.nil?, true, target.request_uri, headers)
        request.body = body unless body.nil?
        result = nil
        client.start do |connection|
          connection.request(request) do |response|
            bytes = +''
            response.read_body do |chunk|
              bytes << chunk
              raise SecurityError, 'Response exceeds size limit' if bytes.bytesize > @maximum_bytes
            end
            result = { status: response.code.to_i, headers: response.to_hash.transform_values(&:first), body: bytes }
          end
        end
        result
      end
    end
  end
end
