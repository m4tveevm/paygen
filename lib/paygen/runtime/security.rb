# frozen_string_literal: true

require 'digest'
require 'ipaddr'
require 'net/http'
require 'openssl'
require 'resolv'
require 'timeout'
require 'uri'

module Paygen
  module Runtime
    class SecurityError < StandardError; end
    # Unlike preflight denials, a response limit can occur after a payout commits.
    class ResponseSizeError < SecurityError; end

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
        240.0.0.0/4 ::/128 ::1/128 64:ff9b::/96 64:ff9b:1::/48 100::/64
        2001::/23 2001:db8::/32 2002::/16 fc00::/7 fe80::/10 ff00::/8
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
      def initialize(allow_local: false, open_timeout: 5, read_timeout: 15, total_timeout: 20,
                     maximum_bytes: 1_048_576)
        @allow_local = allow_local
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @total_timeout = Float(total_timeout)
        raise ArgumentError, 'total_timeout must be positive and finite' unless @total_timeout.positive? && @total_timeout.finite?

        @maximum_bytes = maximum_bytes
      end

      def request(method:, url:, headers:, body:)
        # A provider can keep a socket alive indefinitely by trickling bytes.
        # Bound DNS, connection establishment and every response chunk together.
        Timeout.timeout(@total_timeout) do
          perform_request(method: method, url: url, headers: headers, body: body)
        end
      end

      private

      def perform_request(method:, url:, headers:, body:)
        target = Security.uri(url, allow_local: @allow_local)
        addresses = Timeout.timeout(5) { Resolv.getaddresses(target.hostname) }
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
              raise ResponseSizeError, 'Response exceeds size limit' if bytes.bytesize > @maximum_bytes
            end
            result = { status: response.code.to_i, headers: response.to_hash.transform_values(&:first), body: bytes }
          end
        end
        result
      end
    end
  end
end
