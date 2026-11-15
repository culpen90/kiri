# Guest kernel source offer

The Stowlark desktop guest kernel is Linux under GPL-2.0-only. The source
archive `Stowlark-VERSION-kernel-source.tar.xz` accompanies kernel binaries on
the [Stowlark releases page](https://github.com/culpen90/stowlark/releases).
Replace `VERSION` with the Stowlark release version. The archive contains the exact
upstream Linux release, the guest kernel patches already applied, the kernel
configuration, and the build inputs. It is also reproducible from this checkout
with:

```sh
scripts/ci/kernel-source.sh target/Stowlark-VERSION-kernel-source.tar.xz
```

This offer to provide the corresponding source is valid for three years from
the date of each release. The guest kernel is a separate work from the
Apache-2.0 Stowlark application.
