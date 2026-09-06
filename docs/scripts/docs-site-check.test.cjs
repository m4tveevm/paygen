'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {checkSite, DOWNLOADS} = require('./docs-site-check.cjs');
const {normalize} = require('./docs-normalize.cjs');
const sha = 'a'.repeat(40);
const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'paygen-site-test-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  fs.mkdirSync(path.join(root, 'downloads/novapay'), {recursive: true});
  fs.mkdirSync(path.join(root, '_bundle'));
  const put = (name, value) => fs.writeFileSync(path.join(root, name), value);
  put('index.html', '<base href="./"><h1 id="intro">Paygen</h1><a href="provider-catalog.html?download=1#files">Catalog</a>');
  put('provider-catalog.html', '<h1 id="files">Downloads</h1><a href="downloads/novapay/fixtures.json">Fixture</a>');
  put('404.html', '<h1>404 not found</h1>');
  put('toc.js', 'window.__DATA__.data.toc = {"id":"random","items":[{"id":"random2","href":"index.html#intro"}]};');
  put('version.json', JSON.stringify({source_code_sha: sha, generator_version: '0.1.0'}));
  for (const name of DOWNLOADS) put(`downloads/novapay/${name}`, '{}');
  const providerManifest = (contents = {}) => put('downloads/novapay/manifest.json', JSON.stringify({
    source_code_sha: sha, generator_version: '0.1.0',
    files: Object.fromEntries(DOWNLOADS.map((name) => [name, digest(contents[name] || '{}')]))}, null, 2));
  providerManifest();
  return {root, put, providerManifest};
}

test('sealing and read-only verification bind every byte and accepted identity', (t) => {
  const {root, put} = fixture(t);
  const first = checkSite(root, '/paygen/', {seal: true, expectedSHA: sha});
  const before = fs.readFileSync(path.join(root, 'publication-manifest.json'));
  assert.deepEqual(checkSite(root, '/paygen/', {expectedDigest: first.artifact_sha256}), first);
  assert.throws(() => checkSite(root, '/paygen/', {expectedSHA: 'b'.repeat(40)}), /source identity/);
  assert.throws(() => checkSite(root, '/paygen/', {expectedDigest: 'b'.repeat(64)}), /accepted digest/);
  put('index.html', '<h1 id="intro">Edited after acceptance</h1>');
  assert.throws(() => checkSite(root, '/paygen/'), /manifest mismatch/);
  assert.deepEqual(fs.readFileSync(path.join(root, 'publication-manifest.json')), before);
  assert.throws(() => checkSite(root, '/paygen/', {seal: true}), /overwrite/);
});

for (const [name, target, message] of [
  ['query on a missing download', 'downloads/novapay/missing.json?raw=1', /broken asset/],
  ['missing anchor', 'provider-catalog.html#absent', /missing anchor/],
  ['root-relative link missing project prefix', '/provider-catalog.html', /project prefix/],
  ['encoded traversal', '/paygen/%2e%2e/private.txt', /project prefix/],
  ['protocol-relative target', '//evil.invalid/payload.js', /unsafe link/],
  ['script URL', 'javascript:alert(1)', /scheme/],
]) {
  test(`rejects ${name}, including links inside hydrated Diplodoc content`, (t) => {
    const {root, put} = fixture(t);
    const state = JSON.stringify({data: {html: `<h1 id="intro">Paygen</h1><a href="${target}">Link</a>`}})
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    put('index.html', `<script id="diplodoc-state" type="application/json">${state}</script>`);
    assert.throws(() => checkSite(root, '/paygen/', {seal: true}), message);
  });
}

test('checks prefix-correct absolute links, percent-encoded names and query strings', (t) => {
  const {root, put} = fixture(t);
  put('index.html', '<h1 id="intro">Paygen</h1><a href="/paygen/%70rovider-catalog.html?v=1#files">Catalog</a>');
  assert(checkSite(root, '/paygen/', {seal: true}));
});

test('checks CSS assets and srcset candidates', (t) => {
  const {root, put} = fixture(t);
  put('_bundle/style.css', 'body{background:url("missing.png?v=1")}');
  assert.throws(() => checkSite(root, '/paygen/', {seal: true}), /broken asset/);
  put('_bundle/style.css', 'body{background:url("data:image/svg+xml,a(b)c")}');
  put('index.html', '<h1 id="intro">Paygen</h1><img srcset="_bundle/absent.png 2x">');
  assert.throws(() => checkSite(root, '/paygen/', {seal: true}), /broken asset/);
});

for (const name of ['.env', 'source.zip', 'downloads/novapay/service.rb', '_bundle/.secret.js']) {
  test(`rejects unapproved publication entry ${name}`, (t) => {
    const {root, put} = fixture(t);
    put(name, 'not publishable');
    assert.throws(() => checkSite(root, '/paygen/', {seal: true}), /artifact/);
  });
}

test('rejects symbolic links and hard links, including a symlinked site root', (t) => {
  const {root} = fixture(t);
  const target = path.join(root, 'index.html');
  const link = path.join(root, 'alias.html');
  fs.symlinkSync(target, link);
  assert.throws(() => checkSite(root, '/paygen/', {seal: true}), /symlink/);
  fs.unlinkSync(link);
  fs.linkSync(target, link);
  assert.throws(() => checkSite(root, '/paygen/', {seal: true}), /hard-linked/);
  fs.unlinkSync(link);
  const rootLink = path.join(root, 'site-link');
  fs.symlinkSync(root, rootLink);
  assert.throws(() => checkSite(rootLink, '/paygen/', {seal: true}), /real directory/);
});

test('rejects changed download hashes and obvious secrets even with a matching download manifest', (t) => {
  const {root, put, providerManifest} = fixture(t);
  put('downloads/novapay/config.json', '{"key":"changed"}');
  assert.throws(() => checkSite(root, '/paygen/', {seal: true}), /download hash/);
  const content = '{"key":"sk_live_1234567890abcdef"}';
  put('downloads/novapay/config.json', content);
  providerManifest({'config.json': content});
  assert.throws(() => checkSite(root, '/paygen/', {seal: true}), /credential-like/);
});

test('normalizes renderer-generated IDs repeatably without changing content or links', (t) => {
  const {root, put} = fixture(t);
  put('index.html', '<code id="inline-code-id-randomone">sample inline-code-id-literal</code><a href="#inline-code-id-randomone">Copy</a>');
  normalize(root);
  const first = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  const toc = fs.readFileSync(path.join(root, 'toc.js'), 'utf8');
  put('index.html', '<code id="inline-code-id-randomtwo">sample inline-code-id-literal</code><a href="#inline-code-id-randomtwo">Copy</a>');
  normalize(root);
  assert.equal(fs.readFileSync(path.join(root, 'index.html'), 'utf8'), first);
  assert.equal(fs.readFileSync(path.join(root, 'toc.js'), 'utf8'), toc);
  assert.match(first, /href="#inline-code-id-1"/);
  assert.match(first, /sample inline-code-id-literal/);
});
