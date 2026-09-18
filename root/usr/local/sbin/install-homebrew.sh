#!/usr/bin/env bash

set -euo pipefail

prefix=/home/linuxbrew/.linuxbrew
owner=jono

if [ -x "$prefix/bin/brew" ]; then
    echo "Homebrew already installed at $prefix; nothing to do."
    exit 0
fi

home="$(getent passwd "$owner" | cut -d: -f6)"
: "${home:?no home directory for $owner}"

staging="$(mktemp -d /var/home/.homebrew-install.XXXXXX)"
trap 'rm -rf "$staging"' EXIT

git clone https://github.com/Homebrew/brew "$staging/Homebrew"

mkdir -p "$prefix/bin"
mv "$staging/Homebrew" "$prefix/Homebrew"
ln -sf ../Homebrew/bin/brew "$prefix/bin/brew"
chown -R "$owner:$owner" /home/linuxbrew

runuser -u "$owner" -- env "HOME=$home" "USER=$owner" HOMEBREW_NO_ANALYTICS=1 \
    "$prefix/bin/brew" update --force --quiet

echo "Homebrew installed at $prefix."
