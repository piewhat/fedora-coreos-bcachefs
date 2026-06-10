# Fedora CoreOS with Bcachefs

This repository provides Fedora CoreOS images with the bcachefs kernel module and `bcachefs-tools`.

The module is compiled in a throwaway build stage against the exact kernel of the base image, and only the resulting `.ko` plus the userspace tools are layered on top. **No compiler, kernel headers, or DKMS ship in the final image, and every base package stays exactly as Fedora CoreOS shipped it.**

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

Images are additionally signed with a static cosign key (`certs/cosign.pub`)
so hosts can cryptographically verify every pull. The image ships the public
key at `/etc/pki/containers/fcos-bcachefs.pub` and the required
`registries.d` config, so after the first rebase only `policy.json` needs a
one-time edit:

```
# 1. (first install only) fetch the public key and registries.d config
sudo mkdir -p /etc/pki/containers /etc/containers/registries.d
curl -fsSL https://raw.githubusercontent.com/piewhat/fedora-coreos-bcachefs/main/certs/cosign.pub \
  | sudo tee /etc/pki/containers/fcos-bcachefs.pub
curl -fsSL https://raw.githubusercontent.com/piewhat/fedora-coreos-bcachefs/main/containers/fcos-bcachefs.yaml \
  | sudo tee /etc/containers/registries.d/fcos-bcachefs.yaml

# 2. require a valid signature for this repo in the containers policy
sudo jq '.transports.docker["ghcr.io/piewhat/fedora-coreos-bcachefs"] =
  [{"type":"sigstoreSigned",
    "keyPath":"/etc/pki/containers/fcos-bcachefs.pub",
    "signedIdentity":{"type":"matchRepository"}}]' \
  /etc/containers/policy.json | sudo tee /etc/containers/policy.json.new >/dev/null
sudo mv /etc/containers/policy.json.new /etc/containers/policy.json

# 3. rebase with enforcement
sudo bootc switch --enforce-container-sigpolicy ghcr.io/piewhat/fedora-coreos-bcachefs:stable
# or: sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/piewhat/fedora-coreos-bcachefs:stable
```

From then on every update pull fails closed unless the image carries a valid
signature from this repository's key. The keyless GitHub-OIDC signature
shown above exists alongside this for provenance auditing.

---

## Using the Image

To switch your system to use one of these images:

```
sudo bootc switch ghcr.io/piewhat/fedora-coreos-bcachefs:stable
```

> Replace `stable` with `testing` if you want the testing stream.
> `sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/piewhat/fedora-coreos-bcachefs:stable`
> works too; both track the same image and automatic updates work either way.

After rebasing, reboot to apply the changes:

```
sudo systemctl reboot
```

Check that bcachefs is available:

```
lsmod | grep bcachefs
bcachefs version
```

To roll back to your previous deployment at any time:

```
sudo rpm-ostree rollback
```

---

## Automatic updates

Zincati follows Fedora's official update graph, which only knows official
`quay.io/fedora/fedora-coreos` releases — on a custom image it could deploy
an official digest over this one and silently drop the bcachefs layer.
**Zincati is therefore masked in this image.**

Updates are handled by bootc's own `bootc-fetch-apply-updates.timer`
(enabled in this image), which checks the registry for a new image digest,
stages it, and reboots only when an update was actually pulled. A shipped
drop-in constrains it to a nightly window: daily at ~04:00 with up to 30
minutes of randomized delay, instead of bootc's default every-8-hours
cadence.

Adjust the schedule or behavior on a host — these edits live in `/etc`,
win over the image's drop-in, and persist across updates:

```
sudo systemctl edit bootc-fetch-apply-updates.timer
sudo systemctl edit bootc-fetch-apply-updates.service
```

To opt out of automatic updates entirely:

```
sudo systemctl disable --now bootc-fetch-apply-updates.timer
```

and update manually with `sudo bootc upgrade --apply` whenever you choose.

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
