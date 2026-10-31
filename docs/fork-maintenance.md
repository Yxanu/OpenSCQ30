# Experimental macOS fork maintenance

- Fork: https://github.com/Yxanu/OpenSCQ30
- Upstream: https://github.com/Oppzippy/OpenSCQ30
- Integrated branch: `master`; initial port branch: `macos-rfcomm`
- License: original GPL-3.0-or-later license and upstream history retained.
- Tested native alternative: https://github.com/Yxanu/soundcorebridge

## What is and is not verified

The original macOS commits add a Classic Bluetooth IOBluetooth backend, FFI,
run-loop ownership, service discovery, app metadata, and local build scripts.
They are preserved in the fork's history and integrated with current upstream.
On 2026-10-31, after synchronization, all 231 library tests passed locally on
Apple Silicon, including the macOS backend's UUID/error tests.

The port's live Liberty 5 connection previously failed during RFCOMM open and
has not been demonstrated working after synchronization. No macOS hardware
support claim follows from CI passing. SoundcoreBridge separately achieved
live Liberty 5 listening-mode and EQ control; carrying its connection strategy
back into this Rust backend requires a separate implementation and device test.

The `macOS` workflow checks formatting, library tests, CLI compilation and shell
syntax. Its manual `package_gui` option builds an ad-hoc-signed GUI ZIP as a
workflow artifact, not a notarized release. Existing upstream Linux/Windows/
Android workflows are retained. Dependabot proposes Actions updates weekly;
updates are reviewed, not automatically merged.

## Local checks

```shell
cargo fmt --all -- --check
cargo test --locked -p openscq30-lib --lib --features bundled-dependencies
cargo check --locked -p openscq30-cli --features bundled-dependencies
bash -n script/build_and_run.sh script/smoke_test_device.sh
```

Build the GUI with `./script/build_and_run.sh --package-only` without launching
it or acquiring a Bluetooth connection. Launch locally with the same script
without an option. For distribution details and limitations see `build-macos.md`.

## Remote and branch policy

Local clones use `origin` for the fork and `upstream` for the original project;
the upstream push URL is `DISABLED`. Configure new clones similarly:

```shell
git remote add upstream https://github.com/Oppzippy/OpenSCQ30.git
git remote set-url --push upstream DISABLED
git config remote.pushDefault origin
```

Branch from `master` for new macOS work. To synchronize upstream with a clean
worktree:

```shell
git fetch upstream
git switch -c maintenance/upstream-sync master
git merge upstream/master
cargo test --locked -p openscq30-lib --lib --features bundled-dependencies
git push -u origin maintenance/upstream-sync
```

Review via a PR against this fork. Do not force-push public history, open
upstream PRs as an automatic side effect, or transfer personal diagnostic
captures into test fixtures. Raw captures, database files, device identifiers,
HearID calibration and local sync-conflict copies remain local and unpublished.
