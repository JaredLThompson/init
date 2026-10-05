#!/usr/bin/env bash
set -euo pipefail

# Basic Raspberry Pi OS bootstrap (Debian-based)
# Installs: zsh, oh-my-zsh, vim, git, python3, pip, venv + useful tooling
# Also sets zsh default shell and adds a few sensible defaults.

log()  { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m⚠ %s\033[0m\n" "$*"; }

if [[ "${EUID}" -eq 0 ]]; then
  warn "Run as your normal user (not root)."
  exit 1
fi

USER_NAME="$(id -un)"
HOME_DIR="$HOME"

initArch() {
  ARCH="$(uname -m)"
  case "$ARCH" in
    armv5*) ARCH="armv5" ;;
    armv6*) ARCH="armv6" ;;
    armv7*) ARCH="arm" ;;
    aarch64) ARCH="arm64" ;;
    x86_64) ARCH="amd64" ;;
    i686|i386) ARCH="386" ;;
    *) ARCH="$ARCH" ;;
  esac
  export ARCH
}
initArch
log "Detected arch: ${ARCH}"

log "Update + upgrade"
sudo apt-get update -y
sudo apt-get upgrade -y

log "Install base packages"
# Notes:
# - `software-properties-common` is often not present on Raspberry Pi OS; we intentionally do NOT install it.
# - `ripgrep` package name is `ripgrep`; `fd-find` provides `fdfind` binary on Debian.
sudo apt-get install -y zsh
sudo apt-get install -y pipx

sudo apt-get install -y \
  git \
  vim \
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
  openssh-client \
  openssh-server \
  rsync \
  net-tools \
  dnsutils \
  iproute2 \
  iputils-ping \
  traceroute \
  psmisc \
  build-essential \
  make \
  cmake \
  pkg-config \
  python3 \
  python3-pip \
  python3-venv \
  python3-dev

log "Enable SSH (safe default; harmless if already enabled)"
sudo systemctl enable ssh >/dev/null 2>&1 || true
sudo systemctl start ssh  >/dev/null 2>&1 || true

log "Set up pipx (Python CLI tools in isolated envs)"
python3 -m pipx ensurepath || true
# ensurepath updates shell rc; also add ~/.local/bin to PATH in .zshrc (we already do)

# Install useful Python CLIs (safe, isolated)
pipx install ruff || pipx upgrade ruff
pipx install black || pipx upgrade black
pipx install ipython || pipx upgrade ipython
pipx install pytest || pipx upgrade pytest


log "Install Oh My Zsh (unattended)"
if [[ ! -d "${HOME_DIR}/.oh-my-zsh" ]]; then
  export RUNZSH=no
  export CHSH=no
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
  log "Oh My Zsh already installed"
fi

log "Ensure .zshrc exists"
touch "${HOME_DIR}/.zshrc"

log "Set default shell to zsh for ${USER_NAME}"
ZSH_BIN="$(command -v zsh)"
if [[ -n "${ZSH_BIN}" ]]; then
  if ! grep -q "^${ZSH_BIN}$" /etc/shells; then
    echo "${ZSH_BIN}" | sudo tee -a /etc/shells >/dev/null
  fi
  chsh -s "${ZSH_BIN}" "${USER_NAME}" || warn "chsh failed; run manually: chsh -s ${ZSH_BIN}"
else
  warn "zsh not found after install?"
fi

log "Configure Oh My Zsh theme + plugins"
# Ensure a theme that exists in default OMZ. (pygmalion usually exists; robbyrussell definitely does.)
# If pygmalion isn't present for some reason, we fall back.
if grep -q '^ZSH_THEME=' "${HOME_DIR}/.zshrc"; then
  sed -i 's/^ZSH_THEME=.*/ZSH_THEME="pygmalion"/' "${HOME_DIR}/.zshrc"
else
  echo 'ZSH_THEME="pygmalion"' >> "${HOME_DIR}/.zshrc"
fi

# Plugins: keep them conservative (installed with OMZ, no extra deps)
# Add more later: zsh-autosuggestions, zsh-syntax-highlighting (manual install)
if grep -q '^plugins=' "${HOME_DIR}/.zshrc"; then
  sed -i 's/^plugins=.*/plugins=(git sudo python pip)/' "${HOME_DIR}/.zshrc"
else
  echo 'plugins=(git sudo python pip)' >> "${HOME_DIR}/.zshrc"
fi

log "Add PATH + aliases + a few quality-of-life defaults"
# Avoid duplicating blocks on re-run
if ! grep -q '### PI_BOOTSTRAP_START' "${HOME_DIR}/.zshrc"; then
  cat <<'EOF' >> "${HOME_DIR}/.zshrc"

### PI_BOOTSTRAP_START
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

alias ll='ls -alF'
alias gs='git status'
alias gd='git diff'
alias v='vim'
alias py='python3'

# Better history behavior
HISTSIZE=10000
SAVEHIST=10000
setopt hist_ignore_dups
setopt share_history
### PI_BOOTSTRAP_END
EOF
fi

log "Drop a basic .vimrc (backup if existing)"
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
set incsearch
set hlsearch
set ignorecase
set smartcase
set cursorline
EOF

log "Create a default Python venv workspace"
mkdir -p "${HOME_DIR}/venvs"
if [[ ! -d "${HOME_DIR}/venvs/default" ]]; then
  python3 -m venv "${HOME_DIR}/venvs/default"
fi

log "Optional: install a few common Python tools in the venv"
# shellcheck disable=SC1091
source "${HOME_DIR}/venvs/default/bin/activate"
python -m pip install --upgrade pip
python -m pip install ipython ruff black pytest requests
deactivate

log "Done."
echo
echo "Next steps:"
echo "  - Log out/in (or reboot) for default shell change to take effect."
echo "  - Start zsh: zsh"
echo "  - Source venv: source ~/venvs/default/bin/activate"
echo

