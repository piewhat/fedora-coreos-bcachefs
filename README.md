# Fedora CoreOS with Bcachefs

Fedora CoreOS images with the bcachefs kernel module and `bcachefs-tools`.
The module is prebuilt and signed. Images are rebuilt automatically when a new
bcachefs-tools tag or Fedora CoreOS build is released.

| Stream  | Image                                            |
| ------- | ------------------------------------------------ |
| stable  | `ghcr.io/piewhat/fedora-coreos-bcachefs:stable`  |
| testing | `ghcr.io/piewhat/fedora-coreos-bcachefs:testing` |

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

A bundled timer runs `rpm-ostree upgrade --reboot` daily at ~04:00 (with up
to 30 minutes of randomized delay). Zincati is masked, as it can't update ostree container images.

Adjust the schedule or behavior (persists across updates):

```
sudo systemctl edit rpm-ostreed-oci-update.timer
```

Opt out entirely and update manually with `sudo rpm-ostree upgrade`:

```
sudo systemctl disable --now rpm-ostreed-oci-update.timer
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

## Tags

Pinned to a bcachefs release, with or without the FCOS version:

```
ghcr.io/piewhat/fedora-coreos-bcachefs:<bcachefs-tag>-<stream>
ghcr.io/piewhat/fedora-coreos-bcachefs:<bcachefs-tag>-<fcos-version>-<stream>
```

## Notes

- Enrolling the MOK means trusting every kernel module signed by this
  repository's key. Build the image with your own keys instead if you
  prefer (see `certs/README.md`).
- Verify the module signature with `modinfo -F signer bcachefs`.

## License

MIT
