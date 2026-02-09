ARG FCOS_STREAM

FROM fedora:43 AS builder
ARG BCACHE_TAG

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
    make rpm
    
FROM quay.io/fedora/fedora-coreos:${FCOS_STREAM}

COPY --from=builder /root/rpmbuild/RPMS/x86_64/bcachefs-tools-*.rpm /tmp/
COPY --from=builder /root/rpmbuild/RPMS/noarch/dkms-bcachefs-*.rpm /tmp/

RUN TARGET_VERSION=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -n 1) && \
    rpm-ostree install -y "kernel-devel-${TARGET_VERSION}" dkms

RUN rpm-ostree install \
      /tmp/bcachefs-tools-*.rpm \
      /tmp/dkms-bcachefs-*.rpm && \
    rm -f /tmp/*.rpm

RUN echo "bcachefs" > /etc/modules-load.d/bcachefs.conf

RUN ostree --repo=/ostree/repo init --mode=bare && \
    ostree --repo=/ostree/repo commit \
      --branch=${FCOS_STREAM} \
      --subject="FCOS + Bcachefs ${BCACHE_TAG}" \
      --add-metadata-string=fedora-coreos.stream=${FCOS_STREAM} \
      /usr


