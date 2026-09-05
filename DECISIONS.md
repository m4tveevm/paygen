# Decisions

1. User confirmed implementation of Paygen, not only automation prompts.
2. Main was initialized with a minimal README because the GitHub repository had
   no commits or branches. All implementation is on dev/paygen-reference.
3. Source document prose is not executable. Ambiguous payout semantics are
   explicit profiles or corrections. Unresolved semantics block executable output.
4. Runtime outcomes are structured hashes and backend hooks form the integration
   seam. The unpublished production BaseService is represented by a test harness.
5. Curated official subsets do not claim full API coverage. Each identifies
   upstream source, version, license and local SHA256.
6. Signed callbacks require raw body bytes. Process-local state is a test default;
   the application must provide durable state for a production deployment.
7. No live provider calls are part of tests. Remote verifier targets are loopback
   simulators only; offline fault evidence is kept distinct from remote smoke.
8. Ruby/Docker execution must be proven by CI or a suitable runtime, not inferred
   from source review. Status stays CONTINUE until final gates are satisfied.
9. Documentation keeps the requested Node 22 runtime. Diplodoc 5.39.4 and its
   compatible extensions are pinned; npm 11.9.0 and strict engine checks prevent
   silently adopting Node 24-only releases. Security overrides use patched
   upstream packages. The docs-only preload adapts five explicit legacy CommonJS
   import contracts to their current exports, without vendoring parser code.
   Node tests verify parser APIs, URI decoding, rendered tables/code/links/tabs
   and XLIFF round trips; npm audit remains a required gate.
10. CI uses explicit Bash pipefail for the completion log pipeline. A green job
    without the script's final PASS record is insufficient evidence. The docs
    container must serve a page containing Paygen, beyond merely starting nginx.

Documentation version boundary: [upstream Node 24 migration](https://github.com/diplodoc-platform/cli/commit/cf937da656f82b171bc27c1f0d6d1479b8f4fbc7). The patched Markdown parser
keeps its APIs but changes internal module packaging; see its [changelog](https://github.com/markdown-it/markdown-it/blob/master/CHANGELOG.md).
