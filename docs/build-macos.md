# Building on macOS

macOS support is experimental. This fork adds a native Classic Bluetooth RFCOMM backend using Apple's `IOBluetooth` framework and packages the existing desktop GUI as a normal `.app` bundle.

The current Rust port has not completed a successful live Liberty 5 control
test. The native Swift app in [Yxanu/soundcorebridge](https://github.com/Yxanu/soundcorebridge)
has separately verified listening modes and EQ; those results must not be
attributed to this Rust backend. See [fork maintenance](fork-maintenance.md).

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools (`xcode-select --install`)
- [rustup](https://rustup.rs/); the repository selects Rust 1.99.1 via `rust-toolchain.toml`
- a Soundcore device already paired and connected in macOS Bluetooth settings

The Soundcore mobile app should be fully closed while OpenSCQ30 connects. Many Soundcore devices accept only one settings connection at a time.

## Build and run the app

```shell
./script/build_and_run.sh
```

The script builds the existing `openscq30-gui`, embeds its runtime resources,
stages a clean temporary `OpenSCQ30.app`, ad-hoc signs and verifies it, and
launches it. It creates the portable `build-output/OpenSCQ30-macOS.zip` from
that exact clean bundle. Temporary staging avoids File Provider attaching
FinderInfo and invalidating signatures under synced folders. The bundle includes
the Bluetooth privacy descriptions required by macOS.

Useful modes:

```shell
./script/build_and_run.sh --verify
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --package-only
OPENSCQ30_BUILD_PROFILE=release ./script/build_and_run.sh
```

The first launch may cause macOS to ask for Bluetooth access. It can be changed later under **System Settings > Privacy & Security > Bluetooth**.

## Liberty 5 smoke test

Liberty 5 is model `SoundcoreA3957`. To exercise the same backend through the CLI without changing your regular OpenSCQ30 database:

```shell
OPENSCQ30_MAC_ADDRESS="AA:BB:CC:DD:EE:FF" \
OPENSCQ30_DEVICE_MODEL="SoundcoreA3957" \
./script/smoke_test_device.sh
```

The address is only used locally and is not written to the repository.

## Implementation notes

The macOS backend:

- lists paired, currently connected devices via `IOBluetoothDevice`;
- reads cached SDP records (and refreshes them when needed);
- expands 16-, 32-, and 128-bit Bluetooth UUIDs before applying OpenSCQ30's existing service-selection logic;
- owns the RFCOMM channel on a dedicated run-loop thread and forwards packets into Tokio channels;
- links only system frameworks; no private Soundcore API or third-party Bluetooth daemon is required.

On some recent macOS versions, `openRFCOMMChannelSync` can fail with `kIOReturnError` (`0xe00002bc`) even though SDP discovery succeeds. Apple developers have reported the same framework behavior in [Apple Developer Forums thread 786421](https://developer.apple.com/forums/thread/786421). First rule out another settings client (especially the iPhone Soundcore app), reconnect the earbuds, and retry. This is the main remaining live-device risk for the experimental port.

## Fork maintenance and distribution

Keep the original project as the `upstream` remote and use a maintenance branch
to synchronize without rewriting published fork history:

```shell
git fetch upstream
git switch -c maintenance/upstream-sync master
git merge upstream/master
cargo test --locked -p openscq30-lib --lib --features bundled-dependencies
```

The local bundle is ad-hoc signed, not Developer ID-signed or notarized. An
Apple-notarized public release needs Developer ID signing, hardened runtime,
notarization and supported-macOS testing. No public macOS release is implied by
the upstream release tags inherited by this fork.
