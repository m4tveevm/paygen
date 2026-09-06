'use strict';

// The pinned renderer emits random clipboard IDs and TOC UUIDs. Normalize only
// those generated identifiers, not user timestamps, before sealing the site.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const cheerio = require('cheerio');

function stabilizeMarkup($) {
  const ids = new Map();
  $('code[id^="inline-code-id-"]').each((_index, element) => {
    const id = $(element).attr('id');
    if (!ids.has(id)) ids.set(id, `inline-code-id-${ids.size + 1}`);
    $(element).attr('id', ids.get(id));
  });
  $('[href], [aria-labelledby], [aria-describedby]').each((_index, element) => {
    for (const attribute of ['href', 'aria-labelledby', 'aria-describedby']) {
      const value = $(element).attr(attribute);
      if (!value) continue;
      if (attribute === 'href' && ids.has(value.slice(1)) && value.startsWith('#')) $(element).attr(attribute, `#${ids.get(value.slice(1))}`);
      else if (attribute !== 'href') $(element).attr(attribute, value.split(' ').map((id) => ids.get(id) || id).join(' '));
    }
  });
}

function normalize(root) {
  assert(fs.lstatSync(root).isDirectory(), 'site must be a real directory');
  for (const name of fs.readdirSync(root).filter((name) => name.endsWith('.html'))) {
    const file = path.join(root, name);
    assert(fs.lstatSync(file).isFile(), 'HTML must be a regular file');
    const $ = cheerio.load(fs.readFileSync(file, 'utf8'));
    stabilizeMarkup($);
    const script = $('script#diplodoc-state');
    if (script.length) {
      const state = JSON.parse(script.text().replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'));
      if (state.data.html) {
        const article = cheerio.load(state.data.html, null, false);
        stabilizeMarkup(article);
        state.data.html = article.html();
      }
      script.text(JSON.stringify(state).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'));
    }
    fs.writeFileSync(file, $.html());
  }
  const file = path.join(root, 'toc.js');
  assert(fs.lstatSync(file).isFile(), 'TOC must be a regular file');
  const text = fs.readFileSync(file, 'utf8');
  const match = text.match(/^window\.__DATA__\.data\.toc = (.*);\s*$/s);
  assert(match, 'unexpected Diplodoc TOC format');
  const toc = JSON.parse(match[1]);
  function visit(value, location) {
    if (!value || typeof value !== 'object') return;
    if (Object.hasOwn(value, 'id')) value.id = crypto.createHash('sha256').update(location).digest('hex').slice(0, 32);
    for (const [key, child] of Object.entries(value)) visit(child, `${location}/${key}`);
  }
  visit(toc, 'toc');
  fs.writeFileSync(file, `window.__DATA__.data.toc = ${JSON.stringify(toc)};`);

  // CLI 5.39.4 ships a KaTeX stylesheet whose hashed font files are absent.
  // Use the locked, security-patched KaTeX CSS and its matching font bytes.
  const latex = path.join(root, '_bundle', 'latex-extension.css');
  if (fs.existsSync(latex)) {
    assert(fs.lstatSync(latex).isFile(), 'LaTeX CSS must be a regular file');
    const katex = path.dirname(require.resolve('katex/package.json'));
    fs.copyFileSync(path.join(katex, 'dist/katex.min.css'), latex);
    const fonts = path.join(root, '_bundle/fonts');
    assert(!fs.lstatSync(fonts, {throwIfNoEntry: false})?.isSymbolicLink(), 'font directory must not be a symlink');
    fs.mkdirSync(fonts, {recursive: true});
    for (const name of fs.readdirSync(path.join(katex, 'dist/fonts')).sort()) {
      assert(/^KaTeX_[a-zA-Z0-9_-]+\.(?:woff2?|ttf)$/.test(name), 'unexpected KaTeX asset');
      fs.copyFileSync(path.join(katex, 'dist/fonts', name), path.join(fonts, name));
    }
    fs.copyFileSync(path.join(katex, 'LICENSE'), path.join(fonts, 'LICENSE.txt'));
  }
}

if (require.main === module) normalize(path.resolve(process.argv[2] || 'docs/_build'));
module.exports = {normalize};
