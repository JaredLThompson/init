#!/usr/bin/env bash
#
# Unified dev-box bootstrap.
#
# Replaces the per-distro scripts (AL2023 / AL2 / Ubuntu / Raspberry Pi OS).
# Detects the package manager (dnf/yum or apt) and CPU arch, then installs a
# common toolchain: zsh + oh-my-zsh, git, vim, AWS CLI v2, kubectl, helm,
# eksctl, and terraform. All shell-rc edits are idempotent (guarded by
# sentinels or grep checks), so the script is safe to re-run.
#
# Usage:
#   ./setup.sh                 # full install
#   SKIP_K8S=1 ./setup.sh      # skip kubectl/helm/eksctl
#   SKIP_TERRAFORM=1 ./setup.sh
#   SKIP_AWSCLI=1 ./setup.sh
#   SKIP_CHSH=1 ./setup.sh     # don't change default shell to zsh
#
# Run as your normal (sudo-capable) user, NOT as root.

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log()  { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[warn] %s\033[0m\n" "$*" >&2; }
die()  { printf "\n\033[1;31m[error] %s\033[0m\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
  die "Run as your normal user (not root). The script uses sudo where needed."
fi

if ! command -v sudo >/dev/null 2>&1; then
  die "sudo is required but not found."
fi

USER_NAME="$(id -un)"
HOME_DIR="$HOME"
ZSHRC="${HOME_DIR}/.zshrc"
BASHRC="${HOME_DIR}/.bashrc"

# ---------------------------------------------------------------------------
# Detect architecture (Go-style names used by kubectl/eksctl/terraform)
# ---------------------------------------------------------------------------
initArch() {
  local raw
  raw="$(uname -m)"
  case "$raw" in
    armv5*)        ARCH="armv5" ;;
    armv6*)        ARCH="armv6" ;;
    armv7*)        ARCH="arm"   ;;
    aarch64|arm64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="amd64" ;;
    i686|i386|x86) ARCH="386"   ;;
    *)             ARCH="$raw"  ;;
  esac
  export ARCH
}
initArch

# kubectl / eksctl only publish amd64 and arm64 linux builds. Warn (don't fail)
# on other arches so the rest of the script still runs.
K8S_ARCH_OK=1
case "$ARCH" in
  amd64|arm64) ;;
  *) K8S_ARCH_OK=0 ;;
esac

# ---------------------------------------------------------------------------
# Detect package manager / distro family
# ---------------------------------------------------------------------------
OS_ID=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  OS_ID="$(. /etc/os-release && echo "${ID:-}")"
fi

if command -v dnf >/dev/null 2>&1; then
  PKG="dnf"; FAMILY="rhel"
elif command -v yum >/dev/null 2>&1; then
  PKG="yum"; FAMILY="rhel"
elif command -v apt-get >/dev/null 2>&1; then
  PKG="apt"; FAMILY="debian"
else
  die "No supported package manager found (need dnf, yum, or apt-get)."
fi

log "Detected: user=${USER_NAME} arch=${ARCH} os=${OS_ID:-unknown} pkg=${PKG} family=${FAMILY}"
if [[ "${K8S_ARCH_OK}" -eq 0 ]]; then
  warn "arch '${ARCH}' has no kubectl/eksctl builds; those will be skipped."
fi

# ---------------------------------------------------------------------------
# Package-manager wrappers
# ---------------------------------------------------------------------------
pkg_update() {
  case "$FAMILY" in
    rhel)   sudo "$PKG" -y update ;;
    debian) sudo apt-get update -y && sudo apt-get upgrade -y ;;
  esac
}

pkg_install() {
  case "$FAMILY" in
    rhel)   sudo "$PKG" -y install "$@" ;;
    debian) sudo apt-get install -y "$@" ;;
  esac
}

# ---------------------------------------------------------------------------
# Idempotent "append line to file if missing"
# ---------------------------------------------------------------------------
append_once() {
  # append_once <file> <line>
  local file="$1" line="$2"
  touch "$file"
  grep -qsF -- "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

# ---------------------------------------------------------------------------
# Base packages
# ---------------------------------------------------------------------------
log "Update package metadata / upgrade"
pkg_update

log "Install base packages"
case "$FAMILY" in
  rhel)
    # NOTE: do NOT install the full 'curl' package. AL2023/recent RHEL ship
    # 'curl-minimal' by default, which provides the curl binary; pulling in
    # 'curl' triggers an unresolvable conflict with 'curl-minimal'.
    # util-linux-user provides chsh on AL2023/AL2.
    pkg_install zsh git vim tar gzip unzip util-linux-user
    ;;
  debian)
    pkg_install zsh git vim wget unzip ca-certificates gnupg \
                openssh-client net-tools dnsutils iproute2 iputils-ping
    ;;
esac

# curl is required below. It's present on virtually all base images (via
# curl-minimal on RHEL). Only try to install it if the binary is missing.
if ! command -v curl >/dev/null 2>&1; then
  warn "curl not found; attempting to install it"
  pkg_install curl || die "curl is required but could not be installed"
fi

# ---------------------------------------------------------------------------
# AWS CLI v2
# ---------------------------------------------------------------------------
if [[ "${SKIP_AWSCLI:-0}" != "1" ]]; then
  if command -v aws >/dev/null 2>&1; then
    log "AWS CLI already installed: $(aws --version 2>&1)"
  elif [[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]]; then
    log "Install AWS CLI v2"
    case "$ARCH" in
      amd64) awscli_arch="x86_64" ;;
      arm64) awscli_arch="aarch64" ;;
    esac
    tmpd="$(mktemp -d)"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${awscli_arch}.zip" -o "${tmpd}/awscliv2.zip"
    unzip -q "${tmpd}/awscliv2.zip" -d "${tmpd}"
    sudo "${tmpd}/aws/install" --update
    rm -rf "${tmpd}"
  else
    warn "AWS CLI v2 has no build for arch '${ARCH}'; skipping."
  fi
fi

# ---------------------------------------------------------------------------
# kubectl (latest stable, per-arch)
# ---------------------------------------------------------------------------
mkdir -p "${HOME_DIR}/bin"
if [[ "${SKIP_K8S:-0}" != "1" && "${K8S_ARCH_OK}" -eq 1 ]]; then
  log "Install kubectl (latest stable)"
  kver="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo "${HOME_DIR}/bin/kubectl" \
    "https://dl.k8s.io/release/${kver}/bin/linux/${ARCH}/kubectl"
  chmod +x "${HOME_DIR}/bin/kubectl"

  log "Install Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get_helm.sh
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh
  rm -f /tmp/get_helm.sh

  log "Install eksctl (latest)"
  PLATFORM="$(uname -s)_${ARCH}"
  curl -fsSLo /tmp/eksctl.tar.gz \
    "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz"
  tar -xzf /tmp/eksctl.tar.gz -C /tmp && rm -f /tmp/eksctl.tar.gz
  sudo mv /tmp/eksctl /usr/local/bin/
else
  [[ "${SKIP_K8S:-0}" == "1" ]] && log "SKIP_K8S set; skipping kubectl/helm/eksctl"
fi

# ---------------------------------------------------------------------------
# Terraform (correct repo per family)
# ---------------------------------------------------------------------------
if [[ "${SKIP_TERRAFORM:-0}" != "1" ]]; then
  if command -v terraform >/dev/null 2>&1; then
    log "Terraform already installed: $(terraform version | head -n1)"
  else
    log "Install Terraform (HashiCorp repo)"
    case "$FAMILY" in
      rhel)
        pkg_install yum-utils
        # dnf uses the same config-manager plugin alias on AL2023.
        sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
        pkg_install terraform
        ;;
      debian)
        wget -qO- https://apt.releases.hashicorp.com/gpg \
          | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        # /etc/os-release only exists on the target host; safe to source at runtime.
        # shellcheck disable=SC1091
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs 2>/dev/null || . /etc/os-release && echo "$VERSION_CODENAME") main" \
          | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
        sudo apt-get update -y
        pkg_install terraform
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Oh My Zsh (unattended, idempotent)
# ---------------------------------------------------------------------------
log "Install Oh My Zsh"
if [[ ! -d "${HOME_DIR}/.oh-my-zsh" ]]; then
  export RUNZSH=no CHSH=no
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
  log "Oh My Zsh already present"
fi
touch "$ZSHRC"

# ---------------------------------------------------------------------------
# zsh theme + plugins (idempotent sed with fallback)
# ---------------------------------------------------------------------------
log "Configure zsh theme + plugins"
if grep -q '^ZSH_THEME=' "$ZSHRC"; then
  sed -i 's/^ZSH_THEME=.*/ZSH_THEME="pygmalion"/' "$ZSHRC"
else
  echo 'ZSH_THEME="pygmalion"' >> "$ZSHRC"
fi
if grep -q '^plugins=' "$ZSHRC"; then
  sed -i 's/^plugins=.*/plugins=(git aws kubectl)/' "$ZSHRC"
else
  echo 'plugins=(git aws kubectl)' >> "$ZSHRC"
fi

# ---------------------------------------------------------------------------
# PATH + aliases (guarded block, written once)
# ---------------------------------------------------------------------------
log "Add PATH + aliases"
if ! grep -q '### INIT_SETUP_START' "$ZSHRC"; then
  cat <<'EOF' >> "$ZSHRC"

### INIT_SETUP_START
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
alias tf="terraform"
alias k="kubectl"
### INIT_SETUP_END
EOF
fi
# Keep bash usable too (login user may land in bash before chsh takes effect).
# Intentionally single-quoted: the line must expand at shell startup, not now.
# shellcheck disable=SC2016
append_once "$BASHRC" 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"'

# ---------------------------------------------------------------------------
# EC2 IMDS tag -> prompt (guarded block)
# ---------------------------------------------------------------------------
log "Add EC2 instance-tag prompt function"
if ! grep -q '### INIT_IMDS_START' "$ZSHRC"; then
  cat <<'EOF' >> "$ZSHRC"

### INIT_IMDS_START
# Show an EC2 instance tag (console-name) in the prompt, if present.
function get_instance_tag() {
    TAG_KEY="console-name"
    CACHE_FILE="/tmp/instance_tag_cache"
    CURRENT_TIME=$(date +%s)

    if [ -f "$CACHE_FILE" ]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            FILE_TIME=$(stat -f %m "$CACHE_FILE")
        else
            FILE_TIME=$(stat -c %Y "$CACHE_FILE")
        fi
        if (( CURRENT_TIME - FILE_TIME < 3600 )); then
            cat "$CACHE_FILE"
            return
        fi
    fi

    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
    TAG_VALUE=$(curl -s -f -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/tags/instance/$TAG_KEY" 2>/dev/null)

    if [ -n "$TAG_VALUE" ]; then
        echo "$TAG_VALUE" > "$CACHE_FILE"
        echo "$TAG_VALUE"
    fi
}
PROMPT='$(tag=$(get_instance_tag); if [ -n "$tag" ]; then echo "%{$fg[green]%}[$tag]%{$reset_color%} "; fi)'$PROMPT
### INIT_IMDS_END
EOF
fi

# ---------------------------------------------------------------------------
# SSH keepalive (idempotent)
# ---------------------------------------------------------------------------
log "Configure SSH keepalive"
mkdir -p "${HOME_DIR}/.ssh"
chmod 700 "${HOME_DIR}/.ssh"
append_once "${HOME_DIR}/.ssh/config" 'ServerAliveInterval 50'
chmod 600 "${HOME_DIR}/.ssh/config"

# ---------------------------------------------------------------------------
# Default shell -> zsh (for the detected user)
# ---------------------------------------------------------------------------
if [[ "${SKIP_CHSH:-0}" != "1" ]]; then
  log "Set default shell to zsh for ${USER_NAME}"
  ZSH_BIN="$(command -v zsh || true)"
  if [[ -n "$ZSH_BIN" ]]; then
    if ! grep -qx "$ZSH_BIN" /etc/shells 2>/dev/null; then
      echo "$ZSH_BIN" | sudo tee -a /etc/shells >/dev/null
    fi
    sudo chsh -s "$ZSH_BIN" "$USER_NAME" || warn "chsh failed; run manually: chsh -s $ZSH_BIN"
  else
    warn "zsh not found after install?"
  fi
fi

log "Done."
echo
echo "Next steps:"
echo "  - Log out/in (or run 'zsh') for the new shell + config to take effect."
echo "  - Verify tools: aws --version; kubectl version --client; eksctl version; terraform version"
