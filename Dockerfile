ARG BASE_IMAGE=quay.io/fedora/fedora-coreos:stable

FROM ${BASE_IMAGE} AS builder
ARG BCACHEFS_REF

RUN set -eux; \
    KVER=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}'); \
    KPATH=$(rpm -q kernel-core --queryformat '%{VERSION}/%{RELEASE}/%{ARCH}'); \
    dnf install -y "kernel-devel-${KVER}" dkms || \
    dnf install -y \
        "https://kojipkgs.fedoraproject.org/packages/kernel/${KPATH}/kernel-devel-${KVER}.rpm" \
        dkms

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
    rust \
    cargo \
    libattr-devel \
    libunwind-devel \
    openssl \
    xz \
    zstd

ENV RPM_TOPDIR=/var/tmp/rpmbuild \
    CARGO_HOME=/var/tmp/cargo \
    RUSTUP_HOME=/var/tmp/rustup \
    HOME=/var/tmp \
    TMPDIR=/var/tmp \
    RPM_BUILD_NOSOURCEDEBUG=1

RUN mkdir -p \
    ${RPM_TOPDIR}/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} \
    ${CARGO_HOME} \
    ${RUSTUP_HOME} \
    /build

WORKDIR /build
RUN git clone https://github.com/koverstreet/bcachefs-tools.git && \
    cd bcachefs-tools && \
    git checkout "$BCACHEFS_REF"

WORKDIR /build/bcachefs-tools
RUN make rpm -j"$(nproc)"

RUN set -eux; \
    KVER=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}'); \
    rpm -i --noscripts --nodeps ${RPM_TOPDIR}/RPMS/noarch/dkms-bcachefs-*.rpm; \
    SRC=$(ls -d /usr/src/bcachefs-*); \
    PACKAGE_NAME=$(sed -n 's/^PACKAGE_NAME="\?\([^"]*\)"\?.*/\1/p' "${SRC}/dkms.conf"); \
    PACKAGE_VERSION=$(sed -n 's/^PACKAGE_VERSION="\?\([^"]*\)"\?.*/\1/p' "${SRC}/dkms.conf"); \
    : "${PACKAGE_NAME:=bcachefs}"; \
    : "${PACKAGE_VERSION:=$(basename "${SRC}" | cut -d- -f2-)}"; \
    dkms install "${PACKAGE_NAME}/${PACKAGE_VERSION}" -k "${KVER}" --force; \
    mkdir -p /out/modules; \
    find "/lib/modules/${KVER}" \( -path '*/extra/*' -o -path '*/updates/*' \) \
        -name '*.ko*' -exec cp -v {} /out/modules/ \; ; \
    test -n "$(ls -A /out/modules)"

ARG SIGNING_FINGERPRINT=""
COPY certs/MOK.der /MOK.der
RUN --mount=type=secret,id=module_signing_key \
    set -eux; \
    echo "signing setup: ${SIGNING_FINGERPRINT}"; \
    if [ -s /run/secrets/module_signing_key ]; then \
        KVER=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}'); \
        SIGN="/usr/src/kernels/${KVER}/scripts/sign-file"; \
        for f in /out/modules/*.ko*; do \
            case "$f" in \
                *.ko.xz)  xz -d "$f"; ko="${f%.xz}";; \
                *.ko.zst) zstd -d --rm "$f"; ko="${f%.zst}";; \
                *.ko)     ko="$f";; \
                *)        continue;; \
            esac; \
            "$SIGN" sha256 /run/secrets/module_signing_key /MOK.der "$ko"; \
            modinfo -F signer "$ko"; \
            case "$f" in \
                *.ko.xz)  xz -f "$ko";; \
                *.ko.zst) zstd -f --rm "$ko";; \
            esac; \
        done; \
    else \
        echo "WARNING: no module signing key provided, shipping unsigned module"; \
    fi

FROM ${BASE_IMAGE}

RUN --mount=type=bind,from=builder,source=/var/tmp/rpmbuild/RPMS,target=/rpms \
    rpm-ostree install -y mokutil /rpms/x86_64/bcachefs-tools-0*.rpm

COPY certs/MOK.der /etc/pki/fcos-bcachefs/MOK.der

RUN --mount=type=bind,from=builder,source=/out/modules,target=/prebuilt \
    set -eux; \
    KVER=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}'); \
    install -d -m 0755 "/usr/lib/modules/${KVER}/extra"; \
    install -m 0644 /prebuilt/*.ko* "/usr/lib/modules/${KVER}/extra/"; \
    depmod -a "${KVER}"; \
    modinfo -k "${KVER}" bcachefs

RUN set -eux; \
    echo "bcachefs" > /etc/modules-load.d/bcachefs.conf; \
    systemctl mask zincati.service

COPY rpm-ostreed-oci-update.service /etc/systemd/system/rpm-ostreed-oci-update.service
COPY rpm-ostreed-oci-update.timer /etc/systemd/system/rpm-ostreed-oci-update.timer
RUN ln -s /etc/systemd/system/rpm-ostreed-oci-update.timer \
    /etc/systemd/system/timers.target.wants/rpm-ostreed-oci-update.timer

RUN bootc container lint || echo "bootc lint reported issues (non-fatal)"

RUN ostree container commit
