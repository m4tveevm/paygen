'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(process.argv[2] || 'docs/_build');
const basePath = process.argv[3] || '/paygen/';
assert.match(basePath, /^\/[a-z0-9._/-]+\/$/i, 'base path must start and end with /');
assert(fs.statSync(root).isDirectory(), `missing site directory: ${root}`);

const entries = [];
function walk(directory) {
  for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
    const absolute = path.join(directory, entry.name);
    const relative = path.relative(root, absolute).split(path.sep).join('/');
    assert(!entry.isSymbolicLink(), `symlink is not publishable: ${relative}`);
    if (entry.isDirectory()) walk(absolute);
    else {
      assert(entry.isFile(), `non-regular artifact entry: ${relative}`);
      assert(fs.statSync(absolute).nlink === 1, `hard-linked artifact entry: ${relative}`);
      entries.push(relative);
    }
  }
}
walk(root);

const forbidden = /(^|\/)(\.git|\.env|node_modules|source|state)(\/|$)|\.(pem|key)$/i;
for (const relative of entries) assert(!forbidden.test(relative), `forbidden artifact path: ${relative}`);
assert(entries.includes('index.html'));
assert(entries.includes('provider-catalog.html'));
assert(entries.includes('404.html'));
assert(entries.includes('version.json'));

for (const relative of entries.filter((name) => name.endsWith('.html'))) {
  const html = fs.readFileSync(path.join(root, relative), 'utf8');
  for (const match of html.matchAll(/(?:href|src)=["']([^"'#?]+)["']/g)) {
    const target = match[1];
    if (/^(?:https?:|mailto:|data:)/.test(target)) continue;
    const base = html.match(/<base href=["']([^"']+)/)?.[1] || './';
    const resolved = path.resolve(path.dirname(path.join(root, relative)), base, target);
    assert(resolved === root || resolved.startsWith(`${root}${path.sep}`), `link escapes site: ${relative} -> ${target}`);
    assert(fs.existsSync(resolved), `broken asset/link: ${relative} -> ${target}`);
  }
}

const notFound = fs.readFileSync(path.join(root, '404.html'), 'utf8');
assert.match(notFound, /404|not found/i, '404 page must identify a missing page');

const manifestPath = path.join(root, 'publication-manifest.json');
const files = entries.filter((name) => name !== 'publication-manifest.json').sort();
const hashes = Object.fromEntries(files.map((name) => [name, crypto.createHash('sha256').update(fs.readFileSync(path.join(root, name))).digest('hex')]));
const version = JSON.parse(fs.readFileSync(path.join(root, 'version.json')));
const manifest = {
  schema_version: 1,
  source_code_sha: version.source_code_sha,
  docs_sha: crypto.createHash('sha256').update(files.filter((name) => name.endsWith('.html')).map((name) => hashes[name]).join('\n')).digest('hex'),
  artifact_sha256: crypto.createHash('sha256').update(files.map((name) => `${hashes[name]}  ${name}`).join('\n')).digest('hex'),
  base_path: basePath,
  files: hashes,
};
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(JSON.stringify({ok: true, base_path: basePath, files: files.length, artifact_sha256: manifest.artifact_sha256}));
