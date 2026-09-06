# frozen_string_literal: true

require 'rspec'
require_relative 'docs_provider_assets'

RSpec.describe DocsProviderAssets do
  around do |example|
    Dir.mktmpdir('paygen-docs-spec-') do |directory|
      @directory = directory
      example.run
    end
  end

  it 'binds generated and publication bytes separately and is repeatable across directories' do
    first = File.join(@directory, 'first')
    second = File.join(@directory, 'second')
    FileUtils.mkdir_p([first, second])
    manifest = described_class.build(first)
    expect(described_class.build(second)).to eq(manifest)
    project = Paygen::Project.init(File.join(described_class::ROOT, 'fixtures/novapay/openapi.yaml'),
                                  output: File.join(@directory, 'independent'),
                                  profile: File.join(described_class::ROOT, 'fixtures/novapay/integration.yml'))
    Paygen::Generator.new(project).generate
    described_class::FILES.each do |name|
      generated = File.binread(project.path("generated/#{name}"))
      published = File.binread(File.join(first, 'downloads/novapay', name))
      expect(published).to eq(described_class.publication_bytes(name, generated).b)
      expect(manifest.fetch('unpublished_generated_sha256').fetch(name)).to eq(Digest::SHA256.hexdigest(generated))
      expect(published).not_to match(/\b\d{13,19}\b/)
    end
    expect(manifest.fetch('generated_input_sha256')).to eq(project.lock.fetch('inputs'))
    expect(manifest.fetch('generated_input_sha256').keys).to include('integration.yml', 'recipes/selected.yml')
  end

  it 'redacts nested public samples without changing their source or hiding credential patterns' do
    source = JSON.generate('sample' => { 'card_number' => '4111111111111111', 'id' => 1234567890123456 },
                           'examples' => ['x 4111111111111111 y'], 'credential' => 'sk_live_not_a_payment_identifier')
    published = JSON.parse(described_class.publication_bytes('config.json', source))
    expect(published.fetch('sample').values).to eq(['[REDACTED]', '[REDACTED]'])
    expect(published.fetch('examples')).to eq(['x [REDACTED] y'])
    expect(published.fetch('credential')).to eq('sk_live_not_a_payment_identifier')
    expect(source).to include('4111111111111111')
  end

  it 'refuses an existing publication instead of overwriting it' do
    described_class.build(@directory)
    expect { described_class.build(@directory) }.to raise_error(/already exists/)
  end

  it 'refuses a symlinked downloads parent without writing outside the output' do
    outside = File.join(@directory, 'outside')
    output = File.join(@directory, 'site')
    FileUtils.mkdir_p([outside, output])
    File.symlink(outside, File.join(output, 'downloads'))
    expect { described_class.build(output) }.to raise_error(/symbolic-link/)
    expect(Dir.children(outside)).to be_empty
  end

  it 'rejects an identity that does not match the checkout' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('PAYGEN_SOURCE_SHA').and_return('0' * 40)
    expect { described_class.source_sha }.to raise_error(/does not match/)
  end
end
