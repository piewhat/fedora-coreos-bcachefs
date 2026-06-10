# Fedora CoreOS with Bcachefs

This repository provides Fedora CoreOS images with the bcachefs kernel module and `bcachefs-tools`.

Images are rebuilt automatically when either:

- A new bcachefs-tools tag is created
- A new Fedora CoreOS build is released

---

## Available Images

| Stream  | Image                                          |
| ------- | ---------------------------------------------- |
| stable  | `ghcr.io/piewhat/fedora-coreos-bcachefs:stable`  |
| testing | `ghcr.io/piewhat/fedora-coreos-bcachefs:testing` |

You can also pull images pinned to a specific bcachefs release, with or without the FCOS version:

```
ghcr.io/piewhat/fedora-coreos-bcachefs:<bcachefs-tag>-<stream>
ghcr.io/piewhat/fedora-coreos-bcachefs:<bcachefs-tag>-<fcos-version>-<stream>
```

---

## Image signing

Images are signed with [cosign](https://docs.sigstore.dev/) using keyless GitHub OIDC signing. Verify any tag with:

```
cosign verify ghcr.io/piewhat/fedora-coreos-bcachefs:stable \
  --certificate-identity-regexp 'https://github.com/piewhat/fedora-coreos-bcachefs/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

### Verified pulls (ostree-image-signed)

Images are additionally signed with a static cosign key (`certs/cosign.pub`).
The image ships everything needed for verification: the public key at
`/etc/pki/containers/fcos-bcachefs.pub`, the `registries.d` config, and a
`policy.json` that requires a valid signature for this repository (and
changes nothing else). So enabling verification is just two rebases:

```
# from stock FCOS (zincati still running, hence --bypass-driver):
sudo rpm-ostree rebase --bypass-driver --reboot \
  ostree-unverified-registry:ghcr.io/piewhat/fedora-coreos-bcachefs:stable

# after the reboot, flip the origin to the signed transport — the
# verification config is now on disk, and the layers are already cached:
sudo rpm-ostree rebase --reboot \
  ostree-image-signed:docker://ghcr.io/piewhat/fedora-coreos-bcachefs:stable
```

From then on every update pull fails closed unless the image carries a
valid signature from this repository's key. Verify the state of a host
with `rpm-ostree status` (the origin shows `ostree-image-signed:`).

A host with locally-modified `/etc/containers/policy.json` keeps its own
version (ostree three-way /etc merge); merge the `transports.docker` entry
from this repo's `containers/policy.json` manually in that case.

The keyless GitHub-OIDC signature shown above exists alongside the static
key for provenance auditing.

---

## Using the Image

To switch your system to use one of these images:

```
sudo rpm-ostree rebase --bypass-driver --reboot \
  ostree-unverified-registry:ghcr.io/piewhat/fedora-coreos-bcachefs:stable
```

> Replace `stable` with `testing` if you want the testing stream.
> `--bypass-driver` is only needed while Zincati is still running (stock FCOS).

After rebasing, reboot to apply the changes:

```
sudo systemctl reboot
```

Check that bcachefs is available:

```
lsmod | grep bcachefs
bcachefs version
```

---

## Automatic updates

Zincati follows Fedora's official update graph, which only knows official
`quay.io/fedora/fedora-coreos` releases — on a custom image it could deploy
an official digest over this one and silently drop the bcachefs layer.
**Zincati is therefore masked in this image.**

Updates are handled by a bundled systemd timer that runs
`rpm-ostree upgrade --reboot` daily at ~04:00 (with up to 30 minutes of
randomized delay). Layered packages are reapplied on every update. Adjust
the schedule or behavior — these edits live in `/etc` and persist across
updates:

```
sudo systemctl edit rpm-ostreed-oci-update.timer
sudo systemctl edit rpm-ostreed-oci-update.service
```

To opt out of automatic updates entirely:

```
sudo systemctl disable --now rpm-ostreed-oci-update.timer
```

and update manually with `sudo rpm-ostree upgrade` whenever you choose.

---

## Secure Boot

The bcachefs module is signed at build time with this repository's own
signing key (see `certs/`). Fedora's kernel lockdown policy under Secure
Boot only loads modules whose signature chains to a key in the platform
keyring — which includes Machine Owner Keys (MOK) that you enroll yourself.

To use this image with Secure Boot enabled, enroll the certificate once:

```
sudo mokutil --import /etc/pki/fcos-bcachefs/MOK.der
```

Set a one-time password when prompted, reboot, and in the blue MokManager
screen choose **Enroll MOK → Continue**, confirm, and enter that password.
This is a one-time step; the enrollment persists across all future image
updates.

You can verify the module's signature with:

```
modinfo -F signer bcachefs
```

> **Trust note:** enrolling the MOK means trusting every kernel module
> signed by this repository's key. If you'd rather not, you can build the
> image yourself with your own key (see `certs/README.md`) — or disable
> Secure Boot, or enroll your own MOK and sign the module locally.

---

## License

MIT
