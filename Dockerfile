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
    libunwind-devel

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

FROM ${BASE_IMAGE}

RUN --mount=type=bind,from=builder,source=/var/tmp/rpmbuild/RPMS,target=/rpms \
    rpm-ostree install -y /rpms/x86_64/bcachefs-tools-0*.rpm

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
