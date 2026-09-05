'use strict';

require('./diplodoc-compat.cjs');
const assert = require('node:assert/strict');
const test = require('node:test');

test('legacy markdown-it imports expose the unchanged upstream APIs', () => {
  for (const name of ['token', 'renderer', 'rules_inline/state_inline']) {
    assert.equal(require(`markdown-it/lib/${name}`), require(`markdown-it/lib/${name}.mjs`).default);
  }
  const utils = require('markdown-it/lib/common/utils');
  assert.equal(utils, require('markdown-it/lib/common/utils.mjs'));
  assert.equal(utils.escapeHtml('<tag>&'), '&lt;tag&gt;&amp;');

  const MarkdownIt = require('markdown-it');
  const Token = require('markdown-it/lib/token');
  const Renderer = require('markdown-it/lib/renderer');
  const StateInline = require('markdown-it/lib/rules_inline/state_inline');
  const parser = new MarkdownIt();
  const token = new Token('text', '', 0);
  token.content = 'plain <text>';
  assert.equal(new Renderer().renderInline([token], parser.options, {}), 'plain &lt;text&gt;');
  assert.equal(new StateInline('text', parser, {}, []).src, 'text');
});

test('source-map-resolve can read encoded external source-map paths', () => {
  const resolve = require('source-map-resolve');
  let requestedPath;
  const result = resolve.resolveSourceMapSync(
    '//# sourceMappingURL=source%20map+file.map',
    '/docs/example.js',
    (path) => {
      requestedPath = path;
      return JSON.stringify({version: 3, sources: [], names: [], mappings: ''});
    },
  );
  assert.equal(requestedPath, '/docs/source map+file.map');
  assert.equal(result.map.version, 3);
});

const markdown = [
  '# Compatibility',
  '',
  '[Provider](https://example.com/payments) and `inline <code>`.',
  '',
  '| State | Result |',
  '| --- | --- |',
  '| paid | approved |',
  '',
  '```ruby',
  'puts "<payment>"',
  '```',
  '',
  '{% cut "Details" %}',
  '',
  'Cut content.',
  '',
  '{% endcut %}',
  '',
  '{% list tabs %}',
  '',
  '- First',
  '',
  '  First tab content.',
  '',
  '- Second',
  '',
  '  Second tab content.',
  '',
  '{% endlist %}',
  '',
].join('\n');

test('Diplodoc renders tables, fenced code, links, cuts and tabs', () => {
  const transform = require('@diplodoc/transform');
  const {result} = transform(markdown);
  assert.match(result.html, /<table/);
  assert.match(result.html, /approved/);
  assert.match(result.html, /<pre/);
  assert.match(result.html, /&lt;payment&gt;/);
  assert.match(result.html, /href="https:\/\/example\.com\/payments"/);
  assert.match(result.html, /yfm-cut/);
  assert.match(result.html, /yfm-tabs/);
  assert.match(result.html, /Second tab content/);
});

test('Diplodoc translation extracts and composes representative Markdown', () => {
  const {extract, compose} = require('@diplodoc/translation');
  const {XMLValidator} = require('fast-xml-parser');
  const {skeleton, xliff} = extract(markdown, {
    source: {language: 'en', locale: 'US'},
    target: {language: 'ru', locale: 'RU'},
    skeletonPath: '/docs/example.skl.md',
    markdownPath: '/docs/example.md',
  });
  assert.equal(XMLValidator.validate(xliff), true);
  assert.match(xliff, /Compatibility/);
  assert.match(skeleton, /```ruby/);
  const composed = compose(skeleton, xliff, {useSource: true});
  assert.equal(composed.trim(), markdown.trim());
});
