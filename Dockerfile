# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=quay.io/fedora/fedora-coreos:stable
ARG BUILDER_IMAGE=quay.io/fedora/fedora:latest

FROM ${BASE_IMAGE} AS kinfo
RUN rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' > /kver && \
    rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}' > /kvr && \
    rpm -q kernel-core --queryformat '%{ARCH}' > /karch && \
    rpm -q podman --queryformat '%{VERSION}-%{RELEASE}' > /pnvr

FROM ${BUILDER_IMAGE} AS tools
ARG BCACHEFS_REF
RUN dnf install -y \
    rpm-build \
    jq \
    'pkgconfig(udev)' \
    @c-development \
    git \
    libaio-devel \
    libsodium-devel \
    libblkid-devel \
    libzstd-devel \
    zlib-devel \
    userspace-rcu-devel \
    lz4-devel \
    libuuid-devel \
    valgrind-devel \
    keyutils-libs-devel \
    findutils \
    systemd-devel \
    clang-devel \
    llvm-devel \
    bindgen-cli \
    rust \
    cargo \
    libattr-devel \
    libunwind-devel
ENV RPM_TOPDIR=/root/rpmbuild \
    RPM_BUILD_NOSOURCEDEBUG=1
RUN mkdir -p ${RPM_TOPDIR}/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} /build
WORKDIR /build
RUN git clone https://github.com/koverstreet/bcachefs-tools.git && \
    cd bcachefs-tools && \
    git checkout "$BCACHEFS_REF"
WORKDIR /build/bcachefs-tools
RUN make rpm -j"$(nproc)"

FROM ${BUILDER_IMAGE} AS module
COPY --from=kinfo /kver /kvr /karch /
RUN set -eux; \
    dnf install -y fedora-repos-archive dkms rpm-build kmod openssl xz zstd; \
    if ! dnf install -y \
        "kernel-core-$(cat /kver)" \
        "kernel-modules-core-$(cat /kver)" \
        "kernel-devel-$(cat /kver)"; then \
        dnf install -y koji; \
        mkdir /koji; \
        cd /koji; \
        koji download-build --noprogress --arch "$(cat /karch)" "kernel-$(cat /kvr)"; \
        dnf install -y \
            ./kernel-core-*.rpm \
            ./kernel-modules-core-*.rpm \
            ./kernel-devel-*.rpm; \
        cd /; \
        rm -rf /koji; \
    fi
RUN --mount=type=bind,from=tools,source=/root/rpmbuild/RPMS,target=/rpms \
    set -eux; \
    KVER=$(cat /kver); \
    rpm -i --noscripts --nodeps /rpms/noarch/dkms-bcachefs-*.rpm; \
    SRC=$(ls -d /usr/src/bcachefs-*); \
    PACKAGE_NAME=$(sed -n 's/^PACKAGE_NAME="\?\([^"]*\)"\?.*/\1/p' "${SRC}/dkms.conf"); \
    PACKAGE_VERSION=$(sed -n 's/^PACKAGE_VERSION="\?\([^"]*\)"\?.*/\1/p' "${SRC}/dkms.conf"); \
    : "${PACKAGE_NAME:=bcachefs}"; \
    : "${PACKAGE_VERSION:=$(basename "${SRC}" | cut -d- -f2-)}"; \
    dkms install "${PACKAGE_NAME}/${PACKAGE_VERSION}" -k "${KVER}" --force; \
    echo "${PACKAGE_VERSION}" > /bver; \
    mkdir -p /out; \
    KO=$(find "/lib/modules/${KVER}" \( -path '*/extra/*' -o -path '*/updates/*' \) -name 'bcachefs.ko*' | head -n1); \
    test -n "$KO"; \
    cp "$KO" /out/; \
    cd /out; \
    case "$(basename "$KO")" in \
        *.ko.xz)  xz -d bcachefs.ko.xz;; \
        *.ko.zst) zstd -d --rm -q bcachefs.ko.zst;; \
    esac; \
    test -f /out/bcachefs.ko
ARG SIGNING_FINGERPRINT=""
COPY certs/MOK.der /MOK.der
RUN --mount=type=secret,id=module_signing_key \
    set -eux; \
    echo "signing setup: ${SIGNING_FINGERPRINT}"; \
    KVER=$(cat /kver); \
    if [ -s /run/secrets/module_signing_key ]; then \
        "/usr/src/kernels/${KVER}/scripts/sign-file" sha256 \
            /run/secrets/module_signing_key /MOK.der /out/bcachefs.ko; \
        modinfo -F signer /out/bcachefs.ko; \
    else \
        echo "WARNING: no module signing key provided, shipping unsigned module"; \
    fi; \
    xz --check=crc32 --lzma2=dict=1MiB /out/bcachefs.ko; \
    xz -lv /out/bcachefs.ko.xz | grep -q "CRC32"
RUN set -eux; \
    KVER=$(cat /kver); \
    BVER=$(tr '-' '.' < /bver); \
    KREL=$(echo "${KVER}" | tr '-' '_'); \
    mkdir -p /root/rpmbuild/{SPECS,SOURCES,RPMS}; \
    cp /out/bcachefs.ko.xz /root/rpmbuild/SOURCES/; \
    { \
    echo "Name: kmod-bcachefs"; \
    echo "Version: ${BVER}"; \
    echo "Release: 1.${KREL}"; \
    echo "Summary: Prebuilt bcachefs kernel module for kernel ${KVER}"; \
    echo "License: GPL-2.0-only"; \
    echo "Source0: bcachefs.ko.xz"; \
    echo "BuildArch: $(cat /karch)"; \
    echo "Requires: kernel-uname-r = ${KVER}"; \
    echo ""; \
    echo "%description"; \
    echo "bcachefs ${BVER} kernel module built for kernel ${KVER}."; \
    echo ""; \
    echo "%install"; \
    echo "install -D -m 0644 %{SOURCE0} %{buildroot}/usr/lib/modules/${KVER}/extra/bcachefs.ko.xz"; \
    echo "install -d %{buildroot}/usr/lib/modules-load.d"; \
    echo "echo bcachefs > %{buildroot}/usr/lib/modules-load.d/bcachefs.conf"; \
    echo ""; \
    echo "%post"; \
    echo "depmod -a ${KVER} || :"; \
    echo ""; \
    echo "%files"; \
    echo "/usr/lib/modules/${KVER}/extra/bcachefs.ko.xz"; \
    echo "/usr/lib/modules-load.d/bcachefs.conf"; \
    } > /root/rpmbuild/SPECS/kmod-bcachefs.spec; \
    rpmbuild -bb /root/rpmbuild/SPECS/kmod-bcachefs.spec; \
    mkdir -p /out/rpms; \
    cp /root/rpmbuild/RPMS/*/kmod-bcachefs-*.rpm /out/rpms/

FROM ${BUILDER_IMAGE} AS podman-driver
ARG BCACHEFS_DRIVER_REF=main
COPY --from=kinfo /pnvr /karch /
RUN dnf install -y 'dnf-command(download)' rpmdevtools rpm-build git golang jq koji
RUN rpmdev-setuptree
WORKDIR /build
RUN git clone https://github.com/ticpu/bcachefs-storage-driver.git && \
    cd bcachefs-storage-driver && \
    git checkout "$BCACHEFS_DRIVER_REF"
RUN set -eux; \
    PNVR=$(cat /pnvr); \
    dnf download --source "podman-${PNVR}" -y --downloaddir /build || \
    koji download-build --noprogress --arch src "podman-${PNVR}"; \
    rpm -i /build/podman-*.src.rpm
RUN dnf builddep -y /root/rpmbuild/SPECS/podman.spec
# Unpack + Fedora's own patches, exposing the vendored source tree. Do not
# run -bb yet: that would re-run %prep and stomp the driver patch applied
# below onto a fresh extraction.
RUN cd /root/rpmbuild && rpmbuild -bp SPECS/podman.spec
RUN set -eux; \
    SRC_DIR=$(find /root/rpmbuild/BUILD -maxdepth 1 -type d -name 'podman-*' | head -n1); \
    test -n "$SRC_DIR"; \
    STORAGE_DIR=$(find "$SRC_DIR" -maxdepth 5 -type d -path '*/vendor/go.podman.io/storage' 2>/dev/null | head -n1); \
    MODULE="go.podman.io/storage"; \
    if [ -z "$STORAGE_DIR" ]; then \
        STORAGE_DIR=$(find "$SRC_DIR" -maxdepth 5 -type d -path '*/vendor/github.com/containers/storage' 2>/dev/null | head -n1); \
        MODULE="github.com/containers/storage"; \
    fi; \
    test -n "$STORAGE_DIR"; \
    echo "$SRC_DIR" > /src_dir; \
    echo "$STORAGE_DIR" > /storage_dir; \
    echo "$MODULE" > /storage_module; \
    echo "$STORAGE_DIR" | sed -E 's#(.*/vendor)/.*#\1/modules.txt#' > /modules_txt; \
    echo "podman source: $SRC_DIR"; \
    echo "storage vendor: $STORAGE_DIR ($MODULE)"; \
    echo "modules.txt: $(cat /modules_txt)"
RUN bash /build/bcachefs-storage-driver/packaging/apply-driver.sh \
    --module "$(cat /storage_module)" \
    "$(cat /storage_dir)" \
    /build/bcachefs-storage-driver/driver
# apply-driver.sh drops drivers/bcachefs/ into the vendor tree as a new
# package directory, but `go build -mod=vendor` resolves imports against
# vendor/modules.txt, not the filesystem — a new package path absent from
# that manifest is refused ("ignoring package ... missing from
# vendor/modules.txt"). Editing existing vendored files (driver_linux.go,
# driver.go, appending register_bcachefs.go into the already-vendored
# drivers/register package) doesn't need this; only the brand-new
# drivers/bcachefs package path does. Insert one line into the storage
# module's block, anchored right after its "## explicit" marker — any
# line within the block works for Go's parser, this anchor is just always
# present and easy to find.
RUN set -eux; \
    MOD="$(cat /storage_module)"; \
    PKG="${MOD}/drivers/bcachefs"; \
    MODULES_TXT="$(cat /modules_txt)"; \
    test -f "$MODULES_TXT"; \
    if ! grep -qxF "$PKG" "$MODULES_TXT"; then \
        awk -v modhdr="# ${MOD} " -v pkg="$PKG" ' \
            { print } \
            index($0, modhdr) == 1 { inblock=1; next } \
            /^# / && index($0, modhdr) != 1 { inblock=0 } \
            inblock && index($0, "## explicit") == 1 && !done { print pkg; done=1 } \
        ' "$MODULES_TXT" > "$MODULES_TXT.new"; \
        mv "$MODULES_TXT.new" "$MODULES_TXT"; \
    fi; \
    grep -qxF "$PKG" "$MODULES_TXT" || { \
        echo "FATAL: failed to register $PKG in $MODULES_TXT — module header anchor may not match"; \
        exit 1; \
    }; \
    echo "registered in modules.txt: $PKG"
# Build from the already-patched BUILD tree via the real spec (--noprep
# skips re-extraction), so the resulting RPM set matches stock podman's
# file manifest, deps, and scriptlets exactly — only the vendored storage
# source underneath differs. No dist-suffix: the NVR stays byte-identical
# to stock. Two earlier rpm-ostree-driven approaches were abandoned
# fighting for this same property — `override replace` requires a
# suffix because it specifically forbids an identical NVR, and `override
# remove` + `install` fails depsolve because base packages require podman
# unversioned (toolbox, then bootc, with no complete list to hunt down).
# The final stage instead swaps podman in directly via `rpm -Uvh
# --replacepkgs`, which doesn't have either restriction — see that step
# for why.
RUN cd /root/rpmbuild && rpmbuild -bb --noprep SPECS/podman.spec
# podman-docker provides the docker/moby-engine virtual names, and
# intentionally conflicts with moby-engine — which FCOS ships by default.
# It was never part of the base install; excluding it here means the
# install step below only touches packages that belong.
RUN mkdir -p /out/rpms && \
    find /root/rpmbuild/RPMS -name '*.rpm' \
        ! -name '*-debuginfo-*' ! -name '*-debugsource-*' \
        ! -name 'podman-docker-*' \
        -exec cp {} /out/rpms/ \;

FROM ${BASE_IMAGE}
RUN --mount=type=bind,from=tools,source=/root/rpmbuild/RPMS,target=/tools-rpms \
    --mount=type=bind,from=module,source=/out/rpms,target=/kmod-rpms \
    rpm-ostree install -y \
        mokutil \
        /tools-rpms/*/bcachefs-tools-0*.rpm \
        /kmod-rpms/kmod-bcachefs-*.rpm
RUN set -eux; \
    KVER=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}'); \
    depmod -a "${KVER}"; \
    modinfo -k "${KVER}" bcachefs

# podman is already part of the base compose, but this swap goes through
# raw rpm rather than any rpm-ostree override command. During a container
# build (not yet a deployed/booted bootc system), dnf and rpm work
# directly on the filesystem — the read-only, rpm-ostree-only constraint
# is a property of a live deployed system, not of building the image.
#
# `rpm -Uvh --replacepkgs` performs an in-place upgrade: it replaces the
# package's files under the same name in one RPM transaction, never
# removing "podman" from the rpmdb at any point — so anything requiring
# it (toolbox, bootc, or whatever a future FCOS release adds) stays
# satisfied throughout, without needing to know their names in advance.
# `--replacepkgs` specifically permits this even when the installed NVR
# is identical, which plain `rpm -U` would otherwise skip as "already
# installed" — this bypasses that check while still doing a proper
# transactional replace, not a raw file overwrite.
#
# Two rpm-ostree-driven approaches were tried and abandoned chasing this
# same property: `override replace` requires a version-suffixed NVR (it
# specifically forbids an identical one), and `override remove` +
# `install` as two separate commands fails depsolve on exactly the
# dependents this approach avoids by never removing podman at all.
#
# Only plain podman, not podman-machine/remote/tests/podmansh: rpm has no
# repo access or dependency fetching, unlike rpm-ostree's override
# commands (which is what previously pulled in podman-machine's qemu
# stack and podman-tests' bats/buildah chain automatically from the
# enabled repos). Bundling those here would fail outright on unresolved
# dependencies. That's fine — with exact-NVR podman, a user who wants any
# of them later can `rpm-ostree install <pkg>` on the real, deployed
# host (dnf itself is blocked there — it only works during this build,
# before the image is deployed), which
# has full repo access and resolves their dependencies normally against
# our exact podman version. podman-docker is excluded at the staging step
# (see above) regardless — that's a real conflict with moby-engine.
RUN --mount=type=bind,from=podman-driver,source=/out/rpms,target=/podman-rpms \
    rpm -Uvh --replacepkgs /podman-rpms/podman-[0-9]*.rpm

COPY certs/MOK.der /etc/pki/fcos-bcachefs/MOK.der
COPY certs/cosign.pub /etc/pki/containers/fcos-bcachefs.pub
COPY containers/fcos-bcachefs.yaml /etc/containers/registries.d/fcos-bcachefs.yaml
COPY containers/policy.json /etc/containers/policy.json
COPY systemd/10-update-window.conf /usr/lib/systemd/system/rpm-ostreed-automatic.timer.d/10-update-window.conf

RUN set -eux; \
    printf '[Daemon]\nAutomaticUpdatePolicy=apply\n' > /etc/rpm-ostreed.conf; \
    systemctl enable rpm-ostreed-automatic.timer; \
    systemctl mask zincati.service

RUN bootc container lint || echo "bootc lint reported issues (non-fatal)"

RUN ostree container commit
