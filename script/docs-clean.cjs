'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = fs.realpathSync(path.join(__dirname, '..'));
assert.equal(fs.realpathSync(process.cwd()), root, 'run documentation builds from the repository root');
assert(!fs.lstatSync(path.join(root, 'docs')).isSymbolicLink(), 'refusing a symbolic-link docs directory');
const output = path.join(root, 'docs', '_build');
assert.equal(path.relative(root, output), path.join('docs', '_build'));
if (fs.existsSync(output) || fs.lstatSync(output, {throwIfNoEntry: false})) {
  assert(fs.lstatSync(output).isDirectory(), 'refusing to remove a non-directory output');
  fs.rmSync(output, {recursive: true});
}
