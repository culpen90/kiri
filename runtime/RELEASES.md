# Building Stowlark releases

Stowlark is a fork of [Kiri](https://github.com/libracoder/kiri). Check
[GitHub Releases](https://github.com/stowlark/stowlark/releases) for published
Stowlark artifacts and release notes.

Run the release commands from `runtime/` in the checkout. Set the workspace
version in `Cargo.toml` to the release tag's version
before building. Use the same checkout and its `Cargo.lock` for every
platform. The build also verifies the pinned Docker CLI, Compose and buildx
downloads before bundling them.

- **macOS:** Build the VM kernel, disk and guest with `cargo xtask kernel`,
  `cargo xtask disk` and `cargo xtask guest`. Then run `cargo xtask release`
  for the application archive and `cargo xtask dmg` for the disk image.
  See [Building from source](docs/development.md) for architecture flags.
- **Windows:** Run `cargo xtask msi` for x86-64 or `cargo xtask msi --arch arm64`
  for Windows on Arm. Both installers use Stowlark's MSI identity and install
  under `%LOCALAPPDATA%\Stowlark`.
- **Linux:** Run `scripts/ci/linux-build.sh` on Ubuntu, or
  `scripts/ci/linux-packages.sh` on a Mac with a Docker-compatible engine.
  The script writes the packages and `SHA256SUMS-linux` to `target/packages`.
  Use `packaging/linux/test-host.sh` to install and exercise them on a test
  machine with systemd.
- **Android:** Run `scripts/build-android.sh` with an Android NDK. The bundle
  and its checksum are written to `target/android-dist`.
  See [Android Linux workspaces](docs/android.md).

The macOS build uses an ad hoc signature when a Developer ID is unavailable.
For a signed and notarized build, set `STOWLARK_SIGN_IDENTITY` and
`STOWLARK_NOTARY_PROFILE` on a machine with the corresponding credentials.
Check the app with `codesign --verify --deep --strict -v Stowlark.app`.
An MSI needs a separate Authenticode signing step if distributing it with
a publisher signature.

Mac and Windows builds generate update manifests when
`STOWLARK_RELEASE_BASE` is set to the publisher's download directory.
Use `STOWLARK_RELEASE_NOTES` or `STOWLARK_RELEASE_NOTES_URL` to add release
notes to those manifests. Set `STOWLARK_UPDATE_URL` when launching the app
to opt in to the HTTPS manifest for that platform and architecture.
