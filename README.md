# Fedora CoreOS with Bcachefs

Fedora CoreOS images with the bcachefs kernel module and `bcachefs-tools`.
The module is prebuilt and signed, package layering with `rpm-ostree install`
works like stock FCOS. Images are rebuilt automatically when a new
bcachefs-tools tag or Fedora CoreOS build is released.

| Stream  | Image                                            | With the podman storage driver                          |
| ------- | ------------------------------------------------ | ------------------------------------------------------- |
| stable  | `ghcr.io/piewhat/fedora-coreos-bcachefs:stable`  | `ghcr.io/piewhat/fedora-coreos-bcachefs:stable-driver`  |
| testing | `ghcr.io/piewhat/fedora-coreos-bcachefs:testing` | `ghcr.io/piewhat/fedora-coreos-bcachefs:testing-driver` |
| next    | `ghcr.io/piewhat/fedora-coreos-bcachefs:next`    | `ghcr.io/piewhat/fedora-coreos-bcachefs:next-driver`    |

## Quick start

Rebase and reboot:

```
sudo rpm-ostree rebase --bypass-driver --reboot \
  ostree-unverified-registry:ghcr.io/piewhat/fedora-coreos-bcachefs:stable
```

> `--bypass-driver` is only needed while Zincati is still running (stock FCOS).

If Secure Boot is enabled, enroll the module signing certificate once,
then reboot and choose **Enroll MOK → Continue** in the blue MokManager
screen:

```
sudo mokutil --import /etc/pki/fcos-bcachefs/MOK.der
```

Verify:

```
lsmod | grep bcachefs
bcachefs version
```

## Automatic updates

rpm-ostree's built-in automatic updates are enabled
(`AutomaticUpdatePolicy=apply`): the stock `rpm-ostreed-automatic.timer`
checks for a new image daily at ~04:00 (with up to 30 minutes of randomized
delay) and reboots only when an update was staged. Layered packages are
reapplied on every update. Zincati is masked because it can't update ostree
container images.

The `next` stream (Fedora 45 and newer) uses bootc's
`bootc-fetch-apply-updates.timer` instead, with the same nightly window; edit
that timer rather than `rpm-ostreed-automatic.timer`. bootc does not reapply
packages layered with `rpm-ostree install`, so on `next` bake extra packages
into a derived image instead.

Adjust the schedule (persists across updates):

```
sudo systemctl edit rpm-ostreed-automatic.timer
```

Opt out entirely and update manually with `sudo rpm-ostree upgrade`:

```
sudo systemctl disable --now rpm-ostreed-automatic.timer
```

## Verified pulls (optional)

Images are signed with a static cosign key. The image ships everything
needed for verification — the public key, `registries.d` config, and a
`policy.json` requiring a valid signature for this repository — so once
you're running the image, one rebase enables fail-closed verification of
every future pull:

```
sudo rpm-ostree rebase --reboot \
  ostree-image-signed:docker://ghcr.io/piewhat/fedora-coreos-bcachefs:stable
```

A host with a locally-modified `/etc/containers/policy.json` keeps its own
version; merge the `transports.docker` entry from this repo's
`containers/policy.json` manually in that case.

Images also carry a keyless GitHub-OIDC signature for provenance:

```
cosign verify ghcr.io/piewhat/fedora-coreos-bcachefs:stable \
  --certificate-identity-regexp 'https://github.com/piewhat/fedora-coreos-bcachefs/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Podman bcachefs storage driver (optional)

Images tagged `-driver` ship podman rebuilt with the
[bcachefs-storage-driver](https://github.com/ticpu/bcachefs-storage-driver)
patched in; the plain stream tags ship Fedora's podman unchanged. The driver
is inert until you select it — `storage.conf` still defaults to overlay. To
opt in, rebase to a `-driver` tag:

```
sudo rpm-ostree rebase --reboot \
  ostree-unverified-registry:ghcr.io/piewhat/fedora-coreos-bcachefs:stable-driver
```

The rebuilt podman keeps Fedora's exact NVR, so `rpm -q podman` can't tell
the variants apart. Check that the driver is registered instead:

```
podman --storage-driver bcachefs --root /tmp/pmtest info
```

`"/tmp/pmtest" is not on a bcachefs filesystem` means it is registered; on a
stock image the same command reports the driver as unsupported. To use it,
point `graphroot` at a path on a bcachefs filesystem:

```toml
[storage]
driver = "bcachefs"
graphroot = "/var/lib/containers/storage"
```

Podman records the driver in a store the first time it initialises it. After
using `driver = "bcachefs"`, rebasing back to a stock image leaves podman
unable to open that store until you rebase to a `-driver` tag again or run
`podman system reset`.

## Tags

`stable`, `testing` and `next` track the matching Fedora CoreOS stream with
stock podman. Append `-driver` for the variant with the bcachefs storage
driver (`stable-driver`, `testing-driver`, `next-driver`). Both are also
published pinned to a specific bcachefs release, with or without the FCOS
version:

```
ghcr.io/piewhat/fedora-coreos-bcachefs:<bcachefs-tag>-<stream>[-driver]
ghcr.io/piewhat/fedora-coreos-bcachefs:<bcachefs-tag>-<fcos-version>-<stream>[-driver]
```

## Notes

- Enrolling the MOK means trusting every kernel module signed by this
  repository's key. Build the image with your own keys instead if you
  prefer (see `certs/README.md`).
- Verify the module signature with `modinfo -F signer bcachefs`.

## License

MIT
