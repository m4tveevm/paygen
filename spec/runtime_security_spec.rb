# frozen_string_literal: true

require 'spec_helper'
require 'paygen/runtime/security'
require 'puma'

RSpec.describe Paygen::Runtime::Security do
  it 'denies private, loopback, metadata, mapped IPv4 and reserved destinations' do
    %w[127.0.0.1 ::1 169.254.169.254 10.0.0.1 172.16.1.1 192.168.1.1 ::ffff:127.0.0.1 fe80::1 0.0.0.0 100.64.0.1].each do |ip|
      expect(described_class.permitted_address?(ip)).to be(false), ip
    end
    expect(described_class.permitted_address?('8.8.8.8')).to be(true)
    expect(described_class.permitted_address?('127.0.0.1', allow_local: true)).to be(true)
    expect(described_class.permitted_address?('10.0.0.1', allow_local: true)).to be(false)
  end

  it 'rejects unsafe URL forms before transport construction' do
    ['file:///etc/passwd', 'https://user:secret@example.com/a', 'http://example.com', "https://example.com/\npath", 'https://example.com/#fragment'].each do |url|
      expect { described_class.uri(url) }.to raise_error(Paygen::Runtime::SecurityError)
    end
  end

  it 'checks every DNS answer before connecting to prevent mixed-answer SSRF' do
    allow(Resolv).to receive(:getaddresses).with('provider.example').and_return(['8.8.8.8', '127.0.0.1'])
    expect(Net::HTTP).not_to receive(:new)
    expect do
      Paygen::Runtime::HTTPTransport.new.request(method: 'GET', url: 'https://provider.example/a', headers: {}, body: nil)
    end.to raise_error(Paygen::Runtime::SecurityError, /restricted/)
  end

  it 'keeps synchronized callback state shared between adapter instances' do
    store = Paygen::Runtime::MemoryStateStore.new
    threads = Array.new(5) do
      Thread.new { 100.times { store.synchronize { |state| state['count'] = state.fetch('count', 0) + 1 } } }
    end
    threads.each(&:join)
    expect(store.synchronize { |state| state['count'] }).to eq(500)
  end

  it 'sends real local HTTP bytes, refuses redirects and enforces response limits' do
    requests = []
    app = lambda do |env|
      requests << { 'method' => env['REQUEST_METHOD'], 'path' => env['PATH_INFO'],
                    'body' => env.fetch('rack.input').read, 'key' => env['HTTP_X_KEY'] }
      if env['PATH_INFO'] == '/redirect'
        [302, { 'location' => '/capture' }, ['redirect']]
      else
        [200, { 'content-type' => 'application/json' }, ['{"ok":true}']]
      end
    end
    server = Puma::Server.new(app)
    server.add_tcp_listener('127.0.0.1', 0)
    port = server.binder.ios.first.local_address.ip_port
    server.run
    transport = Paygen::Runtime::HTTPTransport.new(allow_local: true)
    result = transport.request(method: 'POST', url: "http://127.0.0.1:#{port}/capture",
                               headers: { 'X-Key' => 'test-secret' }, body: '{"amount":1234}')
    expect(result[:status]).to eq(200)
    expect(requests.last).to include('method' => 'POST', 'body' => '{"amount":1234}', 'key' => 'test-secret')
    redirect = transport.request(method: 'GET', url: "http://127.0.0.1:#{port}/redirect", headers: {}, body: nil)
    expect(redirect[:status]).to eq(302)
    expect(requests.length).to eq(2)
    limited = Paygen::Runtime::HTTPTransport.new(allow_local: true, maximum_bytes: 5)
    expect do
      limited.request(method: 'GET', url: "http://127.0.0.1:#{port}/capture", headers: {}, body: nil)
    end.to raise_error(Paygen::Runtime::ResponseSizeError, /size limit/)
  ensure
    server&.stop(true)
  end

  it 'bounds the complete request when a provider continuously trickles small response chunks' do
    slow_body = Class.new do
      attr_reader :chunks

      def initialize
        @chunks = 0
      end

      def each
        20.times do
          @chunks += 1
          yield '.'
          sleep 0.02
        end
      end
    end.new
    server = Puma::Server.new(->(_env) { [200, { 'content-type' => 'text/plain' }, slow_body] })
    server.add_tcp_listener('127.0.0.1', 0)
    port = server.binder.ios.first.local_address.ip_port
    server.run
    transport = Paygen::Runtime::HTTPTransport.new(allow_local: true, total_timeout: 0.1,
                                                 read_timeout: 2, maximum_bytes: 100)
    expect do
      transport.request(method: 'GET', url: "http://127.0.0.1:#{port}/slow", headers: {}, body: nil)
    end.to raise_error(Timeout::Error) { |error| expect(error.class).to eq(Timeout::Error) }
    expect(slow_body.chunks).to be < 20
  ensure
    server&.stop(true)
  end

  it 'rejects disabled or unbounded overall deadlines' do
    [0, -1, Float::INFINITY].each do |deadline|
      expect { Paygen::Runtime::HTTPTransport.new(total_timeout: deadline) }.to raise_error(ArgumentError)
    end
  end
end
