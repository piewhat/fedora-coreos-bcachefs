ARG FCOS_STREAM=stable

FROM quay.io/fedora/fedora-coreos:${FCOS_STREAM} AS builder
ARG BCACHE_TAG

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
    libattr-devel && \
    dnf clean all

WORKDIR /build
RUN git clone --depth 1 --branch ${BCACHE_TAG} \
      https://evilpiepirate.org/git/bcachefs-tools.git && \
    cd bcachefs-tools && \
    rpmbuild --define "_topdir ${RPM_TOPDIR}" -ta *.tar* || true && \
    make rpm RPMBUILD="rpmbuild --define '_topdir ${RPM_TOPDIR}'"

FROM quay.io/fedora/fedora-coreos:${FCOS_STREAM}

COPY --from=builder /var/tmp/rpmbuild/RPMS/x86_64/bcachefs-tools-0*.rpm /tmp/
COPY --from=builder /var/tmp/rpmbuild/RPMS/noarch/dkms-bcachefs-*.rpm /tmp/

RUN TARGET_VERSION=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -n 1) && \
    rpm-ostree install -y "kernel-devel-${TARGET_VERSION}" dkms

RUN rpm-ostree install \
      /tmp/bcachefs-tools-*.rpm \
      /tmp/dkms-bcachefs-*.rpm && \
    rm -f /tmp/*.rpm

RUN echo "bcachefs" > /etc/modules-load.d/bcachefs.conf

COPY rpm-ostreed-oci-update.service /etc/systemd/system/rpm-ostreed-oci-update.service
COPY rpm-ostreed-oci-update.timer /etc/systemd/system/rpm-ostreed-oci-update.timer

RUN ln -s /etc/systemd/system/rpm-ostreed-oci-update.timer /etc/systemd/system/timers.target.wants/rpm-ostreed-oci-update.timer

RUN systemctl disable dkms.service

RUN ostree container commit
