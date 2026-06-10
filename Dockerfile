# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=quay.io/fedora/fedora-coreos:stable
ARG BUILDER_IMAGE=quay.io/fedora/fedora:latest

FROM ${BASE_IMAGE} AS kinfo
RUN rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' > /kver && \
    rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}' > /kvr && \
    rpm -q kernel-core --queryformat '%{ARCH}' > /karch

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
