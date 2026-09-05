'use strict';

// Diplodoc's CommonJS plugins still import markdown-it 13 internals. Version 14
// preserves those APIs in ESM files; Node >=22.13 can load them synchronously.
// Keep the security-patched upstream implementation and adapt only these legacy
// import contracts. This bridge is preloaded only by the documentation commands.
const Module = require('node:module');
const load = Module._load;
const legacyImports = new Map([
  ['markdown-it/lib/common/utils', ['markdown-it/lib/common/utils.mjs', false]],
  ['markdown-it/lib/token', ['markdown-it/lib/token.mjs', true]],
  ['markdown-it/lib/renderer', ['markdown-it/lib/renderer.mjs', true]],
  ['markdown-it/lib/rules_inline/state_inline', ['markdown-it/lib/rules_inline/state_inline.mjs', true]],
  ['decode-uri-component', ['decode-uri-component', true]],
]);

Module._load = function loadDocsDependency(request, parent, isMain) {
  const legacy = legacyImports.get(request);
  if (!legacy) return load.call(this, request, parent, isMain);

  const [upstream, useDefault] = legacy;
  const value = load.call(this, upstream, parent, isMain);
  return useDefault ? value.default : value;
};
