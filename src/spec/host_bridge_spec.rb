# frozen_string_literal: true
require 'spec_helper'
require_relative '../examples/host_bridge'

RSpec.describe 'Independent executable host bridge' do
  it 'loads the generated subclass and proves actions, prechecks and callback backend effects' do
    Dir.mktmpdir do |root|
      report = PaygenHostExample.run(File.join(root, 'proof'))
      expect(report).to include('success' => true, 'failed' => 0, 'skipped' => 0)
      expect(report['checks'].size).to be >= 19
      expect(report['backend_effects'].map(&:last)).to eq(%w[approved rejected])
      expect(report['transport_requests'].count { |request| request['method'] == 'POST' }).to eq(2)
    end
  end
end
