# Paygen Ruby application

This directory owns the Ruby application, Gemfile and lockfile, gemspec, Ruby
version, RSpec/RuboCop/Rake configuration, tests and packaging scripts.

From the repository root:

```sh
src/run setup
src/run cli doctor
src/run test
src/run package-test
src/run package
```

`src/run` selects this Gemfile and resolves CLI input/output paths from the
repository root, even when invoked as `./run` from this directory. Gem archives
are written into `src/`. After installing a built gem, use the `paygen` command
and `require 'paygen'` normally.

Application source and runtime assets are in `lib/`, the CLI entrypoint is
`bin/paygen`, and bundled provider recipes are in `recipes/`. Provider fixtures,
examples, research and the Diplodoc manual live outside this directory.

See [the development guide](../docs/content/development.md) for the full toolchain
and container commands. `LICENSE` is the copy shipped in the gem; package tests
check it against the repository license.
