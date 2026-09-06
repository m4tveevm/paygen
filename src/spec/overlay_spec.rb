# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Paygen::Core::Overlay do
  let(:source) { { 'title' => 'old', 'objects' => [{ 'name' => 'a', 'tags' => ['one'] }, { 'name' => 'b', 'tags' => ['two'] }], 'destination' => {} } }

  def overlay(*actions)
    { 'overlay' => '1.1.0', 'info' => { 'title' => 'Test', 'version' => '1' }, 'actions' => actions }
  end

  it 'recursively merges objects and concatenates array properties in order' do
    result = described_class.new(source).apply(overlay({ 'target' => '$.objects[0]', 'update' => { 'tags' => ['new'], 'other' => true } }, { 'target' => '$.title', 'update' => 'updated' }))
    expect(result['objects'][0]).to eq('name' => 'a', 'tags' => %w[one new], 'other' => true)
    expect(result['title']).to eq('updated')
    expect(source['title']).to eq('old')
  end

  it 'supports filters, descendants, unions, slices and standard functions via Janeway' do
    selectors = ["$.objects[?@.name == 'a']", '$..objects[0:1]', '$.objects[0,0]', '$.objects[?length(@.name) == 1]']
    selectors.each do |selector|
      result = described_class.new(source).apply(overlay('target' => selector, 'update' => { 'found' => true }))
      expect(result['objects'][0]['found']).to be(true)
    end
  end

  it 'appends objects and primitives to array targets' do
    result = described_class.new(source).apply(overlay('target' => '$.objects[0].tags', 'update' => 'last'))
    expect(result['objects'][0]['tags']).to eq(%w[one last])
  end

  it 'copies one node by recursive merge, snapshots it, and allows a subsequent move' do
    result = described_class.new(source).apply(overlay({ 'target' => '$.destination', 'copy' => '$.objects[0]' }, { 'target' => '$.objects[0]', 'remove' => true }))
    expect(result['destination']).to eq('name' => 'a', 'tags' => ['one'])
    expect(result['objects'].map { |entry| entry['name'] }).to eq(['b'])
  end

  it 'removes array selections without index shifting and honors remove precedence' do
    result = described_class.new(source).apply(overlay('target' => '$.objects[*]', 'remove' => true, 'update' => false))
    expect(result['objects']).to eq([])
  end

  it 'reports a zero match as a warning while succeeding unchanged' do
    engine = described_class.new(source)
    expect(engine.apply(overlay('target' => '$.missing', 'update' => 1))).to eq(source)
    expect(engine.diagnostics.first).to include('code' => 'PATCH_STALE', 'severity' => 'warning')
  end

  it 'rejects incompatible nested merge types rather than overwriting objects' do
    expect { described_class.new(source).apply(overlay('target' => '$.objects[0]', 'update' => { 'tags' => 'no' })) }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('OVERLAY_TYPE') }
  end

  it 'accepts update and copy together and applies their mutual suppression' do
    [nil, 'replacement', { 'added' => true }].each do |value|
      engine = described_class.new(source)
      action = { 'target' => '$.destination', 'update' => value, 'copy' => '$.objects[0]' }
      expect(engine.validate!(overlay(action))).to be_a(Hash)
      expect(engine.apply(overlay(action))).to eq(source)
      expect(engine.diagnostics.first).to include('code' => 'OVERLAY_MODIFIERS_IGNORED')
    end
  end

  it 'lets remove suppress both update and copy without resolving copy matches' do
    action = { 'target' => '$.title', 'remove' => true, 'update' => {}, 'copy' => '$.absent' }
    result = described_class.new(source).apply(overlay(action))
    expect(result).not_to have_key('title')
  end

  it 'rejects mixed selected node kinds and non-single copy sources' do
    expect { described_class.new(source).apply(overlay('target' => '$.*', 'update' => {})) }.to raise_error(Paygen::Error)
    expect { described_class.new(source).apply(overlay('target' => '$.destination', 'copy' => '$.objects[*]')) }.to raise_error(Paygen::Error)
  end

  it 'applies updates to the document root' do
    result = described_class.new(source).apply(overlay('target' => '$', 'update' => { 'added' => 1 }))
    expect(result['added']).to eq(1)
  end

  it 'keeps descendant updates when a selector also matches their ancestors' do
    nested = { 'a' => { 'child' => {} } }
    result = described_class.new(nested).apply(overlay('target' => '$..*', 'update' => { 'marked' => true }))
    expect(result['a']['marked']).to be(true)
    expect(result['a']['child']['marked']).to be(true)
  end

  it 'accepts a target-only action as a no-op' do
    expect(described_class.new(source).apply(overlay('target' => '$.title'))).to eq(source)
  end

  it 'checks extends against the selected document URI' do
    doc = overlay('target' => '$', 'update' => { 'added' => true }).merge('extends' => './source.yaml')
    expect { described_class.new(source, source_uri: '/tmp/other.yaml').apply(doc, overlay_uri: '/tmp/overlay.yaml') }.to raise_error(Paygen::Error) { |error| expect(error.code).to eq('OVERLAY_EXTENDS') }
    expect(described_class.new(source, source_uri: '/tmp/source.yaml').apply(doc, overlay_uri: '/tmp/overlay.yaml')['added']).to be(true)
  end

  it 'resolves root-relative extends paths against an HTTPS overlay origin' do
    doc = overlay('target' => '$', 'update' => { 'added' => true }).merge('extends' => '/source.yaml')
    engine = described_class.new(source, source_uri: 'https://provider.example/source.yaml')

    expect(engine.apply(doc, overlay_uri: 'https://provider.example/overlays/fix.yaml')['added']).to be(true)
  end

  it 'keeps absolute local extends paths absolute for local overlays' do
    doc = overlay('target' => '$', 'update' => { 'added' => true }).merge('extends' => '/tmp/source.yaml')
    engine = described_class.new(source, source_uri: '/tmp/source.yaml')

    expect(engine.apply(doc, overlay_uri: '/tmp/overlays/fix.yaml')['added']).to be(true)
  end

  it 'rejects executable or non-RFC selectors' do
    expect { described_class.new(source).apply(overlay('target' => '$.objects[(@.length - 1)]', 'update' => {})) }.to raise_error(Paygen::Error)
  end
end

RSpec.describe 'Pinned RFC 9535 JSONPath compliance suite' do
  suite = JSON.parse(File.read(File.expand_path('../lib/paygen/core/schemas/jsonpath-cts.json', __dir__)))
  suite.fetch('tests').each do |test|
    it test.fetch('name') do
      if test['invalid_selector']
        expect { Janeway.parse(test.fetch('selector')) }.to raise_error(Janeway::Error)
      else
        values = []
        paths = []
        Janeway.enum_for(test.fetch('selector'), test.fetch('document')).each do |value, _parent, _key, path|
          values << value
          paths << path
        end
        expect(test['results'] || [test.fetch('result')]).to include(values)
        expect(test['results_paths'] || [test.fetch('result_paths')]).to include(paths)
      end
    end
  end
end
