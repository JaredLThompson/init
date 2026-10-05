# init

Dev-box bootstrap scripts. The single entry point is **`setup.sh`**, which
replaces the five per-distro scripts that previously lived here (now preserved
under [`archive/`](archive/)).

## What it installs

- **zsh** + **oh-my-zsh** (theme `pygmalion`, plugins `git aws kubectl`)
- **git** + base packages (tar, gzip, unzip, ca-certificates, openssh, ...)
- **Extra utilities** (best-effort; per-distro package names handled):
  `vim`, `tcpdump`, `mtr`, `traceroute`, dig/`nslookup`, `nc` (netcat),
  `jq`, `htop`, `tmux`, `rsync`, `wget`
- **AWS CLI v2**
- **kubectl** (latest stable, per-arch)
- **Helm 3**
- **eksctl** (latest, per-arch)
- **Terraform** (from the correct HashiCorp repo for the distro)
- Aliases `tf` -> `terraform`, `k` -> `kubectl`
- An EC2 IMDSv2 prompt function that shows the instance's `console-name` tag
  (added **only when running on EC2**, detected automatically; uses IMDSv2
  tokens, never IMDSv1)
- SSH keepalive (`ServerAliveInterval 50`)
- Sets the login user's default shell to zsh

## Supported platforms

| Family | Package manager | Examples |
|--------|-----------------|----------|
| RHEL-like | `dnf` / `yum` | Amazon Linux 2023, Amazon Linux 2 |
| Debian-like | `apt` | Ubuntu, Raspberry Pi OS, Debian |

Architecture is auto-detected. `amd64` and `arm64` are fully supported.
On other arches (e.g. 32-bit x86) the base tooling still installs, but
kubectl/eksctl are skipped because upstream publishes no builds for them.

## Usage

Run as your normal sudo-capable user (not root):

```bash
./setup.sh
```

The script is **idempotent** — safe to re-run. Shell-rc edits are guarded by
sentinels (`### INIT_SETUP_*`, `### INIT_IMDS_*`) so re-runs don't duplicate
lines.

### Optional toggles

Each toggle is available as a command-line flag or an equivalent environment
variable. Run `./setup.sh --help` for the built-in menu.

| Flag | Variable | Effect |
|------|----------|--------|
| `--skip-k8s` | `SKIP_K8S=1` | Skip kubectl, Helm, eksctl |
| `--skip-helm` | `SKIP_HELM=1` | Skip Helm only |
| `--skip-eksctl` | `SKIP_EKSCTL=1` | Skip eksctl only |
| `--skip-terraform` | `SKIP_TERRAFORM=1` | Skip Terraform |
| `--skip-awscli` | `SKIP_AWSCLI=1` | Skip AWS CLI v2 |
| `--skip-extras` | `SKIP_EXTRAS=1` | Skip extra utilities (tcpdump, mtr, jq, vim, ...) |
| `--imds` | `FORCE_IMDS=1` | Force-add the EC2 instance-tag prompt (even off-EC2) |
| `--no-imds` | `SKIP_IMDS=1` | Never add the EC2 instance-tag prompt |
| `--skip-chsh` | `SKIP_CHSH=1` | Don't change the default shell to zsh |

Example:

```bash
./setup.sh --skip-helm --skip-eksctl      # kubectl only
SKIP_K8S=1 SKIP_TERRAFORM=1 ./setup.sh    # env-var form
```

## After running

```bash
# log out/in (or just start zsh) for the shell + config to take effect
zsh

# verify
aws --version
kubectl version --client
eksctl version
terraform version
```

## Archive

The original scripts are kept for reference in [`archive/`](archive/):

- `basic-al2023-arm64-setup.sh`
- `basic-al2023-setup.sh`
- `basic-amzn2-setup.sh`
- `basic-ubuntu-setup.sh` (had a bug: used `yum` to install Terraform on Ubuntu)
- `basic-raspi-bootstrap.sh`

## Development

Lint before committing changes to `setup.sh`:

```bash
bash -n setup.sh      # syntax check
shellcheck setup.sh   # static analysis
```
