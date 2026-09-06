# Paygen Ruby application

This directory owns the Ruby application, Gemfile and lockfile, gemspec, Ruby
version, RSpec/RuboCop/Rake configuration, tests and packaging scripts.

For checkout development, select Ruby 4.0.6 from `.ruby-version` in this
directory (the runner does not select Ruby), then run in Bash from the
repository root:

```sh
gem install bundler -v 4.0.20
src/run setup
src/run cli doctor
src/run test
src/run audit --update
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

This README is also included in the installed gem; checkout-only commands above
require the full repository. See [the development guide](https://m4tveevm.github.io/paygen/development.html) for the full toolchain
and container commands. `LICENSE` is the copy shipped in the gem; package tests
check it against the repository license.
