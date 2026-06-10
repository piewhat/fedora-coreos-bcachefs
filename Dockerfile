ARG FCOS_STREAM=stable

FROM quay.io/fedora/fedora-coreos:${FCOS_STREAM} AS builder
ARG BCACHEFS_REF

RUN KVER=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    KPATH=$(rpm -q kernel-core --queryformat '%{VERSION}/%{RELEASE}/%{ARCH}') && \
    dnf install -y "kernel-devel-${KVER}" dkms || \
    dnf install -y \
        "https://kojipkgs.fedoraproject.org/packages/kernel/${KPATH}/kernel-devel-${KVER}.rpm" \
        dkms

RUN dnf install -y \
    rpm-build jq 'pkgconfig(udev)' @c-development git \
    libaio-devel libsodium-devel libblkid-devel libzstd-devel zlib-devel \
    userspace-rcu-devel lz4-devel libuuid-devel valgrind-devel \
    keyutils-libs-devel findutils systemd-devel clang-devel llvm-devel \
    rust cargo libattr-devel libunwind-devel

ENV RPM_TOPDIR=/var/tmp/rpmbuild \
    CARGO_HOME=/var/tmp/cargo \
    RUSTUP_HOME=/var/tmp/rustup \
    HOME=/var/tmp \
    TMPDIR=/var/tmp \
    RPM_BUILD_NOSOURCEDEBUG=1
RUN mkdir -p ${RPM_TOPDIR}/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} \
    ${CARGO_HOME} ${RUSTUP_HOME} /build

WORKDIR /build
RUN git clone https://github.com/koverstreet/bcachefs-tools.git && \
    cd bcachefs-tools && git checkout "$BCACHEFS_REF"

WORKDIR /build/bcachefs-tools
RUN make rpm -j"$(nproc)"

RUN set -eux; \
    KVER=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}'); \
    rpm -i --nodeps ${RPM_TOPDIR}/RPMS/noarch/dkms-bcachefs-*.rpm || true; \
    DKMS_VER=$(ls /usr/src | grep -oP 'bcachefs-\K.*'); \
    dkms install "bcachefs/${DKMS_VER}" -k "${KVER}" --force; \
    mkdir -p /out; \
    cp -a "/lib/modules/${KVER}/extra" /out/extra

FROM quay.io/fedora/fedora-coreos:${FCOS_STREAM}

COPY --from=builder /var/tmp/rpmbuild/RPMS/x86_64/bcachefs-tools-0*.rpm /tmp/
COPY --from=builder /out/extra /tmp/extra

# Userspace tools only — plain >= deps, base packages untouched.
RUN rpm-ostree install -y /tmp/bcachefs-tools-0*.rpm && rm -f /tmp/*.rpm

RUN set -eux; \
    KVER=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}'); \
    mkdir -p "/usr/lib/modules/${KVER}/extra"; \
    cp -a /tmp/extra/. "/usr/lib/modules/${KVER}/extra/"; \
    depmod -a "${KVER}"; \
    rm -rf /tmp/extra

RUN echo "bcachefs" > /etc/modules-load.d/bcachefs.conf

COPY rpm-ostreed-oci-update.service /etc/systemd/system/rpm-ostreed-oci-update.service
COPY rpm-ostreed-oci-update.timer /etc/systemd/system/rpm-ostreed-oci-update.timer
RUN ln -s /etc/systemd/system/rpm-ostreed-oci-update.timer /etc/systemd/system/timers.target.wants/rpm-ostreed-oci-update.timer

RUN ostree container commit
