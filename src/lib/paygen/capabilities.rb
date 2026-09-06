# frozen_string_literal: true

module Paygen
  # One bounded transport vocabulary shared by the contract gate and runtime.
  module Capabilities
    OUTGOING_ROLES = %w[create status cancel balance].freeze
    REQUEST_ENCODINGS = { 'application/json' => 'json', 'application/x-www-form-urlencoded' => 'form' }.freeze
    API_KEY_LOCATIONS = %w[header query].freeze
    AUTH_TYPES = %w[none apiKey bearer basic oauth2 OAuth2].freeze
    SIGNATURE_ENCODINGS = {
      'hmac-sha256' => %w[hex base64].freeze,
      'stripe-v1' => ['hex'].freeze,
      'provider_verification' => %w[hex base64].freeze
    }.freeze
    SIGNATURE_ALGORITHMS = SIGNATURE_ENCODINGS.keys.freeze

    def self.json_media?(media)
      media == 'application/json' || media.match?(%r{\Aapplication/[a-zA-Z0-9.!#$&^_+-]+\+json\z})
    end

    def self.request_media(content, encoding: nil)
      REQUEST_ENCODINGS.find { |media, codec| content.key?(media) && (encoding.nil? || codec == encoding) }&.first
    end

    def self.request_encoding(endpoint, profile)
      explicit = endpoint['request_encoding'] || profile['request_encoding']
      content = endpoint.fetch('request_content', {})
      # Hand-written runtime configs predating IR media metadata remain supported.
      return explicit || REQUEST_ENCODINGS[endpoint.fetch('content_type', 'application/json')] if content.empty?

      REQUEST_ENCODINGS[request_media(content, encoding: explicit)]
    end
  end
end
