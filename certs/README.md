# Module signing key

`MOK.der` in this directory is the **public** certificate used to sign the
bcachefs kernel module for Secure Boot. The matching private key lives only
in the `MODULE_SIGNING_KEY` GitHub Actions secret and is mounted into the
build as a BuildKit secret (it never enters an image layer or the build
cache).

The Dockerfile requires `certs/MOK.der` to exist, so generate the keypair
before the first build:

```sh
openssl req -new -x509 -newkey rsa:4096 -nodes -days 36500 \
  -subj "/CN=fedora-coreos-bcachefs kernel module signing key/" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout MOK.priv \
  -out certs/MOK.der -outform DER

# private key -> GitHub secret, then destroy the local copy (or store it
# somewhere safe offline — losing it means generating a new key and every
# user re-enrolling)
gh secret set MODULE_SIGNING_KEY < MOK.priv
shred -u MOK.priv

git add certs/MOK.der
```

If `MODULE_SIGNING_KEY` is unset (forks, local builds), the build still
succeeds and ships an unsigned module — Secure Boot machines simply won't
load it.

**Trust model:** anyone who enrolls this certificate as a MOK trusts every
kernel module ever signed with the private key. Treat the GitHub secret
accordingly: it is effectively a key to your users' Secure Boot machines.
Rotating it means users must enroll the new certificate.

# Image signing key (cosign)

`cosign.pub` is the public half of the static cosign keypair used to sign
the container images themselves (separate from the kernel-module MOK key).
Hosts use it in `/etc/containers/policy.json` to verify pulls. Generate it
once:

```sh
cosign generate-key-pair          # prompts for a passphrase
gh secret set COSIGN_PRIVATE_KEY < cosign.key
gh secret set COSIGN_PASSWORD     # prompts; paste the same passphrase
mv cosign.pub certs/cosign.pub
shred -u cosign.key   # back it up first, same caveats as MOK.priv
git add certs/cosign.pub
```

The passphrase encrypts the private key at rest (including your backup). If
you'd rather use an empty passphrase, generate with
`COSIGN_PASSWORD="" cosign generate-key-pair` and skip the
`COSIGN_PASSWORD` secret entirely — GitHub rejects empty secret values, and
an unset secret resolves to an empty string in CI, which matches an empty
passphrase.
