ARG FCOS_STREAM=stable

FROM quay.io/fedora/fedora-coreos:${FCOS_STREAM} AS builder
ARG BCACHEFS_TAG

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
    libattr-devel

ENV RPM_TOPDIR=/var/tmp/rpmbuild
ENV CARGO_HOME=/var/tmp/cargo
ENV RUSTUP_HOME=/var/tmp/rustup
ENV HOME=/var/tmp
ENV TMPDIR=/var/tmp
RUN mkdir -p \
    ${RPM_TOPDIR}/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} \
    ${CARGO_HOME} \
    ${RUSTUP_HOME} \
    /build

WORKDIR /build
RUN git clone --depth 1 --branch "$BCACHEFS_TAG" \
    https://evilpiepirate.org/git/bcachefs-tools.git;

WORKDIR /build/bcachefs-tools
RUN set -eux; \
    make rpm -j$(nproc)

FROM quay.io/fedora/fedora-coreos:${FCOS_STREAM}

COPY --from=builder /var/tmp/rpmbuild/RPMS/x86_64/bcachefs-tools-0*.rpm /tmp/
COPY --from=builder /var/tmp/rpmbuild/RPMS/noarch/dkms-bcachefs-*.rpm /tmp/

RUN TARGET_VERSION=$(ls /usr/lib/modules | head -n1) \
    rpm-ostree install -y "kernel-devel-${TARGET_VERSION}" dkms

RUN set -eux; \
    rpm-ostree install -y \
      /tmp/bcachefs-tools-0*.rpm \
      /tmp/dkms-bcachefs-*.rpm; \
    rm -f /tmp/*.rpm

RUN echo "bcachefs" > /etc/modules-load.d/bcachefs.conf
RUN systemctl disable dkms.service

COPY rpm-ostreed-oci-update.service /etc/systemd/system/rpm-ostreed-oci-update.service
COPY rpm-ostreed-oci-update.timer /etc/systemd/system/rpm-ostreed-oci-update.timer
RUN ln -s /etc/systemd/system/rpm-ostreed-oci-update.timer /etc/systemd/system/timers.target.wants/rpm-ostreed-oci-update.timer

RUN ostree container commit
