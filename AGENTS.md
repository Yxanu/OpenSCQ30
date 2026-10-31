# Working on the experimental macOS fork

- Read `docs/build-macos.md`, `docs/development.md` and
  `docs/fork-maintenance.md` before changing or publishing the macOS port.
- `origin` is `Yxanu/OpenSCQ30`; `upstream` is `Oppzippy/OpenSCQ30`.
  Work from the integrated `master` branch, keep the original GPL license and
  history, and do not push to upstream without explicit authorization.
- Verify with `cargo fmt --all -- --check`,
  `cargo test --locked -p openscq30-lib --lib --features bundled-dependencies`
  and `cargo check --locked -p openscq30-cli --features bundled-dependencies`.
  Use the repository-pinned Rust toolchain; keep `rust-toolchain.toml` aligned
  with upstream's `.build-tool-versions` when synchronizing.
- Use `script/build_and_run.sh` for the native GUI. Keep temporary, clean
  bundle staging and strict signature verification. `--package-only` must not
  launch an app or touch Bluetooth.
- A compiled native backend is not live-device support. The Rust Liberty 5
  connection is still experimental. SoundcoreBridge's successful hardware
  tests must not be presented as tests of this backend.
- Real-device tests are opt-in. Do not compete with another active settings
  client or write unverified firmware/OTA commands.
- Keep raw captures, personal device identifiers, HearID calibration, logs,
  databases, credentials, signing keys and local sync-conflict copies out of
  commits. Stage named files and review the diff; do not bulk-stage the workspace.
- Preserve unrelated local files. Synchronize upstream in a maintenance branch
  and merge reviewed updates without force-pushing published fork history.
