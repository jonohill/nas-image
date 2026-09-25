# The i5-3570K (Ivy Bridge) has no AVX2, so it needs AlmaLinux's x86_64_v2
# build. The :10 index carries it as the linux/amd64/v2 platform.
FROM --platform=linux/amd64/v2 quay.io/almalinuxorg/almalinux-bootc:10.2 AS base

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
        podman-compose \
        smartmontools \
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

RUN dnf install -y gcc gcc-c++ make && dnf clean all && \
    chmod 0755 /usr/local/sbin/install-homebrew.sh && \
    systemctl enable install-homebrew.service

# Power tuning, see docs/power-tuning.md. tuned-adm needs the daemon, so the
# active profile is written directly.
RUN dnf install -y tuned powertop && dnf clean all && \
    chmod 0755 /etc/tuned/profiles/nas-powersave/pci-runtime-pm.sh && \
    printf 'nas-powersave\n' > /etc/tuned/active_profile && \
    printf 'manual\n' > /etc/tuned/profile_mode && \
    systemctl enable tuned.service

# ZFS, see docs/zfs.md. Root is not on ZFS, so zfs-dracut is left out and the
# shipped initramfs stays as is. sysstat is a hard dependency of the zfs
# package; its 10-minute collector timer is disabled to keep the box idle.
COPY --from=zfs-builder /rpms /tmp/zfs-rpms
RUN dnf install -y /tmp/zfs-rpms/*.rpm && dnf clean all && rm -rf /tmp/zfs-rpms && \
    depmod -a "$(ls /usr/lib/modules)" && \
    systemctl enable zfs-hostid.service zfs-import-scan.service zfs-import.target \
        zfs-mount.service zfs-zed.service zfs.target zfs-tank.service zfs-ssd.service && \
    systemctl add-wants offpeak.target zfs-scrub@tank.service zfs-scrub@ssd.service && \
    systemctl disable sysstat.service sysstat-collect.timer sysstat-rotate.timer \
        sysstat-summary.timer

# The NAS boots with Secure Boot on, so the kernel refuses unsigned modules.
COPY --from=zfs-builder /usr/src/kernels/*/scripts/sign-file /tmp/sign-file
RUN --mount=type=secret,id=mok_key,required=true \
    for ko in /usr/lib/modules/*/extra/*/*.ko; do \
        /tmp/sign-file sha256 /run/secrets/mok_key /etc/pki/mok/nas-image.der "$ko" && \
        modinfo -F signer "$ko" | grep -q . || exit 1; \
    done && rm /tmp/sign-file

# Backups, see docs/backup-plan.md. Neither tool is packaged for EL10.
# renovate: datasource=github-releases depName=rustic-rs/rustic extractVersion=^v(?<version>.*)$
ARG RUSTIC_VERSION=0.11.4
# rclone reads every RCLONE_* environment variable as a flag, so the ARG
# must not be named RCLONE_VERSION.
# renovate: datasource=github-releases depName=rclone/rclone extractVersion=^v(?<version>.*)$
ARG RCLONE_RELEASE=1.75.1
RUN cd /tmp && \
    tarball="rustic-v${RUSTIC_VERSION}-x86_64-unknown-linux-gnu.tar.gz" && \
    curl -fsSLO "https://github.com/rustic-rs/rustic/releases/download/v${RUSTIC_VERSION}/${tarball}" && \
    curl -fsSL "https://github.com/rustic-rs/rustic/releases/download/v${RUSTIC_VERSION}/${tarball}.sha256" | sha256sum -c - && \
    tar xzf "$tarball" rustic && \
    install -m 0755 rustic /usr/local/bin/rustic && \
    rm -f rustic "$tarball" && \
    dnf install -y "https://github.com/rclone/rclone/releases/download/v${RCLONE_RELEASE}/rclone-v${RCLONE_RELEASE}-linux-amd64.rpm" && \
    dnf clean all

RUN chmod 0755 /usr/local/sbin/rustic-zfs-snap /usr/local/sbin/rustic-job \
        /usr/local/sbin/rustic-due /usr/local/sbin/rustic-idle \
        /usr/local/sbin/rustic-maintain-nas /usr/local/sbin/rustic-maintain-jotta && \
    systemctl enable rustic-serve.service rustic-ssd-data.timer rustic-copy.timer

# Logically bound images: quadlet images are pulled with the host image.
RUN mkdir -p /usr/lib/bootc/bound-images.d && \
    find /usr/share/containers/systemd \
        \( -name '*.container' -o -name '*.image' \) \
        -exec ln -sf -t /usr/lib/bootc/bound-images.d {} +

# daily updates, reboot if needed (schedule in the timer drop-in)
RUN systemctl enable bootc-fetch-apply-updates.timer

# Off-peak power window, see docs/offpeak.md.
RUN systemctl enable offpeak-start.timer offpeak-stop.timer

RUN systemctl enable dev-almalinux-swap.swap

RUN dnf install -y greenboot && dnf clean all && \
    chmod 0755 /etc/greenboot/check/required.d/*.sh && \
    systemctl enable greenboot-healthcheck.service

ARG IMAGE_REVISION=unknown
ARG IMAGE_BUILD=dev
LABEL org.opencontainers.image.source="https://github.com/jonohill/nas-image" \
      org.opencontainers.image.revision="$IMAGE_REVISION" \
      nz.jonohill.build="$IMAGE_BUILD"
