#!/usr/bin/env bash
set -euo pipefail

# Basic Raspberry Pi bootstrap for Raspberry Pi OS / Debian
# Installs: zsh, oh-my-zsh, vim, git, python3, pip, venv, and useful CLI tooling.

log() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m⚠ %s\033[0m\n" "$*"; }

if [[ "${EUID}" -eq 0 ]]; then
  warn "Run this as your normal user (not root). Exiting."
  exit 1
fi

USER_NAME="$(id -un)"
HOME_DIR="${HOME}"
ZSH_PATH="$(command -v zsh || true)"

log "Updating package lists and upgrading existing packages"
sudo apt-get update -y
sudo apt-get upgrade -y

log "Installing base packages"
# Core + quality-of-life tools + dev essentials + network/debug tools
sudo apt-get install -y \
  zsh \
  vim \
  git \
  curl \
  wget \
  tmux \
  htop \
  jq \
  ripgrep \
  fzf \
  tree \
  unzip \
  zip \
  ca-certificates \
  gnupg \
  lsb-release \
  openssh-client \
  openssh-server \
  net-tools \
  dnsutils \
  iproute2 \
  iputils-ping \
  traceroute \
  nmap \
  rsync \
  screen \
  psmisc \
  software-properties-common \
  build-essential \
  make \
  cmake \
  pkg-config \
  python3 \
  python3-pip \
  python3-venv \
  python3-dev

log "Enabling SSH (safe default for headless / remote work)"
# Won't hurt if already enabled
sudo systemctl enable ssh || true
sudo systemctl start ssh || true

log "Upgrading pip tooling (user-level)"
python3 -m pip install --user --upgrade pip setuptools wheel

log "Installing Oh My Zsh (if not already installed)"
if [[ ! -d "${HOME_DIR}/.oh-my-zsh" ]]; then
  # Official unattended-ish installer. It may still prompt depending on environment.
  # We run it as your user (not sudo).
  export RUNZSH=no
  export CHSH=no
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
else
  log "Oh My Zsh already present at ${HOME_DIR}/.oh-my-zsh"
fi

log "Setting zsh as default shell for ${USER_NAME}"
ZSH_PATH="$(command -v zsh)"
if [[ -n "${ZSH_PATH}" ]]; then
  # Ensure zsh is in /etc/shells (normally is)
  if ! grep -q "^${ZSH_PATH}$" /etc/shells; then
    echo "${ZSH_PATH}" | sudo tee -a /etc/shells >/dev/null
  fi
  chsh -s "${ZSH_PATH}" "${USER_NAME}" || warn "Could not change shell automatically. You can run: chsh -s ${ZSH_PATH}"
else
  warn "zsh not found in PATH after install?"
fi

log "Configuring a sensible .zshrc (theme + plugins)"
ZSHRC="${HOME_DIR}/.zshrc"
if [[ -f "${ZSHRC}" ]]; then
  cp "${ZSHRC}" "${ZSHRC}.bak.$(date +%Y%m%d%H%M%S)"
fi

# Minimal, reliable defaults (avoid exotic plugins that may not exist)
# You can customize later.
cat > "${ZSHRC}" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git sudo python pip)

# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt hist_ignore_dups
setopt share_history

# Nice defaults
setopt auto_cd
setopt correct
autoload -U compinit && compinit

# Useful aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias gs='git status'
alias gd='git diff'
alias v='vim'
alias py='python3'

# Prefer user-local pip installs on PATH
export PATH="$HOME/.local/bin:$PATH"

source $ZSH/oh-my-zsh.sh
EOF

log "Dropping a basic .vimrc"
VIMRC="${HOME_DIR}/.vimrc"
if [[ -f "${VIMRC}" ]]; then
  cp "${VIMRC}" "${VIMRC}.bak.$(date +%Y%m%d%H%M%S)"
fi

cat > "${VIMRC}" <<'EOF'
set nocompatible
syntax on
set number
set relativenumber
set tabstop=2
set shiftwidth=2
set expandtab
set smartindent
set autoindent
set backspace=indent,eol,start
set incsearch
set hlsearch
set ignorecase
set smartcase
set cursorline
set mouse=a
set clipboard=unnamedplus
EOF

log "Setting up a default Python venv workspace"
mkdir -p "${HOME_DIR}/venvs"
if [[ ! -d "${HOME_DIR}/venvs/default" ]]; then
  python3 -m venv "${HOME_DIR}/venvs/default"
fi

log "Optional: install a few handy Python tools into the default venv"
# Activate and install common dev tooling
# shellcheck disable=SC1091
source "${HOME_DIR}/venvs/default/bin/activate"
python -m pip install --upgrade pip
python -m pip install \
  ipython \
  black \
  ruff \
  pytest \
  requests
deactivate

log "Done."
echo
echo "Next steps:"
echo "  1) Log out and back in (or reboot) so your default shell becomes zsh."
echo "  2) Start a new shell: zsh"
echo "  3) (Optional) Use your venv: source ~/venvs/default/bin/activate"
echo

