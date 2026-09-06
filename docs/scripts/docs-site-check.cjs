'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const cheerio = require('cheerio');

const DOWNLOADS = ['INTEGRATION.md', 'fixtures.json', 'config.json', 'diagnostics.json', 'provenance.json'];
const ORIGIN = 'https://pages.invalid';
const sha256 = (body) => crypto.createHash('sha256').update(body).digest('hex');
const readJSON = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));

function checkSite(root, basePath, {seal = false, expectedSHA, expectedDigest} = {}) {
  root = path.resolve(root);
  assert.match(basePath, /^\/(?:[a-z0-9_-]+\/)+$/i, 'use an explicit project Pages prefix');
  assert(fs.lstatSync(root).isDirectory(), 'site must be a real directory');
  const entries = [];
  function walk(directory) {
    for (const name of fs.readdirSync(directory).sort()) {
      const absolute = path.join(directory, name);
      const relative = path.relative(root, absolute).split(path.sep).join('/');
      const stat = fs.lstatSync(absolute);
      assert(!stat.isSymbolicLink(), `symlink is not publishable: ${relative}`);
      assert(!name.startsWith('.'), `hidden artifact entry: ${relative}`);
      if (stat.isDirectory()) walk(absolute);
      else {
        assert(stat.isFile() && stat.nlink === 1, `non-regular or hard-linked artifact: ${relative}`);
        entries.push(relative);
      }
    }
  }
  walk(root);

  // Explicit publication surface: no arbitrary source trees, archives or uploads.
  const allowed = /^(?:[a-z0-9-]+\.html|toc\.js|(?:version|publication-manifest)\.json|_bundle\/[a-zA-Z0-9_.-]+\.(?:js|css|woff2?|ttf|svg|png)|_bundle\/fonts\/(?:KaTeX_[a-zA-Z0-9_-]+\.(?:woff2?|ttf)|LICENSE\.txt)|downloads\/novapay\/(?:INTEGRATION\.md|fixtures\.json|config\.json|diagnostics\.json|provenance\.json|manifest\.json))$/;
  for (const relative of entries) assert(allowed.test(relative), `unapproved artifact path: ${relative}`);
  for (const required of ['index.html', 'provider-catalog.html', '404.html', 'version.json', 'toc.js', ...DOWNLOADS.map((name) => `downloads/novapay/${name}`), 'downloads/novapay/manifest.json']) {
    assert(entries.includes(required), `missing publication file: ${required}`);
  }

  const version = readJSON(path.join(root, 'version.json'));
  assert.match(version.source_code_sha, /^[0-9a-f]{40}$/, 'missing full source identity');
  if (expectedSHA) assert.equal(version.source_code_sha, expectedSHA, 'unexpected source identity');
  const provider = readJSON(path.join(root, 'downloads/novapay/manifest.json'));
  assert.equal(provider.source_code_sha, version.source_code_sha, 'provider source identity mismatch');
  assert.equal(provider.generator_version, version.generator_version, 'generator version mismatch');
  assert.deepEqual(Object.keys(provider.files).sort(), [...DOWNLOADS].sort(), 'provider download allowlist mismatch');
  for (const name of DOWNLOADS) {
    const body = fs.readFileSync(path.join(root, 'downloads/novapay', name), 'utf8');
    assert.equal(sha256(body), provider.files[name], `provider download hash mismatch: ${name}`);
    // Defense in depth, not a claim that a scanner can prove absence of secrets.
    assert(!/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:ghp_[a-zA-Z0-9]{20,}|github_pat_[a-zA-Z0-9_]{20,}|sk_live_[a-zA-Z0-9]{12,})/.test(body), `credential-like content: ${name}`);
    assert(!/\b\d{13,19}\b/.test(body), `unredacted long payment identifier: ${name}`);
    assert(!/\/(?:Users|home|private\/tmp)\//.test(body), `local filesystem path: ${name}`);
  }

  const documents = new Map();
  for (const relative of entries.filter((name) => name.endsWith('.html'))) {
    const $ = cheerio.load(fs.readFileSync(path.join(root, relative), 'utf8'));
    const serialized = $('script#diplodoc-state').text();
    // Diplodoc hydrates article content from this escaped JSON, not the DOM.
    if (serialized) {
      const state = JSON.parse(serialized.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'));
      $('body').append(state.data.html || '');
    }
    const base = new URL($('base').attr('href') || './', `${ORIGIN}${basePath}${relative}`);
    assert.equal(base.origin, ORIGIN, `external base URL: ${relative}`);
    assert(base.pathname.startsWith(basePath), `base URL escapes prefix: ${relative}`);
    documents.set(relative, {$, base});
  }

  function checkLink(relative, target, base, {fragment = true} = {}) {
    if (!target || /^(?:https?:|mailto:|tel:|data:)/i.test(target)) return;
    assert(!target.startsWith('//') && !target.includes('\\'), `unsafe link: ${relative} -> ${target}`);
    const url = new URL(target, base);
    assert.equal(url.origin, ORIGIN, `unsupported link scheme: ${relative} -> ${target}`);
    const pathname = decodeURIComponent(url.pathname);
    assert(pathname.startsWith(basePath), `link escapes project prefix: ${relative} -> ${target}`);
    let name = pathname.slice(basePath.length);
    if (!name || name.endsWith('/')) name += 'index.html';
    assert(entries.includes(name), `broken asset/link: ${relative} -> ${target}`);
    if (fragment && url.hash && documents.has(name)) {
      const id = decodeURIComponent(url.hash.slice(1));
      const {$} = documents.get(name);
      assert($('[id], a[name]').toArray().some((element) => $(element).attr('id') === id || $(element).attr('name') === id), `missing anchor: ${relative} -> ${target}`);
    }
  }
  for (const [relative, {$, base}] of documents) {
    $('[href], [src]').each((_i, element) => {
      if (element.tagName === 'base') return;
      for (const attribute of ['href', 'src']) checkLink(relative, $(element).attr(attribute), base);
    });
    $('[srcset]').each((_i, element) => {
      for (const candidate of $(element).attr('srcset').split(',')) checkLink(relative, candidate.trim().split(/\s+/)[0], base);
    });
  }
  for (const relative of entries.filter((name) => name.endsWith('.css'))) {
    const css = fs.readFileSync(path.join(root, relative), 'utf8');
    for (const match of css.matchAll(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)/g)) {
      const target = (match[1] ?? match[2] ?? match[3]).trim();
      if (target.startsWith('#')) continue;
      checkLink(relative, target, `${ORIGIN}${basePath}${relative}`, {fragment: false});
    }
  }
  const tocText = fs.readFileSync(path.join(root, 'toc.js'), 'utf8');
  const tocMatch = tocText.match(/^window\.__DATA__\.data\.toc = (.*);\s*$/s);
  assert(tocMatch, 'unexpected TOC format');
  function checkToc(value) {
    if (!value || typeof value !== 'object') return;
    if (value.href) {
      const target = new URL(value.href, `${ORIGIN}${basePath}`);
      assert(!decodeURIComponent(target.pathname).endsWith('/404.html'), '404 page must not appear in navigation');
      checkLink('toc.js', value.href, `${ORIGIN}${basePath}`);
    }
    Object.values(value).forEach(checkToc);
  }
  checkToc(JSON.parse(tocMatch[1]));
  assert.match(documents.get('404.html').$.text(), /404|not found/i, '404 page must identify a missing page');

  const manifestPath = path.join(root, 'publication-manifest.json');
  const files = entries.filter((name) => name !== 'publication-manifest.json').sort();
  const hashes = Object.fromEntries(files.map((name) => [name, sha256(fs.readFileSync(path.join(root, name)))]));
  const manifest = {
    schema_version: 2,
    source_code_sha: version.source_code_sha,
    html_sha256: sha256(files.filter((name) => name.endsWith('.html')).map((name) => `${hashes[name]}  ${name}`).join('\n')),
    artifact_sha256: sha256(files.map((name) => `${hashes[name]}  ${name}`).join('\n')),
    base_path: basePath,
    files: hashes,
  };
  if (expectedDigest) assert.equal(manifest.artifact_sha256, expectedDigest, 'artifact differs from accepted digest');
  if (seal) {
    assert(!fs.existsSync(manifestPath), 'refusing to overwrite an existing publication manifest');
    fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, {flag: 'wx'});
  } else {
    assert.deepEqual(readJSON(manifestPath), manifest, 'publication manifest mismatch; rebuild and review the artifact');
  }
  return manifest;
}

if (require.main === module) {
  assert(process.argv.slice(4).every((arg) => arg === '--seal'), 'unknown check argument');
  const manifest = checkSite(process.argv[2] || '_build', process.argv[3] || '/paygen/', {
    seal: process.argv.includes('--seal'), expectedSHA: process.env.PAYGEN_SOURCE_SHA,
    expectedDigest: process.env.PAYGEN_ACCEPTED_ARTIFACT_SHA256,
  });
  console.log(JSON.stringify({ok: true, base_path: manifest.base_path, files: Object.keys(manifest.files).length, artifact_sha256: manifest.artifact_sha256}));
}
module.exports = {checkSite, DOWNLOADS};
