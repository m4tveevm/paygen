# frozen_string_literal: true

require 'spec_helper'
require_relative '../script/verify-fixtures'

RSpec.describe 'Fixture contract gate' do
  it 'requires positive payload coverage for all seven datasets and preserves four invalid upstream examples' do
    report = Paygen::FixtureGate.run
    expect(report.fetch('failures')).to eq([])
    expect(report.fetch('profiles').map { |item| item['name'] }).to eq(Paygen::FixtureGate::DATASETS.keys)
    expect(report.fetch('profiles').sum { |item| item['positive'] }).to be >= 67
    expect(report.fetch('profiles').sum { |item| item['upstream_invalid'] }).to eq(4)
    expect(report.fetch('profiles').find { |item| item['name'] == 'novapay' }.fetch('response_coverage').size).to eq(15)
  end

  it 'does not allow removing a response positive and its primary alias to pass the gate' do
    allow_any_instance_of(Paygen::Generator).to receive(:render).and_wrap_original do |original, **kwargs|
      files = original.call(**kwargs)
      fixtures = JSON.parse(files.fetch('fixtures.json'))
      if fixtures.dig('create', 'response_examples', '409')
        fixtures['create']['response_examples']['409'] = []
        fixtures['create'].delete('response_409')
      end
      files.merge('fixtures.json' => Paygen.json(fixtures))
    end
    report = Paygen::FixtureGate.run
    expect(report.fetch('status')).to eq('failed')
    expect(report.fetch('failures').join('\n')).to include('missing create/409/application/json positive coverage')
  end

  it 'keeps NovaPay parent and branch recipient requirements and schema-valid error responses' do
    Dir.mktmpdir do |directory|
      project = Paygen::Project.init('fixtures/novapay/openapi.yaml', output: File.join(directory, 'project'))
      fixtures = JSON.parse(Paygen::Generator.new(project).render.fetch('fixtures.json'))
      [['status', 'response_200'], ['cancel', 'response_200'], ['create', 'response_409']].each do |role, name|
        recipient = fixtures.fetch(role).fetch(name).fetch('recipient')
        expect(recipient).to include('type')
        if recipient.fetch('type') == 'sbp'
          expect(recipient.keys).to include('phone', 'bank_code')
        else
          expect(recipient.keys).to include('card_number')
        end
      end
      conflict = fixtures.dig('create', 'response_examples', '409')
      expect(conflict.any? { |item| item['suitability'] == 'positive' }).to be(true)
    end
  end

  it 'checks fixed-point money in focused PayPal response and mutated terminal callback samples independently' do
    Dir.mktmpdir do |directory|
      project = Paygen::Project.init('fixtures/paypal/openapi.yaml', output: File.join(directory, 'project'))
      fixtures = JSON.parse(Paygen::Generator.new(project).render.fetch('fixtures.json'))
      expect(fixtures.dig('create', 'response_201', 'items', 0, 'payout_item', 'amount', 'value')).to match(/\A\d+\.\d{2}\z/)
      %w[approved rejected].each do |state|
        example = fixtures.dig('callback', 'cases').find { |item| item['mapped_operation_status'] == state }
        expect(example.fetch('suitability')).to eq('positive')
        expect(example.dig('payload', 'resource', 'payout_item', 'amount', 'value')).to match(/\A\d+\.\d{2}\z/)
      end
    end
  end

  it 'revalidates callback payloads after terminal status substitutions and reports missing terminal coverage' do
    Dir.mktmpdir do |directory|
      project = Paygen::Project.init('fixtures/novapay/openapi.yaml', output: File.join(directory, 'project'))
      project.write('overlays/900-callback-status.yaml', YAML.dump({
        'overlay' => '1.1.0', 'info' => { 'title' => 'Restricted callback regression', 'version' => '1' },
        'actions' => [{ 'target' => '$.components.schemas.WebhookPayload.properties.status.enum', 'remove' => true },
                      { 'target' => '$.components.schemas.WebhookPayload.properties.status', 'update' => { 'enum' => ['pending'] } }]
      }))
      project.configure(project.profile)
      files = Paygen::Generator.new(project).render(draft: true)
      cases = JSON.parse(files.fetch('fixtures.json')).dig('callback', 'cases')
      expect(cases.select { |item| %w[approved rejected].include?(item['mapped_operation_status']) })
        .to all(include('suitability' => 'unresolved', 'schema_validation' => include('valid' => false)))
      expect(JSON.parse(files.fetch('diagnostics.json')).fetch('diagnostics'))
        .to include(include('code' => 'FIXTURE_UNRESOLVED', 'path' => a_string_ending_with('/requestBody/approved')))
      expect(files.keys.grep(/_service\.rb\z/)).to be_empty
    end
  end

  it 'blocks runnable generation when bounded synthesis cannot provide a mandatory schema-valid response' do
    Dir.mktmpdir do |directory|
      project = Paygen::Project.init('fixtures/novapay/openapi.yaml', output: File.join(directory, 'project'))
      project.write('overlays/900-impossible.yaml', YAML.dump({
        'overlay' => '1.1.0', 'info' => { 'title' => 'Impossible response regression', 'version' => '1' },
        'actions' => [{ 'target' => "$.components.schemas.PayoutResponse", 'update' => { 'not' => {} } }]
      }))
      project.configure(project.profile)
      generator = Paygen::Generator.new(project)
      expect { generator.generate }.to raise_error(Paygen::Error) do |error|
        expect(error.exit_code).to eq(4)
        expect(error.details.fetch('diagnostics')).to include(include('code' => 'FIXTURE_UNRESOLVED', 'severity' => 'blocker'))
      end
      files = generator.render(draft: true)
      expect(files.keys.grep(/_service\.rb\z/)).to be_empty
      expect(JSON.parse(files.fetch('config.json')).fetch('draft')).to be(true)
      create = JSON.parse(files.fetch('fixtures.json')).fetch('create')
      expect(create).not_to have_key('response_201')
      expect(create.fetch('response_examples').fetch('201')).to include(include('origin' => 'openapi-example', 'suitability' => 'unresolved'))
    end
  end
end

RSpec.describe Paygen::SchemaExample do
  subject(:builder) { described_class.new }

  it 'retains parent required fields while choosing exactly one compatible branch' do
    schema = { 'type' => 'object', 'required' => ['id'], 'properties' => { 'id' => { 'const' => 'parent' } },
               'oneOf' => [{ 'required' => ['card'], 'properties' => { 'card' => { 'const' => 'test-card' } } },
                           { 'required' => ['phone'], 'properties' => { 'phone' => { 'const' => 'test-phone' } } }] }
    expect(builder.call(schema)).to eq('id' => 'parent', 'card' => 'test-card')
    expect(JSONSchemer.schema(schema).valid?(builder.call(schema))).to be(true)
    expect(builder.call('oneOf' => [{ 'type' => 'integer' }, { 'type' => 'number' }])).to be_nil
  end

  it 'handles allOf, anyOf, enum and constraints without accepting invalid source examples' do
    schema = { 'type' => 'object', 'required' => ['id'], 'properties' => { 'id' => { 'type' => 'integer', 'minimum' => 10 } },
               'allOf' => [{ 'required' => ['state'], 'properties' => { 'state' => { 'enum' => ['ok'] } } }] }
    expect(builder.call(schema)).to eq('id' => 10, 'state' => 'ok')
    expect(builder.call('type' => 'integer', 'example' => -1, 'minimum' => 5, 'exclusiveMinimum' => 10)).to eq(11)
    expect(builder.call('type' => 'string', 'example' => 'wrong', 'pattern' => '^\\d+\\.\\d{2}$')).to eq('0.00')
    expect(builder.call('type' => 'number', 'exclusiveMinimum' => 0, 'exclusiveMaximum' => 0.5)).to eq(0.25)
    expect(builder.call('type' => 'integer', 'exclusiveMaximum' => -5)).to eq(-6)
    expect(builder.call('anyOf' => [{ 'type' => 'boolean' }, { 'type' => 'string' }])).to eq(false)
    expect(builder.call('type' => 'array', 'minItems' => 2, 'maxItems' => 2, 'items' => { 'const' => 'x' })).to eq(%w[x x])
  end

  it 'shares one finite work budget across nested alternative searches' do
    leaf = { 'type' => 'string', 'pattern' => '^unimplemented-witness$' }
    schema = 8.times.reduce(leaf) { |child, _| { 'anyOf' => Array.new(8, child) } }
    expect(builder.call(schema)).to be_nil
    expect(builder.instance_variable_get(:@remaining)).to eq(0)
    # A new independent request resets the budget; recursive attempts do not.
    expect(builder.call('type' => 'string', 'const' => 'next')).to eq('next')
  end

  it 'bounds unsupported patterns, depth and sizes with deterministic unresolved results' do
    schema = { 'type' => 'string', 'pattern' => '^special-unimplemented-pattern$' }
    expect(builder.call(schema)).to be_nil
    expect(builder.call(schema)).to be_nil
    expect(builder.call('type' => 'array', 'minItems' => 101)).to be_nil
    expect(builder.call('type' => 'string', 'minLength' => 10_001)).to be_nil
    expect(builder.call({ 'type' => 'object' }, 17)).to be_nil
  end
end
