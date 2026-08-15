name: Build FCOS bcachefs images

on:
  push:
    branches:
      - main
  schedule:
    - cron: "15 3 * * *"
  workflow_dispatch:
    inputs:
      force:
        description: "Force rebuild (ignore FCOS + bcachefs checks)"
        required: false
        default: "false"
      bcachefs_ref:
        description: "Build a specific bcachefs ref (tag or commit SHA) as an isolated git- tagged image. Leave empty for a normal build of the latest tag."
        required: false
        default: ""
      driver_ref:
        description: "bcachefs-storage-driver ref to build podman against. Leave empty for main."
        required: false
        default: ""

permissions:
  contents: read
  packages: write
  id-token: write

concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: false

env:
  IMAGE: ghcr.io/${{ github.repository }}

jobs:
  build:
    runs-on: ubuntu-latest

    strategy:
      fail-fast: false
      matrix:
        fcos_stream:
          - stable
          - testing

    steps:
      - name: Checkout repository
        uses: actions/checkout@v5

      - name: Ensure skopeo is available
        run: |
          if ! command -v skopeo >/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq skopeo
          fi

      - name: Resolve base image digest
        id: base
        run: |
          REF="quay.io/fedora/fedora-coreos:${{ matrix.fcos_stream }}"
          for i in 1 2 3 4 5; do
            DIGEST=$(skopeo inspect --format '{{.Digest}}' "docker://${REF}") && break
            echo "skopeo inspect failed (attempt $i), retrying..."
            sleep $((i * 15))
          done
          test -n "$DIGEST"
          PINNED="quay.io/fedora/fedora-coreos@${DIGEST}"

          VERSION=$(skopeo inspect --format '{{index .Labels "org.opencontainers.image.version"}}' "docker://${PINNED}")
          if [ -z "$VERSION" ] || [ "$VERSION" = "<no value>" ]; then
            VERSION=$(curl -s "https://builds.coreos.fedoraproject.org/streams/${{ matrix.fcos_stream }}.json" \
              | jq -r '.architectures.x86_64.artifacts.metal.release')
          fi

          FREL="${VERSION%%.*}"
          echo "digest=${DIGEST}" >> "$GITHUB_OUTPUT"
          echo "pinned=${PINNED}" >> "$GITHUB_OUTPUT"
          echo "fcos_version=${VERSION}" >> "$GITHUB_OUTPUT"
          echo "builder=quay.io/fedora/fedora:${FREL}" >> "$GITHUB_OUTPUT"

      - name: Resolve bcachefs ref
        id: bcachefs
        run: |
          if [ -n "${{ inputs.bcachefs_ref }}" ]; then
            REF="${{ inputs.bcachefs_ref }}"
            echo "Using provided ref: $REF"
          else
            REF=$(gh api 'repos/koverstreet/bcachefs-tools/tags?per_page=100' \
              --jq '[.[].name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))]
                    | sort_by(.[1:] | split(".") | map(tonumber)) | last')
            echo "Using latest tag: $REF"
          fi

          if [ -z "$REF" ] || [ "$REF" = "null" ]; then
            echo "Could not resolve a bcachefs ref, aborting"
            exit 1
          fi

          echo "ref=$REF" >> "$GITHUB_OUTPUT"
          echo "short_ref=${REF:0:12}" >> "$GITHUB_OUTPUT"
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Resolve podman driver ref
        id: driver
        run: |
          REF="${{ inputs.driver_ref }}"
          : "${REF:=main}"
          echo "ref=$REF" >> "$GITHUB_OUTPUT"

      - name: Resolve build mode
        id: mode
        run: |
          BRANCH="${{ github.ref_name }}"
          ISOLATED=false
          LABEL=""

          if [ -n "${{ inputs.bcachefs_ref }}" ]; then
            ISOLATED=true
            LABEL="${{ steps.bcachefs.outputs.short_ref }}"
            echo "isolated: explicit bcachefs_ref given"
          elif [ "$BRANCH" != "main" ]; then
            ISOLATED=true
            SAFE_BRANCH=$(echo "$BRANCH" | tr -c 'a-zA-Z0-9._-' '-')
            LABEL="branch-${SAFE_BRANCH}"
            echo "isolated: running from non-main branch ($BRANCH)"
          elif [ -n "${{ inputs.driver_ref }}" ]; then
            ISOLATED=true
            SAFE_DRIVER=$(echo "${{ inputs.driver_ref }}" | cut -c1-12 | tr -c 'a-zA-Z0-9._-' '-')
            LABEL="driver-${SAFE_DRIVER}"
            echo "isolated: explicit driver_ref given"
          else
            echo "normal build: main branch, no explicit refs"
          fi

          echo "isolated=$ISOLATED" >> "$GITHUB_OUTPUT"
          echo "label=$LABEL" >> "$GITHUB_OUTPUT"

      - name: Check if rebuild is needed
        id: check
        run: |
          if [ "${{ steps.mode.outputs.isolated }}" = "true" ]; then
            echo "build_needed=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          if [ "${{ inputs.force }}" = "true" ]; then
            echo "build_needed=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          CURRENT=""
          for i in 1 2 3; do
            CURRENT=$(skopeo inspect \
              --format '{{index .Labels "io.fcos-bcachefs.base-digest"}},{{index .Labels "io.fcos-bcachefs.bcachefs-ref"}},{{index .Labels "io.fcos-bcachefs.driver-ref"}}' \
              "docker://${IMAGE}:${{ matrix.fcos_stream }}" 2>&1) && break
            if echo "$CURRENT" | grep -q "manifest unknown"; then
              CURRENT="none"
              break
            fi
            echo "skopeo inspect failed (attempt $i), retrying..."
            CURRENT="none"
            sleep $((i * 15))
          done
          WANTED="${{ steps.base.outputs.digest }},${{ steps.bcachefs.outputs.ref }},${{ steps.driver.outputs.ref }}"

          echo "current: ${CURRENT}"
          echo "wanted:  ${WANTED}"

          if [ "$CURRENT" != "$WANTED" ]; then
            echo "build_needed=true" >> "$GITHUB_OUTPUT"
          else
            echo "build_needed=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Resolve image tags
        id: tags
        if: ${{ steps.check.outputs.build_needed == 'true' }}
        run: |
          STREAM="${{ matrix.fcos_stream }}"
          REF="${{ steps.bcachefs.outputs.ref }}"
          SHORT_REF="${{ steps.bcachefs.outputs.short_ref }}"
          FCOS="${{ steps.base.outputs.fcos_version }}"

          if [ "${{ steps.mode.outputs.isolated }}" = "true" ]; then
            TAGS="${IMAGE}:git-${{ steps.mode.outputs.label }}-${FCOS}-${STREAM}"
          else
            TAGS=$(printf '%s\n%s\n%s' \
              "${IMAGE}:${STREAM}" \
              "${IMAGE}:${REF}-${STREAM}" \
              "${IMAGE}:${REF}-${FCOS}-${STREAM}")
          fi

          {
            echo "tags<<EOF"
            echo "$TAGS"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Compute signing fingerprint
        id: signing
        run: |
          if [ -n "$MODULE_SIGNING_KEY" ] && [ -f certs/MOK.der ]; then
            echo "fingerprint=$(sha256sum certs/MOK.der | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"
            echo "enabled=true" >> "$GITHUB_OUTPUT"
          else
            echo "fingerprint=unsigned" >> "$GITHUB_OUTPUT"
            echo "enabled=false" >> "$GITHUB_OUTPUT"
          fi
        env:
          MODULE_SIGNING_KEY: ${{ secrets.MODULE_SIGNING_KEY }}

      - name: Set up Docker Buildx
        if: ${{ steps.check.outputs.build_needed == 'true' }}
        uses: docker/setup-buildx-action@v3

      - name: Log in to GitHub Container Registry
        if: ${{ steps.check.outputs.build_needed == 'true' }}
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build image
        if: ${{ steps.check.outputs.build_needed == 'true' }}
        uses: docker/build-push-action@v6
        with:
          context: .
          load: true
          provenance: false
          tags: ${{ steps.tags.outputs.tags }}
          build-args: |
            BASE_IMAGE=${{ steps.base.outputs.pinned }}
            BUILDER_IMAGE=${{ steps.base.outputs.builder }}
            BCACHEFS_REF=${{ steps.bcachefs.outputs.ref }}
            BCACHEFS_DRIVER_REF=${{ steps.driver.outputs.ref }}
            SIGNING_FINGERPRINT=${{ steps.signing.outputs.fingerprint }}
          secrets: |
            "module_signing_key=${{ secrets.MODULE_SIGNING_KEY }}"
          labels: |
            org.opencontainers.image.source=https://github.com/${{ github.repository }}
            org.opencontainers.image.description=Fedora CoreOS (${{ matrix.fcos_stream }}) with the bcachefs kernel module and bcachefs-tools
            org.opencontainers.image.licenses=MIT
            org.opencontainers.image.version=${{ steps.base.outputs.fcos_version }}
            io.fcos-bcachefs.base-digest=${{ steps.base.outputs.digest }}
            io.fcos-bcachefs.bcachefs-ref=${{ steps.bcachefs.outputs.ref }}
            io.fcos-bcachefs.driver-ref=${{ steps.driver.outputs.ref }}
          cache-from: type=gha,scope=${{ matrix.fcos_stream }}
          cache-to: type=gha,scope=${{ matrix.fcos_stream }},mode=max

      - name: Smoke test image
        if: ${{ steps.check.outputs.build_needed == 'true' }}
        run: |
          TAG=$(echo "${{ steps.tags.outputs.tags }}" | head -n1 | xargs)
          # podman does an internal re-exec/unshare for its pause process
          # setup even running as root here — that needs capabilities a
          # plain `docker run` doesn't grant by default (no CAP_SYS_ADMIN,
          # seccomp blocks the clone flags it needs). Without --privileged,
          # `podman info` fails before ever reaching the graphdriver,
          # producing a false "driver not registered" result below.
          docker run --rm --privileged -e SIGNING_ENABLED="${{ steps.signing.outputs.enabled }}" "$TAG" bash -c '
            set -eux
            KVER=$(rpm -q kernel-core --queryformat "%{VERSION}-%{RELEASE}.%{ARCH}")
            modinfo -k "$KVER" bcachefs
            VERMAGIC=$(modinfo -k "$KVER" -F vermagic bcachefs)
            case "$VERMAGIC" in "$KVER "*) ;; *) echo "vermagic mismatch: $VERMAGIC != $KVER"; exit 1;; esac
            rpm -q bcachefs-tools
            bcachefs version
            rpm -q kmod-bcachefs
            test -f /usr/lib/modules-load.d/bcachefs.conf
            test "$(readlink /etc/systemd/system/zincati.service)" = "/dev/null"
            test -e /etc/systemd/system/timers.target.wants/rpm-ostreed-automatic.timer
            test -f /usr/lib/systemd/system/rpm-ostreed-automatic.timer.d/10-update-window.conf
            grep -q "AutomaticUpdatePolicy=apply" /etc/rpm-ostreed.conf
            if [ "$SIGNING_ENABLED" = "true" ]; then
              SIGNER=$(modinfo -k "$KVER" -F signer bcachefs)
              echo "module signer: ${SIGNER}"
              test -n "$SIGNER"
              test -f /etc/pki/fcos-bcachefs/MOK.der
            fi
            OUT=$(podman --storage-driver bcachefs --root /tmp/pmtest info 2>&1 || true)
            echo "$OUT"
            echo "$OUT" | grep -qi "not on a bcachefs filesystem" || {
              echo "bcachefs storage driver not registered in podman"; exit 1;
            }
            if [ -f /etc/containers/storage.conf ]; then
              if grep -q "^driver = \"bcachefs\"" /etc/containers/storage.conf; then
                echo "storage.conf defaults to bcachefs — must ship inert"; exit 1;
              fi
            fi
          '

      - name: Push image
        if: ${{ steps.check.outputs.build_needed == 'true' }}
        id: push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          provenance: false
          tags: ${{ steps.tags.outputs.tags }}
          build-args: |
            BASE_IMAGE=${{ steps.base.outputs.pinned }}
            BUILDER_IMAGE=${{ steps.base.outputs.builder }}
            BCACHEFS_REF=${{ steps.bcachefs.outputs.ref }}
            BCACHEFS_DRIVER_REF=${{ steps.driver.outputs.ref }}
            SIGNING_FINGERPRINT=${{ steps.signing.outputs.fingerprint }}
          secrets: |
            "module_signing_key=${{ secrets.MODULE_SIGNING_KEY }}"
          labels: |
            org.opencontainers.image.source=https://github.com/${{ github.repository }}
            org.opencontainers.image.description=Fedora CoreOS (${{ matrix.fcos_stream }}) with the bcachefs kernel module and bcachefs-tools
            org.opencontainers.image.licenses=MIT
            org.opencontainers.image.version=${{ steps.base.outputs.fcos_version }}
            io.fcos-bcachefs.base-digest=${{ steps.base.outputs.digest }}
            io.fcos-bcachefs.bcachefs-ref=${{ steps.bcachefs.outputs.ref }}
            io.fcos-bcachefs.driver-ref=${{ steps.driver.outputs.ref }}
          cache-from: type=gha,scope=${{ matrix.fcos_stream }}

      - name: Install cosign
        if: ${{ steps.check.outputs.build_needed == 'true' }}
        uses: sigstore/cosign-installer@v3

      - name: Sign image
        if: ${{ steps.check.outputs.build_needed == 'true' }}
        run: |
          cosign sign --yes "${IMAGE}@${{ steps.push.outputs.digest }}"
          if [ -n "$COSIGN_PRIVATE_KEY" ]; then
            cosign sign --yes --key env://COSIGN_PRIVATE_KEY "${IMAGE}@${{ steps.push.outputs.digest }}"
          fi
        env:
          COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
          COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
