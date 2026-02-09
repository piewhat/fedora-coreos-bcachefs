# Fedora CoreOS with Bcachefs

This repository provides Fedora CoreOS images with Bcachefs built in.  

Images are updated automatically when either:

- A new bcachefs-tools tag is created
- A new Fedora CoreOS build is released

Zincati doesn’t currently support ostree-unverified-registry images, so this image includes a systemd service and timer to handle automatic updates. You can modify the timer to fit your needs.

---

## Available Images

| Stream   | Image |
|----------|-------|
| stable   | ghcr.io/piewhat/fedora-coreos-bcachefs:stable |
| testing  | ghcr.io/piewhat/fedora-coreos-bcachefs:testing |

You can also pull images tagged with a specific Bcachefs release:  

```
ghcr.io/piewhat/fedora-coreos-bcachefs:<bcachefs-tag>-<stream>
```

---

## Using the Image

To switch your system to use one of these images:

```
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/piewhat/fedora-coreos-bcachefs:stable
```

> Replace `stable` with `testing` if you want the testing stream.

After rebasing, reboot to apply the changes:

```
sudo systemctl reboot
```

Check that Bcachefs is loaded:

```
lsmod | grep bcachefs
```

You should see the `bcachefs` module listed.
