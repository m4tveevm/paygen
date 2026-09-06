# frozen_string_literal: true
require 'simplecov'
SimpleCov.root File.expand_path('../..', __dir__)
SimpleCov.start do
  add_filter '/spec/'
  enable_coverage :branch
end
require 'tmpdir'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)
require 'paygen'
RSpec.configure do |config|
  config.order = :random
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  Kernel.srand config.seed
end
