# frozen_string_literal: true
# Sources: RSpec Core 3.13 configuration API; https://github.com/rspec/rspec-core
require 'rspec/core'

# A typo, empty filter or missing suite must never become a green verification.
RSpec.configure { |config| config.fail_if_no_examples = true }
