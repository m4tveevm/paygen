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
