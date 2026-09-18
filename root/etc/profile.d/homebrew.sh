# shellcheck shell=sh
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    export HOMEBREW_NO_ANALYTICS=1
fi
