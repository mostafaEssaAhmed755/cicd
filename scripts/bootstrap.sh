#!/usr/bin/env bash
#
# bootstrap.sh — Prepare a fresh Ubuntu Server 24.04 LTS host to act as a
#                GitHub Actions Self-Hosted Runner for Docker deployments.
#
# The script is idempotent: it is safe to run multiple times. It never runs as
# root directly (it escalates with sudo where required) and never prints or
# persists the provided Personal Access Token (PAT).
#
# Usage:
#   curl -fsSL <bootstrap-url> | bash -s -- \
#     --owner <github-owner> \
#     --repo  <repository> \
#     --pat   <github-personal-access-token> \
#     [--runner-name <name>]        # optional, defaults to the hostname
#     [--work-dir  <path>]          # optional, defaults to _work
#     [--labels    <csv>]           # optional extra runner labels
#
# Requirements:
#   * Ubuntu 24.04 LTS (also works on 22.04)
#   * A non-root user with passwordless or interactive sudo access
#   * A GitHub PAT with `repo` scope (classic) or `administration:write`
#     (fine-grained) on the target repository.
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants & globals
# ---------------------------------------------------------------------------
readonly CICD_DIR="/opt/cicd"
readonly RUNNER_DIR="${CICD_DIR}/actions-runner"
readonly GITHUB_API="https://api.github.com"
readonly RUNNER_REPO="actions/runner"

# CLI arguments (populated by parse_args)
OWNER=""
REPO=""
PAT=""
RUNNER_NAME="$(hostname -s)"
WORK_DIR="_work"
EXTRA_LABELS=""
DO_UPGRADE=false   # full `apt upgrade` is opt-in (see --upgrade)
DRY_RUN=false      # print intended actions without changing the system

# ---------------------------------------------------------------------------
# Logging helpers (colorized when attached to a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_RED=$'\033[0;31m'
  readonly C_GREEN=$'\033[0;32m'
  readonly C_YELLOW=$'\033[0;33m'
  readonly C_BLUE=$'\033[0;34m'
  readonly C_BOLD=$'\033[1m'
else
  readonly C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD=""
fi

log()      { printf '%s[ %s ]%s %s\n' "$C_BLUE"   "$(date '+%H:%M:%S')" "$C_RESET" "$*"; }
info()     { printf '%s➜%s  %s\n'      "$C_BLUE"   "$C_RESET" "$*"; }
success()  { printf '%s✔%s  %s\n'      "$C_GREEN"  "$C_RESET" "$*"; }
warn()     { printf '%s⚠%s  %s\n'      "$C_YELLOW" "$C_RESET" "$*" >&2; }
error()    { printf '%s✗%s  %s\n'      "$C_RED"    "$C_RESET" "$*" >&2; }
step()     { printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET"; }

die() { error "$*"; exit 1; }

# In dry-run mode, announce an intended action and signal callers to skip it.
# Usage:  dry_run && dry_notice "would install Docker" && return 0
dry_run()    { [[ "$DRY_RUN" == true ]]; }
dry_notice() { printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }

# ---------------------------------------------------------------------------
# Error trap — report the failing line for easier debugging
# ---------------------------------------------------------------------------
_ERR_HANDLED=false
on_error() {
  local exit_code=$?
  local line_no=${1:-?}
  # Guard against the ERR trap firing more than once as the stack unwinds.
  [[ "$_ERR_HANDLED" == true ]] && exit "$exit_code"
  _ERR_HANDLED=true
  error "Failed at line ${line_no} (exit code ${exit_code})."
  error "Bootstrap aborted. Re-run the script to resume — it is idempotent."
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

# Run a command as root via sudo, prompting for a password only if needed.
as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Map `uname -m` to the architecture slug used by the GitHub runner assets.
runner_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

# Print the systemd unit name of the installed runner service (empty if none).
runner_service_name() {
  systemctl list-units --type=service --all --no-legend 'actions.runner.*' \
    2>/dev/null | awk '{print $1}' | head -n1
}

# Succeed only if the runner service exists and is currently active.
runner_service_active() {
  local svc
  svc="$(runner_service_name)"
  [[ -n "$svc" ]] && systemctl is-active --quiet "$svc"
}

# ---------------------------------------------------------------------------
# Argument parsing & validation
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${C_BOLD}bootstrap.sh${C_RESET} — configure this host as a GitHub Actions self-hosted runner.

${C_BOLD}Required arguments:${C_RESET}
  --owner  <owner>    GitHub organization or user that owns the repository
  --repo   <repo>     Repository name
  --pat    <token>    GitHub Personal Access Token (used once, never stored)

${C_BOLD}Optional arguments:${C_RESET}
  --runner-name <n>   Runner display name        (default: hostname = ${RUNNER_NAME})
  --work-dir    <p>   Runner work directory      (default: ${WORK_DIR})
  --labels      <csv> Extra comma-separated labels for the runner
  --upgrade           Also run 'apt-get upgrade' (off by default; may pull a
                      new kernel and require a reboot — avoid in automation)
  --dry-run           Print what the script would do without changing anything
  -h, --help          Show this help and exit
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner)        OWNER="${2:-}"; shift 2 ;;
      --repo)         REPO="${2:-}"; shift 2 ;;
      --pat)          PAT="${2:-}"; shift 2 ;;
      --runner-name)  RUNNER_NAME="${2:-}"; shift 2 ;;
      --work-dir)     WORK_DIR="${2:-}"; shift 2 ;;
      --labels)       EXTRA_LABELS="${2:-}"; shift 2 ;;
      --upgrade)      DO_UPGRADE=true; shift ;;
      --dry-run)      DRY_RUN=true; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              usage; die "Unknown argument: $1" ;;
    esac
  done
}

validate_args() {
  [[ -n "$OWNER" ]] || { usage; die "Missing required argument: --owner"; }
  [[ -n "$REPO"  ]] || { usage; die "Missing required argument: --repo"; }
  [[ -n "$PAT"   ]] || { usage; die "Missing required argument: --pat"; }
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
  step "Preflight checks"

  if [[ "$(id -u)" -eq 0 ]]; then
    die "Do not run this script as root. Run as a regular user; it uses sudo where needed."
  fi

  if ! command_exists sudo; then
    die "sudo is required but not installed."
  fi

  # Validate (and cache) sudo credentials up-front so long steps don't stall.
  # Skipped in dry-run mode since nothing will actually be executed.
  if ! dry_run && ! sudo -n true 2>/dev/null; then
    info "Requesting sudo privileges…"
    sudo -v
  fi

  if [[ ! -r /etc/os-release ]]; then
    warn "/etc/os-release not found — cannot verify the OS, continuing anyway."
  else
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      warn "This script targets Ubuntu; detected '${ID:-unknown}'. Continuing anyway."
    else
      success "Detected Ubuntu ${VERSION_ID:-?} (${VERSION_CODENAME:-?})."
    fi
  fi
}

# ---------------------------------------------------------------------------
# 1. System update
# ---------------------------------------------------------------------------
update_system() {
  step "Updating the operating system"
  if dry_run; then
    dry_notice "apt-get update"
    $DO_UPGRADE && dry_notice "apt-get upgrade (--upgrade set)"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  as_root apt-get update -y
  # Full upgrade is opt-in: it can pull a new kernel and require a reboot,
  # which is undesirable in unattended automation. Enable with --upgrade.
  if $DO_UPGRADE; then
    as_root apt-get upgrade -y
    success "Package lists refreshed and packages upgraded."
  else
    success "Package lists refreshed (skipping full upgrade; pass --upgrade to enable)."
  fi
}

# ---------------------------------------------------------------------------
# 2. Base packages
# ---------------------------------------------------------------------------
install_base_packages() {
  step "Installing base packages"
  local packages=(
    git curl wget jq unzip zip rsync tar
    ca-certificates gnupg lsb-release
    apt-transport-https software-properties-common
  )
  if dry_run; then dry_notice "apt-get install: ${packages[*]}"; return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  as_root apt-get install -y --no-install-recommends "${packages[@]}"
  success "Base packages installed: ${packages[*]}"
}

# ---------------------------------------------------------------------------
# 3 & 4. Docker Engine + Compose plugin (only if missing)
# ---------------------------------------------------------------------------
install_docker() {
  step "Installing Docker Engine & Compose plugin"

  if command_exists docker && docker compose version >/dev/null 2>&1; then
    success "Docker and the Compose plugin are already installed — skipping."
    return 0
  fi

  if dry_run; then
    dry_notice "add Docker's official APT repo + GPG key"
    dry_notice "apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive

  # Configure Docker's official APT repository (idempotent).
  local keyring="/etc/apt/keyrings/docker.gpg"
  as_root install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f "$keyring" ]]; then
    info "Adding Docker's official GPG key…"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | as_root gpg --dearmor -o "$keyring"
    as_root chmod a+r "$keyring"
  fi

  local codename arch repo_line
  # shellcheck disable=SC1091
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  arch="$(dpkg --print-architecture)"
  repo_line="deb [arch=${arch} signed-by=${keyring} https://download.docker.com/linux/ubuntu ${codename} stable"
  echo "$repo_line" | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null

  as_root apt-get update -y
  as_root apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  as_root systemctl enable --now docker
  success "Docker Engine and Compose plugin installed."
}

# ---------------------------------------------------------------------------
# 5. Add the current user to the docker group
# ---------------------------------------------------------------------------
configure_docker_group() {
  step "Configuring docker group membership"
  if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    success "User '$USER' is already in the docker group."
  elif dry_run; then
    dry_notice "usermod -aG docker $USER"
  else
    as_root usermod -aG docker "$USER"
    warn "Added '$USER' to the docker group. Log out/in (or run 'newgrp docker') for it to take effect in new shells."
  fi
}

# ---------------------------------------------------------------------------
# 6. Create /opt/cicd with correct permissions
# ---------------------------------------------------------------------------
create_cicd_dir() {
  step "Creating ${CICD_DIR}"
  if dry_run; then dry_notice "install -d -o $USER -g $USER -m 0755 $CICD_DIR"; return 0; fi
  # `install -d` creates the directory with owner/group/mode in one atomic step.
  as_root install -d -o "$USER" -g "$USER" -m 0755 "$CICD_DIR"
  success "${CICD_DIR} ready (owned by $USER)."
}

# ---------------------------------------------------------------------------
# 7. Download the latest GitHub Actions runner
# ---------------------------------------------------------------------------
download_runner() {
  step "Downloading the latest GitHub Actions runner"

  # In dry-run we short-circuit before touching the network/jq, so this works
  # even on a fresh host where the base packages (jq) aren't installed yet.
  if dry_run; then
    dry_notice "query ${GITHUB_API}/repos/${RUNNER_REPO}/releases/latest for the newest version"
    dry_notice "download + extract the linux-$(runner_arch) runner into ${RUNNER_DIR}"
    return 0
  fi

  # Resolve the latest release tag from the GitHub API (never hardcoded).
  local latest_tag version arch tarball url
  latest_tag="$(curl -fsSL "${GITHUB_API}/repos/${RUNNER_REPO}/releases/latest" \
    | jq -r '.tag_name')"
  [[ -n "$latest_tag" && "$latest_tag" != "null" ]] \
    || die "Could not determine the latest runner version from the GitHub API."

  version="${latest_tag#v}"   # strip leading 'v' (v2.320.0 -> 2.320.0)
  arch="$(runner_arch)"
  tarball="actions-runner-linux-${arch}-${version}.tar.gz"
  url="https://github.com/${RUNNER_REPO}/releases/download/${latest_tag}/${tarball}"

  info "Latest runner version: ${C_BOLD}${latest_tag}${C_RESET} (${arch})"

  mkdir -p "$RUNNER_DIR"

  # Skip re-download/extract if this version is already installed.
  if [[ -x "${RUNNER_DIR}/config.sh" && -f "${RUNNER_DIR}/.runner-version" ]] \
     && [[ "$(cat "${RUNNER_DIR}/.runner-version")" == "$version" ]]; then
    success "Runner ${version} already downloaded — skipping."
    return 0
  fi

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  info "Fetching ${tarball}…"
  curl -fsSL -o "${tmp}/${tarball}" "$url"

  info "Extracting into ${RUNNER_DIR}…"
  tar -xzf "${tmp}/${tarball}" -C "$RUNNER_DIR"
  echo "$version" > "${RUNNER_DIR}/.runner-version"

  # Install any OS dependencies the runner needs.
  if [[ -x "${RUNNER_DIR}/bin/installdependencies.sh" ]]; then
    info "Installing runner dependencies…"
    ( cd "$RUNNER_DIR" && as_root ./bin/installdependencies.sh )
  fi

  success "Runner ${version} downloaded and extracted."
}

# ---------------------------------------------------------------------------
# 8 & 9. Request a short-lived registration token via the GitHub REST API
# ---------------------------------------------------------------------------
# Writes the token to the caller-provided variable name. The PAT is used only
# here and is never echoed or written to disk.
fetch_registration_token() {
  step "Requesting a runner registration token"

  if dry_run; then
    dry_notice "POST ${GITHUB_API}/repos/${OWNER}/${REPO}/actions/runners/registration-token (PAT used here only)"
    REG_TOKEN="DRY_RUN_TOKEN"
    return 0
  fi

  local response http_code body
  response="$(curl -fsS -w $'\n%{http_code}' -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API}/repos/${OWNER}/${REPO}/actions/runners/registration-token" \
    2>/dev/null)" || die "Failed to reach the GitHub API. Check network/PAT/permissions."

  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ "$http_code" != "201" ]]; then
    # Surface GitHub's message but never the PAT.
    local msg
    msg="$(echo "$body" | jq -r '.message // "unknown error"' 2>/dev/null || echo "unknown error")"
    die "GitHub API returned HTTP ${http_code}: ${msg}"
  fi

  REG_TOKEN="$(echo "$body" | jq -r '.token')"
  [[ -n "$REG_TOKEN" && "$REG_TOKEN" != "null" ]] \
    || die "Registration token missing from GitHub API response."

  success "Registration token obtained (valid for ~1 hour)."
}

# ---------------------------------------------------------------------------
# 10 & 11 & 12. Register the runner and install it as a systemd service
# ---------------------------------------------------------------------------
register_runner() {
  step "Registering the runner and installing the service"

  local repo_url="https://github.com/${OWNER}/${REPO}"
  local labels="self-hosted,linux,docker"
  [[ -n "$EXTRA_LABELS" ]] && labels="${labels},${EXTRA_LABELS}"

  if dry_run; then
    dry_notice "config.sh --unattended --url ${repo_url} --name ${RUNNER_NAME} --labels ${labels} --work ${WORK_DIR}"
    dry_notice "svc.sh install ${USER} && svc.sh start"
    return 0
  fi

  cd "$RUNNER_DIR"

  # If a service for this runner is already installed and active, do nothing.
  # Use systemctl (authoritative) rather than svc.sh, which needs a configured
  # runner and returns non-zero before install.
  if [[ -f "${RUNNER_DIR}/.runner" ]] && runner_service_active; then
    success "Runner already registered and service active — skipping registration."
    return 0
  fi

  # Clean up a stale/partial registration so config can proceed idempotently.
  if [[ -f "${RUNNER_DIR}/.runner" ]]; then
    warn "Found an existing runner configuration — removing it before re-registering."
    as_root ./svc.sh uninstall >/dev/null 2>&1 || true
    ./config.sh remove --token "$REG_TOKEN" >/dev/null 2>&1 || true
  fi

  info "Configuring runner '${RUNNER_NAME}' for ${repo_url}…"
  ./config.sh \
    --unattended \
    --url "$repo_url" \
    --token "$REG_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$labels" \
    --work "$WORK_DIR" \
    --replace

  info "Installing the systemd service…"
  as_root ./svc.sh install "$USER"

  info "Enabling and starting the service…"
  as_root ./svc.sh start

  success "Runner registered and service started."
}

# ---------------------------------------------------------------------------
# 13. Validation
# ---------------------------------------------------------------------------
validate() {
  step "Validating installation"
  if dry_run; then dry_notice "would verify docker, docker compose, and the runner service"; return 0; fi
  local ok=true

  if docker --version >/dev/null 2>&1; then
    success "Docker: $(docker --version)"
  else
    error "Docker validation failed."; ok=false
  fi

  if docker compose version >/dev/null 2>&1; then
    success "Docker Compose: $(docker compose version --short 2>/dev/null || docker compose version)"
  else
    error "Docker Compose validation failed."; ok=false
  fi

  # Confirm the runner service is active (note: `docker --version`/`compose
  # version` above intentionally avoid `docker ps`, which would need the new
  # docker group membership that isn't active in this shell yet).
  local svc
  svc="$(runner_service_name)"
  if [[ -n "$svc" ]] && systemctl is-active --quiet "$svc"; then
    success "Runner service '${svc}' is active."
  else
    error "Runner service is not active."; ok=false
  fi

  $ok || die "One or more validation checks failed. Review the output above."
  success "All validation checks passed."
}

# ---------------------------------------------------------------------------
# 14. Summary
# ---------------------------------------------------------------------------
print_summary() {
  local svc
  svc="$(runner_service_name)"

  printf '\n%s%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf   '%s%s║                 BOOTSTRAP COMPLETE ✔                     ║%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf   '%s%s╚══════════════════════════════════════════════════════════╝%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"

  cat <<EOF

  ${C_BOLD}Host${C_RESET}            : $(hostname -f 2>/dev/null || hostname)
  ${C_BOLD}Repository${C_RESET}      : ${OWNER}/${REPO}
  ${C_BOLD}Runner name${C_RESET}     : ${RUNNER_NAME}
  ${C_BOLD}Runner dir${C_RESET}      : ${RUNNER_DIR}
  ${C_BOLD}CICD dir${C_RESET}        : ${CICD_DIR}
  ${C_BOLD}Runner service${C_RESET}  : ${svc:-unknown}
  ${C_BOLD}Docker${C_RESET}          : $(docker --version 2>/dev/null || echo 'n/a')
  ${C_BOLD}Compose${C_RESET}         : $(docker compose version --short 2>/dev/null || echo 'n/a')

  ${C_BOLD}Useful commands:${C_RESET}
    sudo ${RUNNER_DIR}/svc.sh status      # runner service status
    journalctl -u ${svc:-<service>} -f    # follow runner logs
    docker ps                             # verify Docker access

EOF

  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker || ! docker ps >/dev/null 2>&1; then
    warn "Log out and back in (or run 'newgrp docker') so your shell picks up docker group membership."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_args

  printf '%s%s\nGitHub Actions Self-Hosted Runner — Bootstrap%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  dry_run && warn "DRY-RUN mode: no changes will be made to the system."

  preflight
  update_system
  install_base_packages
  install_docker
  configure_docker_group
  create_cicd_dir
  download_runner
  fetch_registration_token   # sets REG_TOKEN
  register_runner
  validate
  print_summary

  # Best-effort: drop the token from memory once we're done with it.
  unset PAT REG_TOKEN
}

main "$@"
