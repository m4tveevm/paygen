# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe 'src/run test argument handling' do
  it 'adds the default spec directory when the caller supplies only RSpec options' do
    Dir.mktmpdir do |directory|
      capture = File.join(directory, 'arguments')
      bundle = File.join(directory, 'bundle')
      File.write(bundle, <<~SH)
        #!/usr/bin/env bash
        printf '%s\n' "$@" > "#{capture}"
      SH
      File.chmod(0o755, bundle)
      runner = File.expand_path('../run', __dir__)
      _stdout, stderr, status = Open3.capture3({ 'PATH' => "#{directory}:#{ENV.fetch('PATH')}" }, runner, 'test', '--seed', '29193')
      expect(status).to be_success, stderr
      expect(File.readlines(capture, chomp: true)).to eq(
        %w[exec rspec --options src/.rspec --default-path src/spec --require ./src/script/rspec-policy.rb -I src/spec --seed 29193]
      )
    end
  end

  it 'preserves an explicit test path alongside the default and empty-suite policy' do
    Dir.mktmpdir do |directory|
      capture = File.join(directory, 'arguments')
      bundle = File.join(directory, 'bundle')
      File.write(bundle, "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > #{capture.dump}\n")
      File.chmod(0o755, bundle)
      runner = File.expand_path('../run', __dir__)
      _stdout, stderr, status = Open3.capture3({ 'PATH' => "#{directory}:#{ENV.fetch('PATH')}" }, runner, 'test', 'src/spec/input_spec.rb', '--seed', '7')
      expect(status).to be_success, stderr
      expect(File.readlines(capture, chomp: true)).to eq(
        %w[exec rspec --options src/.rspec --default-path src/spec --require ./src/script/rspec-policy.rb -I src/spec src/spec/input_spec.rb --seed 7]
      )
    end
  end
end
