# The i5-3570K (Ivy Bridge) has no AVX2, so it needs AlmaLinux's x86_64_v2
# build. The :10 index carries it as the linux/amd64/v2 platform.
FROM --platform=linux/amd64/v2 quay.io/almalinuxorg/almalinux-bootc:10

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
