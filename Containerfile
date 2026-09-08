# The i5-3570K (Ivy Bridge) has no AVX2, so it needs AlmaLinux's x86_64_v2
# build. The :10 index carries it as the linux/amd64/v2 platform.
FROM --platform=linux/amd64/v2 quay.io/almalinuxorg/almalinux-bootc:10 AS base

# OpenZFS is built from source against this image's kernel. The prebuilt
# kmod-zfs packages target stock EL10, whose toolchain emits x86-64-v3
# instructions, and DKMS cannot run on a bootc host with a read-only /usr.
FROM base AS zfs-builder

# renovate: datasource=github-releases depName=openzfs/zfs extractVersion=^zfs-(?<version>.*)$
ARG ZFS_VERSION=2.4.4

RUN dnf install -y --enablerepo=crb \
        "kernel-devel-$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}')" \
        autoconf automake gcc libtool make rpm-build \
        kernel-rpm-macros systemd-rpm-macros \
        elfutils-libelf-devel libaio-devel libattr-devel libblkid-devel \
        libcurl-devel libffi-devel libtirpc-devel libuuid-devel \
        openssl-devel systemd-devel zlib-ng-compat-devel

WORKDIR /build
RUN curl -fsSL "https://github.com/openzfs/zfs/releases/download/zfs-${ZFS_VERSION}/zfs-${ZFS_VERSION}.tar.gz" \
        | tar xz --strip-components=1 && \
    ./configure --with-linux="/usr/src/kernels/$(ls /usr/src/kernels)" --enable-systemd --enable-pyzfs=no && \
    make -j"$(nproc)" rpm-utils rpm-kmod && \
    mkdir /rpms && \
    find . -maxdepth 1 -name '*.rpm' \
        ! -name '*-devel-*' ! -name '*-debuginfo-*' ! -name '*-debugsource-*' \
        ! -name 'zfs-test-*' ! -name 'zfs-dracut-*' ! -name '*.src.rpm' \
        -exec mv -t /rpms {} +

FROM base

COPY root/ /

# epel-release on the v2 build points at AlmaLinux's own x86_64_v2 EPEL rebuild.
RUN dnf install -y epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf install -y \
        btop \
        htop \
        git \
        jq \
        tar \
    && dnf clean all

RUN useradd --create-home --groups wheel jono && \
    chmod 0440 /etc/sudoers.d/jono && \
    chmod 0644 /etc/ssh/authorized_keys.d/jono && \
    systemctl enable randomize-passwords.service

RUN systemctl enable show-host-key.service

COPY vendor/bootc-secrets/install /tmp/bootc-secrets-install
RUN /tmp/bootc-secrets-install/install.sh && rm -rf /tmp/bootc-secrets-install

RUN mkdir -p /etc/bootc-secrets && \
    printf 'SECRETS_BASE_URL=https://secrets.jonohill.nz\n' > /etc/bootc-secrets/config.env

RUN dnf install -y tailscale && dnf clean all && \
    systemctl enable tailscaled.service tailscale-up.service

# Power tuning, see docs/power-tuning.md. tuned-adm needs the daemon, so the
# active profile is written directly.
RUN dnf install -y tuned powertop && dnf clean all && \
    chmod 0755 /etc/tuned/profiles/nas-powersave/pci-runtime-pm.sh && \
    printf 'nas-powersave\n' > /etc/tuned/active_profile && \
    printf 'manual\n' > /etc/tuned/profile_mode && \
    systemctl enable tuned.service

# ZFS, see docs/zfs.md. Root is not on ZFS, so zfs-dracut is left out and the
# shipped initramfs stays as is.
COPY --from=zfs-builder /rpms /tmp/zfs-rpms
RUN dnf install -y /tmp/zfs-rpms/*.rpm && dnf clean all && rm -rf /tmp/zfs-rpms && \
    depmod -a "$(ls /usr/lib/modules)" && \
    systemctl enable zfs-hostid.service zfs-import-scan.service zfs-import.target \
        zfs-mount.service zfs-zed.service zfs.target

# Logically bound images: quadlet images are pulled with the host image.
RUN mkdir -p /usr/lib/bootc/bound-images.d && \
    find /usr/share/containers/systemd \
        \( -name '*.container' -o -name '*.image' \) \
        -exec ln -sf -t /usr/lib/bootc/bound-images.d {} +

# daily updates, reboot if needed (schedule in the timer drop-in)
RUN systemctl enable bootc-fetch-apply-updates.timer

RUN dnf install -y greenboot && dnf clean all && \
    chmod 0755 /etc/greenboot/check/required.d/*.sh && \
    systemctl enable greenboot-healthcheck.service

ARG IMAGE_REVISION=unknown
ARG IMAGE_BUILD=dev
LABEL org.opencontainers.image.source="https://github.com/jonohill/nas-image" \
      org.opencontainers.image.revision="$IMAGE_REVISION" \
      nz.jonohill.build="$IMAGE_BUILD"
