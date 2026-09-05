# frozen_string_literal: true

require 'spec_helper'
require 'paygen/runtime/security'

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
end
