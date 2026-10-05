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
#   SKIP_K8S=1 ./setup.sh      # skip kubectl + helm + eksctl
#   SKIP_HELM=1 ./setup.sh     # skip helm only
#   SKIP_EKSCTL=1 ./setup.sh   # skip eksctl only
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
# Usage / argument parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Unified dev-box bootstrap.

Detects the package manager (dnf/yum or apt) and CPU arch, then installs a
common toolchain: zsh + oh-my-zsh, git, vim, AWS CLI v2, kubectl, helm,
eksctl, and terraform. Idempotent: safe to re-run.

USAGE:
  ./setup.sh [options]

OPTIONS:
  -h, --help         Show this help and exit.
      --skip-k8s     Skip kubectl, Helm, and eksctl.
      --skip-helm    Skip Helm only.
      --skip-eksctl  Skip eksctl only.
      --skip-terraform
                     Skip Terraform.
      --skip-awscli  Skip AWS CLI v2.
      --skip-extras  Skip extra utilities (tcpdump, mtr, jq, vim, ...).
      --imds         Force-add the EC2 instance-tag prompt (even off-EC2).
      --no-imds      Never add the EC2 instance-tag prompt.
      --skip-chsh    Don't change the default shell to zsh.

By default the EC2 instance-tag prompt is added only when running on an EC2
instance (detected via DMI identifiers and an IMDSv2 token request).

Each option has an equivalent environment variable (set to 1):
  SKIP_K8S  SKIP_HELM  SKIP_EKSCTL  SKIP_TERRAFORM  SKIP_AWSCLI  SKIP_EXTRAS
  FORCE_IMDS  SKIP_IMDS  SKIP_CHSH

EXAMPLES:
  ./setup.sh                              # full install
  ./setup.sh --skip-helm --skip-eksctl    # kubectl only, no helm/eksctl
  SKIP_K8S=1 ./setup.sh                   # env-var form
  ./setup.sh --skip-terraform --skip-awscli

Run as your normal (sudo-capable) user, NOT as root.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)        usage; exit 0 ;;
    --skip-k8s)       SKIP_K8S=1 ;;
    --skip-helm)      SKIP_HELM=1 ;;
    --skip-eksctl)    SKIP_EKSCTL=1 ;;
    --skip-terraform) SKIP_TERRAFORM=1 ;;
    --skip-awscli)    SKIP_AWSCLI=1 ;;
    --skip-extras)    SKIP_EXTRAS=1 ;;
    --imds)           FORCE_IMDS=1 ;;
    --no-imds)        SKIP_IMDS=1 ;;
    --skip-chsh)      SKIP_CHSH=1 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

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
# Hardened download helper.
# curl with no timeout can hang indefinitely on a stalled connection (common
# on Pis with flaky WiFi / IPv6 black-holes). These flags make a stuck fetch
# fail fast and retry, and show progress so a slow download isn't mistaken
# for a hang.
#   --connect-timeout 15 : give up establishing the TCP connection after 15s
#   --max-time 600       : hard cap the whole transfer at 10 min
#   --retry 3            : retry transient failures (with backoff)
#   -fL --progress-bar   : fail on HTTP errors, follow redirects, show progress
# ---------------------------------------------------------------------------
fetch() {
  # fetch <url> <output-path>
  curl -fL --connect-timeout 15 --max-time 600 --retry 3 --retry-delay 2 \
       --progress-bar "$1" -o "$2"
}
# Quiet variant for tiny responses (e.g. version strings).
fetch_quiet() {
  # fetch_quiet <url>
  curl -fsL --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 2 "$1"
}

# ---------------------------------------------------------------------------
# EC2 detection.
# Two cheap, independent signals (either is sufficient):
#   1) DMI identifiers — present on EC2 without any network call. Nitro
#      instances report "Amazon EC2" as the sys-vendor/board-vendor; older
#      Xen instances have a hypervisor UUID starting with "ec2".
#   2) IMDS reachability — a short-timeout IMDSv2 token request succeeds only
#      on an instance (link-local 169.254.169.254).
# ---------------------------------------------------------------------------
is_ec2() {
  # DMI check (no network).
  local dmi
  for dmi in /sys/class/dmi/id/sys_vendor \
             /sys/class/dmi/id/board_vendor \
             /sys/class/dmi/id/bios_vendor; do
    if [[ -r "$dmi" ]] && grep -qi 'amazon' "$dmi" 2>/dev/null; then
      return 0
    fi
  done
  if [[ -r /sys/hypervisor/uuid ]] && grep -qi '^ec2' /sys/hypervisor/uuid 2>/dev/null; then
    return 0
  fi
  # IMDS check (fast fail off-instance). Be strict: a non-empty body is NOT
  # enough -- captive portals, proxies, or a link-local route (e.g. WireGuard
  # catching 169.254.0.0/16) can answer with HTML/other content. Require an
  # HTTP 200 AND a response that actually looks like an IMDSv2 token
  # (reasonably long, single line, no whitespace or HTML markup).
  local token http_code tokfile
  tokfile="$(mktemp)"
  http_code=$(curl -s -o "$tokfile" -w '%{http_code}' \
            -X PUT "http://169.254.169.254/latest/api/token" \
            --connect-timeout 1 --max-time 2 \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
  token="$(cat "$tokfile" 2>/dev/null)"
  rm -f "$tokfile"
  [[ "$http_code" == "200" ]] || return 1
  # Token must be a single whitespace-free line of plausible length and must
  # not contain '<' (would indicate an HTML error/portal page).
  [[ "$token" =~ ^[A-Za-z0-9+/=_-]{20,}$ ]]
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
# Remove a previously-injected sentinel block (inclusive of start/end markers)
# plus one blank line directly above it (we prepend one when injecting).
# Writes a timestamped .bak first.
# ---------------------------------------------------------------------------
remove_sentinel_block() {
  # remove_sentinel_block <file> <start-marker> <end-marker>
  local file="$1" start="$2" end="$3"
  [[ -f "$file" ]] || return 0
  grep -qF -- "$start" "$file" || return 0
  # Always back up BEFORE modifying. If the backup can't be written, do not
  # touch the original.
  local backup
  backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
  if ! cp "$file" "$backup"; then
    warn "could not back up ${file}; leaving it unchanged"
    return 1
  fi
  awk -v s="$start" -v e="$end" '
    # Buffer blank lines so we can drop the one just before the start marker.
    {
      if ($0 == s) { blank=0; skip=1; next }     # drop pending blank, start skipping
      if (skip)    { if ($0 == e) skip=0; next }  # inside block (incl. end marker)
      if ($0 == "") { blank++; next }             # hold blank lines
      while (blank>0) { print ""; blank-- }       # flush held blanks
      print
    }
    END { while (blank>0) { print ""; blank-- } }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
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
    # (vim lives in the best-effort extras group below, since the RHEL
    #  package is 'vim-enhanced' and may be absent on minimal images.)
    pkg_install zsh git tar gzip unzip util-linux-user
    ;;
  debian)
    pkg_install zsh git unzip ca-certificates gnupg openssh-client
    ;;
esac

# curl is required below. It's present on virtually all base images (via
# curl-minimal on RHEL). Only try to install it if the binary is missing.
if ! command -v curl >/dev/null 2>&1; then
  warn "curl not found; attempting to install it"
  pkg_install curl || die "curl is required but could not be installed"
fi

# ---------------------------------------------------------------------------
# Extra utilities (best-effort: a missing package warns but never aborts).
# Package names differ between families, so map them per-family.
# ---------------------------------------------------------------------------
if [[ "${SKIP_EXTRAS:-0}" != "1" ]]; then
  log "Install extra utilities (best-effort)"
  case "$FAMILY" in
    rhel)
      EXTRAS=(vim-enhanced tcpdump mtr traceroute bind-utils nmap-ncat jq htop tmux rsync wget)
      ;;
    debian)
      # mtr -> mtr-tiny (avoids GTK/X11 deps); nc -> netcat-openbsd; dig -> dnsutils.
      EXTRAS=(vim tcpdump mtr-tiny traceroute dnsutils netcat-openbsd jq htop tmux rsync wget \
              net-tools iproute2 iputils-ping)
      ;;
  esac
  # Install individually so one unavailable package can't block the rest.
  for pkg in "${EXTRAS[@]}"; do
    pkg_install "$pkg" || warn "optional package '$pkg' not installed (skipping)"
  done
else
  log "SKIP_EXTRAS set; skipping extra utilities"
fi

# ---------------------------------------------------------------------------
# AWS CLI v2
# ---------------------------------------------------------------------------
if [[ "${SKIP_AWSCLI:-0}" != "1" ]]; then
  # Detect an existing install independent of the current PATH. The AWS CLI v2
  # installer symlinks the binary into /usr/local/bin (default --bin-dir) and
  # keeps the real binary under /usr/local/aws-cli/v2/current/bin. A non-login
  # shell may not have /usr/local/bin on PATH, so check the known locations.
  aws_bin=""
  for cand in \
    "$(command -v aws 2>/dev/null || true)" \
    /usr/local/bin/aws \
    /usr/local/aws-cli/v2/current/bin/aws
  do
    if [[ -n "$cand" && -x "$cand" ]]; then
      aws_bin="$cand"
      break
    fi
  done

  if [[ -n "$aws_bin" ]]; then
    log "AWS CLI already installed: $("$aws_bin" --version 2>&1)"
  elif [[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]]; then
    log "Install AWS CLI v2"
    case "$ARCH" in
      amd64) awscli_arch="x86_64" ;;
      arm64) awscli_arch="aarch64" ;;
    esac

    # Self-heal: a prior interrupted install can leave a version directory
    # under /usr/local/aws-cli/v2/ with no runnable binary and no 'current'
    # symlink. The installer's --update then sees "same version" and skips
    # forever, never repairing it. If we got here, no runnable binary was
    # found, so if an install tree exists it is broken -> remove it and do a
    # clean install (without --update).
    install_mode="--update"
    if [[ -d /usr/local/aws-cli ]] && [[ ! -x /usr/local/aws-cli/v2/current/bin/aws ]]; then
      warn "Found a broken AWS CLI install tree; removing it for a clean reinstall"
      sudo rm -rf /usr/local/aws-cli /usr/local/bin/aws
      install_mode=""
    fi

    tmpd="$(mktemp -d)"
    fetch "https://awscli.amazonaws.com/awscli-exe-linux-${awscli_arch}.zip" "${tmpd}/awscliv2.zip"
    log "Unzipping AWS CLI bundle..."
    unzip -q "${tmpd}/awscliv2.zip" -d "${tmpd}"
    log "Running AWS CLI installer (this can take several minutes on a Pi)..."
    # shellcheck disable=SC2086  # install_mode is intentionally unquoted (may be empty)
    if ! sudo "${tmpd}/aws/install" $install_mode; then
      warn "AWS CLI installer exited non-zero; check output above"
    fi
    rm -rf "${tmpd}"
    # Verify the install actually produced a runnable binary.
    if [[ -x /usr/local/bin/aws ]]; then
      log "AWS CLI installed: $(/usr/local/bin/aws --version 2>&1)"
    elif [[ -x /usr/local/aws-cli/v2/current/bin/aws ]]; then
      log "AWS CLI installed: $(/usr/local/aws-cli/v2/current/bin/aws --version 2>&1)"
    else
      warn "AWS CLI install did not produce a binary at the expected location"
    fi
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
  kver="$(fetch_quiet https://dl.k8s.io/release/stable.txt)"
  fetch "https://dl.k8s.io/release/${kver}/bin/linux/${ARCH}/kubectl" "${HOME_DIR}/bin/kubectl"
  chmod +x "${HOME_DIR}/bin/kubectl"

  if [[ "${SKIP_HELM:-0}" != "1" ]]; then
    log "Install Helm"
    fetch https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 /tmp/get_helm.sh
    chmod 700 /tmp/get_helm.sh
    /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh
  else
    log "SKIP_HELM set; skipping Helm"
  fi

  if [[ "${SKIP_EKSCTL:-0}" != "1" ]]; then
    log "Install eksctl (latest)"
    PLATFORM="$(uname -s)_${ARCH}"
    fetch "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz" /tmp/eksctl.tar.gz
    tar -xzf /tmp/eksctl.tar.gz -C /tmp && rm -f /tmp/eksctl.tar.gz
    sudo mv /tmp/eksctl /usr/local/bin/
  else
    log "SKIP_EKSCTL set; skipping eksctl"
  fi
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
# EC2 IMDS tag -> prompt (guarded block, only on EC2)
# ---------------------------------------------------------------------------
# Decide whether to add the IMDS prompt function. By default we add it only
# when running on an EC2 instance, so non-EC2 hosts (e.g. a Raspberry Pi)
# don't carry a prompt hook that queries a link-local address they can't
# reach. Override with FORCE_IMDS=1 (--imds) or disable with SKIP_IMDS=1
# (--no-imds).
add_imds=0
if [[ "${SKIP_IMDS:-0}" == "1" ]]; then
  log "SKIP_IMDS set; not adding EC2 instance-tag prompt"
elif [[ "${FORCE_IMDS:-0}" == "1" ]]; then
  log "FORCE_IMDS set; adding EC2 instance-tag prompt regardless of host"
  add_imds=1
elif is_ec2; then
  log "EC2 instance detected; adding instance-tag prompt function"
  add_imds=1
else
  log "Not an EC2 instance; skipping instance-tag prompt (use --imds to force)"
fi

if [[ "$add_imds" -eq 1 ]]; then
  if ! grep -q '### INIT_IMDS_START' "$ZSHRC"; then
    cat <<'EOF' >> "$ZSHRC"

### INIT_IMDS_START
# Show an EC2 instance tag (console-name) in the prompt, if present.
# The result (including an empty "no tag / not reachable" result) is cached
# for an hour, so the prompt makes at most one IMDS probe per hour rather
# than a blocking curl on every single prompt render.
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

    # IMDSv2 only: first obtain a session token (PUT), then send it on the
    # metadata request. We never fall back to unauthenticated IMDSv1.
    # Short timeouts: on a non-EC2 host (e.g. a Pi) 169.254.169.254 is not
    # reachable; without these the prompt would stall on every render.
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        --connect-timeout 1 --max-time 2 \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)

    TAG_VALUE=""
    if [ -n "$TOKEN" ]; then
        TAG_VALUE=$(curl -s -f --connect-timeout 1 --max-time 2 \
            -H "X-aws-ec2-metadata-token: $TOKEN" \
            "http://169.254.169.254/latest/meta-data/tags/instance/$TAG_KEY" 2>/dev/null)
    fi

    # Cache the result either way (empty on a non-EC2 host / no tag), so we
    # don't re-probe IMDS on every prompt. The cache expires after an hour.
    echo "$TAG_VALUE" > "$CACHE_FILE"
    [ -n "$TAG_VALUE" ] && echo "$TAG_VALUE"
}
PROMPT='$(tag=$(get_instance_tag); if [ -n "$tag" ]; then echo "%{$fg[green]%}[$tag]%{$reset_color%} "; fi)'$PROMPT
### INIT_IMDS_END
EOF
    log "Instance-tag prompt added to ${ZSHRC}"
  else
    log "Instance-tag prompt already present in ${ZSHRC}"
  fi
else
  # Not adding IMDS -> remove any block a previous run (or older script
  # version) injected, so non-EC2 hosts don't keep a stale prompt hook.
  if grep -q '### INIT_IMDS_START' "$ZSHRC" 2>/dev/null; then
    remove_sentinel_block "$ZSHRC" '### INIT_IMDS_START' '### INIT_IMDS_END'
    log "Removed stale instance-tag prompt block from ${ZSHRC} (backup saved)"
  fi
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
