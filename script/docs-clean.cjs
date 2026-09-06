'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = fs.realpathSync(process.cwd());
const output = path.join(root, 'docs', '_build');
assert.equal(path.relative(root, output), path.join('docs', '_build'));
if (fs.existsSync(output)) {
  assert(!fs.lstatSync(output).isSymbolicLink(), 'refusing to remove a symbolic-link output');
  fs.rmSync(output, {recursive: true});
}
