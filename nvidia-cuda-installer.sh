#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly NVIDIA_CUDA_INSTALLER_TEST_MODE="${NVIDIA_CUDA_INSTALLER_TEST_MODE:-0}"
readonly NVIDIA_CUDA_INSTALLER_PRODUCTION_PATH="/usr/sbin:/usr/bin:/sbin:/bin"
if [[ "$NVIDIA_CUDA_INSTALLER_TEST_MODE" != "1" ]]; then
  export PATH="$NVIDIA_CUDA_INSTALLER_PRODUCTION_PATH"
fi

test_path_or_default() {
  local env_name="$1"
  local default_value="$2"
  local override_value="${!env_name:-}"

  if [[ -n "$override_value" && "$NVIDIA_CUDA_INSTALLER_TEST_MODE" == "1" ]]; then
    printf '%s\n' "$override_value"
  else
    printf '%s\n' "$default_value"
  fi
}

readonly SCRIPT_NAME="$(basename "$0")"
readonly TARGET_CODENAME="trixie"
readonly TARGET_VERSION_ID="13"
readonly DEFAULT_DRIVER_PACKAGE="cuda-drivers"
readonly HEADER_PACKAGE="linux-headers-$(uname -r)"
readonly NVIDIA_REPO_BASE="https://developer.download.nvidia.com/compute/cuda/repos/debian13"
readonly CUDA_KEYRING_DEB_NAME="cuda-keyring_1.1-1_all.deb"
readonly CUDA_KEYRING_EXPECTED_PACKAGE="cuda-keyring"
readonly CUDA_KEYRING_EXPECTED_VERSION="1.1-1"
readonly NVIDIA_DEBIAN12_REPO_BASE="https://developer.download.nvidia.com/compute/cuda/repos/debian12"
readonly NVIDIA_DEBIAN12_KEY_SHORT="3bf863cc"
readonly NVIDIA_DEBIAN12_KEY_FINGERPRINT="EB693B3035CD5710E231E123A4B469963BF863CC"
readonly NVIDIA_KEYRING_PATH="/usr/share/keyrings/cuda-archive-keyring.gpg"
readonly DEPRECATED_DEBIAN12_580_FALLBACK_SOURCE_FILE="/etc/apt/sources.list.d/cuda-debian12-x86_64-nvidia-580-fallback.list"
readonly VENDOR_580_REPO_DIR="$(test_path_or_default NVIDIA_CUDA_INSTALLER_VENDOR_580_REPO_DIR /opt/nvidia-driver-580-local-repo)"
readonly VENDOR_580_WORK_DIR="$(test_path_or_default NVIDIA_CUDA_INSTALLER_VENDOR_580_WORK_DIR /var/lib/nvidia-driver-580-vendor)"
readonly VENDOR_580_SOURCE_FILE="$(test_path_or_default NVIDIA_CUDA_INSTALLER_VENDOR_580_SOURCE_FILE /etc/apt/sources.list.d/nvidia-driver-580-local-vendor.list)"
readonly VENDOR_580_PREF_FILE="$(test_path_or_default NVIDIA_CUDA_INSTALLER_VENDOR_580_PREF_FILE /etc/apt/preferences.d/nvidia-driver-580-local-vendor.pref)"
readonly VENDOR_580_KEYRING_PATH="$(test_path_or_default NVIDIA_CUDA_INSTALLER_VENDOR_580_KEYRING_PATH /usr/share/keyrings/nvidia-driver-580-local-vendor.gpg)"
readonly VENDOR_580_GNUPG_HOME="$(test_path_or_default NVIDIA_CUDA_INSTALLER_VENDOR_580_GNUPG_HOME "${VENDOR_580_WORK_DIR}/gnupg")"
readonly VENDOR_580_SIGNING_UID="Local NVIDIA Driver 580 Vendor Repo <root@localhost>"
readonly VENDOR_580_REPO_ORIGIN="Local-NVIDIA-Driver-580"
readonly VENDOR_580_REPO_LABEL="Local NVIDIA Driver 580 Vendor Repo"
readonly VENDOR_580_MANAGED_SENTINEL="# Managed by nvidia-cuda-installer: branch-580-vendor"

readonly LAPTOP_POWER_UDEV_RULE_PATH="$(test_path_or_default NVIDIA_CUDA_INSTALLER_LAPTOP_POWER_UDEV_RULE_PATH /etc/udev/rules.d/80-nvidia-runtime-pm-managed-by-nvidia-cuda-installer.rules)"
readonly LAPTOP_RUNTIME_PM_MODPROBE_PATH="$(test_path_or_default NVIDIA_CUDA_INSTALLER_LAPTOP_RUNTIME_PM_MODPROBE_PATH /etc/modprobe.d/nvidia-runtime-pm-managed-by-nvidia-cuda-installer.conf)"
readonly NVIDIA_SUSPEND_MODPROBE_PATH="$(test_path_or_default NVIDIA_CUDA_INSTALLER_NVIDIA_SUSPEND_MODPROBE_PATH /etc/modprobe.d/nvidia-suspend-managed-by-nvidia-cuda-installer.conf)"
readonly PRIME_RUN_PATH="$(test_path_or_default NVIDIA_CUDA_INSTALLER_PRIME_RUN_PATH /usr/local/bin/prime-run)"
readonly SCRIPT_STATE_DIR="$(test_path_or_default NVIDIA_CUDA_INSTALLER_STATE_DIR /var/lib/nvidia-cuda-installer)"
readonly MODPROBE_POLICY_DIR="$(test_path_or_default NVIDIA_CUDA_INSTALLER_MODPROBE_DIR /etc/modprobe.d)"
readonly UDEV_RULES_DIR="$(test_path_or_default NVIDIA_CUDA_INSTALLER_UDEV_RULES_DIR /etc/udev/rules.d)"
readonly INSTALLER_LOCK_FILE_OVERRIDE="$(test_path_or_default NVIDIA_CUDA_INSTALLER_LOCK_FILE '')"
readonly NVIDIA_PERSISTENCED_MASK_MARKER="$SCRIPT_STATE_DIR/nvidia-persistenced.masked-by-laptop-power"
readonly VENDOR_580_MANAGED_SENTINEL_FILE="$VENDOR_580_WORK_DIR/managed-by-nvidia-cuda-installer"
readonly MANAGED_SENTINEL="# Managed by nvidia-cuda-installer: laptop-power"
readonly LAPTOP_POWER_UDEV_SENTINEL="$MANAGED_SENTINEL runtime-pm-udev"
readonly LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL="$MANAGED_SENTINEL runtime-d3-modprobe"
readonly NVIDIA_SUSPEND_MODPROBE_SENTINEL="$MANAGED_SENTINEL suspend-modprobe"
readonly PRIME_RUN_SENTINEL="$MANAGED_SENTINEL prime-run"

ASSUME_YES=0
RESET=0
REMOVE_ONLY=0
CHECK_ONLY=0
SKIP_APT_UPDATE=0
ALLOW_UNKNOWN_GPU=0
ALLOW_LEGACY_470=0
ALLOW_UNVERIFIED_REPO=0
ALLOW_DEBIAN12_580_FALLBACK=0
NO_AUTO_DEBIAN12_580_FALLBACK=0
ACCEPT_CROSS_RELEASE_DRIVER_PACKAGES=0
DEBIAN12_580_FALLBACK_ACTIVE=0
IGNORE_RESET_BLOCKERS=0
YOLO=0
PURGE_CUDA_TOOLKIT=0
DRY_RUN=0
LAPTOP_POWER_MODE=""
KEEP_NVIDIA_PERSISTENCED=0
LAPTOP_POWER_AGGRESSIVE=0
ENABLE_NVIDIA_SUSPEND_SERVICES=0
CHECK_LAPTOP_POWER_IDLE=0
DRY_RUN_WOULD_BOOTSTRAP_NVIDIA_REPO=0
NVIDIA_REPO_CHANGED=0
FORCE_BRANCH=0
DRIVER_BRANCH="auto"

GPU_LINES=()
GPU_FAMILIES=()
GPU_PCI_IDS=()
GPU_CLASSIFICATION_METHODS=()
NVIDIA_SMI_OUT=""
NVIDIA_SMI_ERR=""
MODINFO_OUT=""
MODINFO_ERR=""

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

die_block() {
  local title="$1"
  local details="$2"
  printf '[%s] ERROR: %s\n%s\n' "$SCRIPT_NAME" "$title" "$details" >&2
  exit 1
}

on_error() {
  local status=$?
  local line=${BASH_LINENO[0]:-unknown}
  local cmd=${BASH_COMMAND:-unknown}
  warn "Command failed at line $line with status $status: $cmd"
  exit "$status"
}
trap on_error ERR

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [options]

Install NVIDIA proprietary CUDA driver packages from the NVIDIA APT repo on Debian Trixie.

Default behavior:
  - Detect NVIDIA GPU generation with lspci using a device-ID table plus name/chip-prefix heuristics.
  - Pick a driver branch policy.
  - Install a fresh driver only when no existing NVIDIA driver install is detected.
  - If an existing driver install is detected, make no changes unless --reset is passed.
  - If only the desired branch-pinning package is present from a prior partial run,
    continue installing the driver.

Important behavior:
  - Normal install mode is convergent: rerunning after a completed install makes no driver changes.
  - --reset is a repeatable rebuild action, not an idempotent no-op. It purges and reinstalls each time.
  - --remove-only still requires Debian 13/Trixie, but does not require GPU detection or NVIDIA repo access.
  - NVIDIA repo trust is required by default. If the NVIDIA CUDA repo is missing,
    the script idempotently installs NVIDIA's cuda-keyring package to configure
    both the repo source and its signing key before apt-get update. Before
    installing that package, the script verifies its package metadata, embedded
    repo source, and embedded CUDA archive keyring file, but it does not pin a
    brittle Debian 13 key fingerprint. The script also accepts an already
    configured active repo source with signed-by pointing at a readable keyring.
    The authoritative repository signature validation is apt-get update.

Options:
  -y, --yes
                            Non-interactive; pass -y to APT and answer yes to script prompts.

      --reset
                            Purge detected NVIDIA driver packages and runfile-driver traces,
                            then install a fresh driver. Fails by default when active GPU users
                            or key display/NVIDIA services are detected.

      --remove-only
                            Purge detected NVIDIA driver packages and runfile-driver traces,
                            then exit. This mode does not require GPU detection or NVIDIA repo access,
                            but still requires Debian 13/Trixie.

      --check
                            Run Debian 13/Trixie post-reboot validation checks and exit.
                            Treats cuda-drivers as an installation provenance signal; a demonstrably
                            working NVIDIA driver can pass required validation without that metapackage.
                            Does not install or purge.

      --driver-branch auto|current|580|470
                            Driver branch policy.
                            auto:
                              Maxwell/Pascal/Volta -> 580
                              Turing/Ampere/Ada/Hopper/Blackwell -> current
                              Kepler -> refuse unless --allow-legacy-470
                              Mixed legacy/current generations -> refuse unless explicit branch is used
                            current:
                              No branch pinning package.
                            580:
                              Install an available 580 branch-pinning package before cuda-drivers.
                              Prefers nvidia-driver-pinning-580, then the newest matching
                              nvidia-driver-pinning-580.* or nvidia-driver-pinning-580-* package.
                            470:
                              Install an available 470 branch-pinning package before cuda-drivers.
                              Requires --allow-legacy-470.

      --force-branch
                            Bypass GPU-family compatibility guardrails for an explicit branch.
                            Does not bypass unknown GPU detection unless --allow-unknown-gpu is set.

      --allow-unknown-gpu
                            Continue when GPU generation cannot be inferred.
                            With auto branch, unknown GPUs select current.

      --allow-legacy-470
                            Permit Kepler / R470 branch selection.
                            This may not build or operate correctly on Debian 13 kernels.

      --allow-unverified-repo
                            Continue even when the NVIDIA repo is present but cuda-keyring and
                            signed-by keyring verification are not detected. Not recommended.

      --allow-debian12-580-fallback
                            Break-glass fallback for Debian 13 amd64 hosts that require branch 580
                            when NVIDIA's Debian 13 repo does not expose branch 580. This downloads
                            NVIDIA Debian 12 branch-580 .deb files, authenticates upstream repo
                            metadata, verifies package hashes, and vendors the packages into a local
                            signed APT repository. Requires --accept-cross-release-driver-packages
                            when explicitly requested. In auto branch mode, Maxwell/Pascal/Volta-only
                            hosts use this managed fallback automatically when Debian 13 lacks branch 580,
                            unless --no-auto-debian12-580-fallback is passed.

      --no-auto-debian12-580-fallback
                            Disable the automatic managed Debian 12 branch-580 vendor fallback for
                            Maxwell/Pascal/Volta-only hosts in auto branch mode. If Debian 13 lacks
                            branch 580, the script fails with guidance instead.

      --accept-cross-release-driver-packages
                            Acknowledge that the Debian 12 branch-580 fallback installs cross-release
                            driver packages on Debian 13. This path is an experimental compatibility
                            exception for Maxwell/Pascal/Volta branch-580 hosts, not a general path.

      --ignore-reset-blockers
                            Continue reset/purge even when active GPU users or key services are detected.
                            Use only inside a maintenance window.

      --yolo
                            Break-glass shorthand for:
                              --reset -y --allow-debian12-580-fallback
                              --accept-cross-release-driver-packages --ignore-reset-blockers
                            This is destructive and uses the cross-release branch-580 fallback when needed.

      --purge-cuda-toolkit
                            Also purge CUDA Toolkit APT packages during --reset or --remove-only.
                            Driver cleanup does not purge toolkit packages by default.

      --skip-apt-update
                            Do not run apt-get update.

      --dry-run
                            Print and simulate APT actions without changing the system.
                            Non-APT actions are logged but not executed.

      --laptop-power=auto|ask|on|off
                            Configure CUDA-friendly laptop idle power policy for hybrid graphics systems.
                            Default is ask on an interactive TTY and off otherwise. auto/ask only
                            applies unattended when portable hybrid detection is confident.

      --keep-nvidia-persistenced
                            When laptop power policy applies, leave nvidia-persistenced untouched.
                            By default, laptop-first idle behavior disables and stops it.

      --laptop-power-aggressive
                            Permit extra laptop power actions, currently masking nvidia-persistenced.service
                            after disabling it. The script records ownership only when it creates the mask;
                            preexisting administrator masks are left unowned and are never unmasked by reset.

      --enable-nvidia-suspend-services
                            Configure NVIDIA suspend/hibernate support and VRAM preservation. This is
                            separate from idle power behavior and is not an idle-cooling feature.

      --check-laptop-power-idle
                            Run --check plus an explicit 60-second read-only idle probe. The probe avoids
                            nvidia-smi during the wait and reports runtime PM progress from sysfs only.

  -h, --help
                            Show this help.
USAGE
}

confirm() {
  local prompt="$1"

  if (( ASSUME_YES )); then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    return 1
  fi

  local reply
  while true; do
    read -r -p "$prompt [y/N]: " reply || return 1
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]|'') return 1 ;;
      *) printf 'Please answer y or n.\n' ;;
    esac
  done
}

require_root() {
  if (( CHECK_ONLY )); then
    return 0
  fi

  if (( DRY_RUN )); then
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
      warn "Dry-run mode is running without root. Some package simulations may be incomplete."
    fi
    return 0
  fi

  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Run this script as root, for example with sudo."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

test_path_override_variables() {
  cat <<'EOF'
NVIDIA_CUDA_INSTALLER_LAPTOP_POWER_UDEV_RULE_PATH
NVIDIA_CUDA_INSTALLER_LAPTOP_RUNTIME_PM_MODPROBE_PATH
NVIDIA_CUDA_INSTALLER_NVIDIA_SUSPEND_MODPROBE_PATH
NVIDIA_CUDA_INSTALLER_PRIME_RUN_PATH
NVIDIA_CUDA_INSTALLER_STATE_DIR
NVIDIA_CUDA_INSTALLER_MODPROBE_DIR
NVIDIA_CUDA_INSTALLER_UDEV_RULES_DIR
NVIDIA_CUDA_INSTALLER_LOCK_FILE
NVIDIA_CUDA_INSTALLER_VENDOR_580_REPO_DIR
NVIDIA_CUDA_INSTALLER_VENDOR_580_WORK_DIR
NVIDIA_CUDA_INSTALLER_VENDOR_580_SOURCE_FILE
NVIDIA_CUDA_INSTALLER_VENDOR_580_PREF_FILE
NVIDIA_CUDA_INSTALLER_VENDOR_580_KEYRING_PATH
NVIDIA_CUDA_INSTALLER_VENDOR_580_GNUPG_HOME
EOF
}

validate_test_path_override_gate() {
  local name polluted=0

  [[ "$NVIDIA_CUDA_INSTALLER_TEST_MODE" == "1" ]] && return 0

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -n "${!name:-}" ]]; then
      warn "Ignoring test-only path override in production environment: $name"
      polluted=1
    fi
  done < <(test_path_override_variables)

  if (( polluted )); then
    die "Refusing to continue with test-only path override environment variables set. Unset them before production use; tests must set NVIDIA_CUDA_INSTALLER_TEST_MODE=1."
  fi
}

installer_lock_file() {
  local lock_dir

  if [[ -n "$INSTALLER_LOCK_FILE_OVERRIDE" ]]; then
    printf '%s\n' "$INSTALLER_LOCK_FILE_OVERRIDE"
    return 0
  fi

  if [[ -d /run/lock && -w /run/lock ]]; then
    lock_dir=/run/lock
  else
    lock_dir=/tmp
  fi

  printf '%s/nvidia-cuda-installer.lock\n' "$lock_dir"
}

acquire_execution_lock() {
  local lock_file lock_dir

  command_exists flock || die "flock is required for the global installer execution lock; install util-linux before running this installer."

  lock_file="$(installer_lock_file)"
  lock_dir="$(dirname "$lock_file")"

  if [[ ! -d "$lock_dir" ]]; then
    if (( DRY_RUN )); then
      log "Dry run: would create lock directory: $lock_dir"
    else
      install -d -m 0755 "$lock_dir"
    fi
  fi

  exec 9>"$lock_file" || die "Could not open installer lock file: $lock_file"
  if ! flock -n 9; then
    die "Another NVIDIA CUDA installer invocation is already running. Lock is held on: $lock_file"
  fi
  log "Acquired installer execution lock: $lock_file"
}

apt_yes_args() {
  if (( ASSUME_YES )); then
    printf '%s\n' -y
  fi
}

run_apt_get() {
  local mode="$1"
  shift

  local -a yes_args=()
  mapfile -t yes_args < <(apt_yes_args)

  case "$mode" in
    install)
      if (( DRY_RUN )); then
        log "Dry run: apt-get -s install -V $*"
        apt-get -s install -V "$@"
      else
        apt-get install -V "${yes_args[@]}" "$@"
      fi
      ;;
    purge)
      if (( DRY_RUN )); then
        log "Dry run: apt-get -s purge --autoremove -V $*"
        apt-get -s purge --autoremove -V "$@"
      else
        apt-get purge --autoremove -V "${yes_args[@]}" "$@"
      fi
      ;;
    autoremove)
      if (( DRY_RUN )); then
        log "Dry run: apt-get -s autoremove --purge"
        apt-get -s autoremove --purge
      else
        apt-get autoremove --purge "${yes_args[@]}"
      fi
      ;;
    *)
      die "Internal error: unknown apt-get mode: $mode"
      ;;
  esac
}

parse_args() {
  while (($#)); do
    case "$1" in
      -y|--yes)
        ASSUME_YES=1
        ;;
      --reset)
        RESET=1
        ;;
      --remove-only)
        REMOVE_ONLY=1
        ;;
      --check)
        CHECK_ONLY=1
        ;;
      --driver-branch)
        shift
        [[ $# -gt 0 ]] || die "--driver-branch requires a value."
        DRIVER_BRANCH="$1"
        ;;
      --driver-branch=*)
        DRIVER_BRANCH="${1#*=}"
        ;;
      --force-branch)
        FORCE_BRANCH=1
        ;;
      --allow-unknown-gpu)
        ALLOW_UNKNOWN_GPU=1
        ;;
      --allow-legacy-470)
        ALLOW_LEGACY_470=1
        ;;
      --allow-unverified-repo)
        ALLOW_UNVERIFIED_REPO=1
        ;;
      --allow-debian12-580-fallback)
        ALLOW_DEBIAN12_580_FALLBACK=1
        ;;
      --no-auto-debian12-580-fallback)
        NO_AUTO_DEBIAN12_580_FALLBACK=1
        ;;
      --accept-cross-release-driver-packages)
        ACCEPT_CROSS_RELEASE_DRIVER_PACKAGES=1
        ;;
      --ignore-reset-blockers)
        IGNORE_RESET_BLOCKERS=1
        ;;
      --yolo)
        YOLO=1
        RESET=1
        ASSUME_YES=1
        ALLOW_DEBIAN12_580_FALLBACK=1
        ACCEPT_CROSS_RELEASE_DRIVER_PACKAGES=1
        IGNORE_RESET_BLOCKERS=1
        ;;
      --purge-cuda-toolkit)
        PURGE_CUDA_TOOLKIT=1
        ;;
      --skip-apt-update)
        SKIP_APT_UPDATE=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --laptop-power)
        shift
        [[ $# -gt 0 ]] || die "--laptop-power requires a value."
        LAPTOP_POWER_MODE="$1"
        ;;
      --laptop-power=*)
        LAPTOP_POWER_MODE="${1#*=}"
        ;;
      --keep-nvidia-persistenced)
        KEEP_NVIDIA_PERSISTENCED=1
        ;;
      --laptop-power-aggressive)
        LAPTOP_POWER_AGGRESSIVE=1
        ;;
      --enable-nvidia-suspend-services)
        ENABLE_NVIDIA_SUSPEND_SERVICES=1
        ;;
      --check-laptop-power-idle)
        CHECK_LAPTOP_POWER_IDLE=1
        CHECK_ONLY=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done

  case "$DRIVER_BRANCH" in
    auto|current|580|470) ;;
    *) die "--driver-branch must be one of: auto, current, 580, 470." ;;
  esac

  if [[ -z "$LAPTOP_POWER_MODE" ]]; then
    if [[ -t 0 && -t 1 ]]; then
      LAPTOP_POWER_MODE="ask"
    else
      LAPTOP_POWER_MODE="off"
    fi
  fi

  case "$LAPTOP_POWER_MODE" in
    auto|ask|on|off) ;;
    *) die "--laptop-power must be one of: auto, ask, on, off." ;;
  esac

  if (( CHECK_LAPTOP_POWER_IDLE )) && (( RESET || REMOVE_ONLY )); then
    die "--check-laptop-power-idle is read-only and cannot be combined with --reset or --remove-only."
  fi

  if (( RESET && REMOVE_ONLY )); then
    die "Use either --reset or --remove-only, not both."
  fi

  if (( CHECK_ONLY )) && (( RESET || REMOVE_ONLY )); then
    die "Use --check by itself; it does not install, reset, or purge."
  fi

  if [[ "$DRIVER_BRANCH" == "470" && "$ALLOW_LEGACY_470" -ne 1 ]]; then
    die "Branch 470 requires --allow-legacy-470."
  fi

  if (( FORCE_BRANCH )) && [[ "$DRIVER_BRANCH" == "auto" ]]; then
    die "--force-branch only applies with an explicit --driver-branch value."
  fi

  if (( ACCEPT_CROSS_RELEASE_DRIVER_PACKAGES && ! ALLOW_DEBIAN12_580_FALLBACK )); then
    die "--accept-cross-release-driver-packages requires --allow-debian12-580-fallback."
  fi
}

parse_os_release() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."

  # shellcheck disable=SC1091
  . /etc/os-release

  local os_id="${ID:-}"
  local version_id="${VERSION_ID:-}"
  local codename="${VERSION_CODENAME:-${DEBIAN_CODENAME:-}}"

  [[ "$os_id" == "debian" ]] || die "This script targets Debian only. Found ID=${os_id:-unknown}."

  if [[ -n "$version_id" && "$version_id" != "$TARGET_VERSION_ID" ]]; then
    die "This script targets Debian $TARGET_VERSION_ID ($TARGET_CODENAME). Found VERSION_ID=$version_id."
  fi

  if [[ -n "$codename" && "$codename" != "$TARGET_CODENAME" ]]; then
    die "This script targets Debian $TARGET_VERSION_ID ($TARGET_CODENAME). Found codename=$codename."
  fi

  if [[ -z "$version_id" && -z "$codename" ]]; then
    die "This script targets Debian $TARGET_VERSION_ID ($TARGET_CODENAME), but /etc/os-release lacks VERSION_ID and codename."
  fi
}

cuda_repo_arch_path() {
  local arch
  arch="$(dpkg --print-architecture)"

  case "$arch" in
    amd64) echo "x86_64" ;;
    arm64) echo "sbsa" ;;
    *) die "Unsupported Debian architecture for this script: $arch." ;;
  esac
}

expected_repo_root() {
  printf '%s/%s' "$NVIDIA_REPO_BASE" "$(cuda_repo_arch_path)"
}

cuda_keyring_url() {
  printf '%s/%s' "$(expected_repo_root)" "$CUDA_KEYRING_DEB_NAME"
}

debian12_fallback_repo_root() {
  printf '%s/x86_64' "$NVIDIA_DEBIAN12_REPO_BASE"
}

cuda_repo_source_file() {
  printf '/etc/apt/sources.list.d/cuda-debian13-%s.list\n' "$(cuda_repo_arch_path)"
}

cuda_keyring_package_installed() {
  dpkg-query -W -f='${Status}\n' cuda-keyring 2>/dev/null | grep -q '^install ok installed$'
}

cuda_keyring_file_usable() {
  local keyring="$1"

  [[ -r "$keyring" && -s "$keyring" ]] || return 1

  # Prefer a parseable OpenPGP keyring when gpg is available, but do not make a
  # pinned fingerprint part of the Debian 13 bootstrap path. NVIDIA's
  # cuda-keyring package is the trust-bootstrap artifact, and apt-get update is
  # the authoritative repository signature validation step.
  if command_exists gpg; then
    gpg --batch --show-keys "$keyring" >/dev/null 2>&1 && return 0
  fi

  return 0
}

trusted_cuda_keyring_present() {
  cuda_keyring_file_usable "$NVIDIA_KEYRING_PATH"
}

keyring_present() {
  cuda_keyring_package_installed && trusted_cuda_keyring_present
}

source_file_candidates() {
  printf '%s\n' /etc/apt/sources.list
  find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print 2>/dev/null || true
}

apt_list_line_is_active_repo() {
  local line="$1"
  local repo_root="$2"

  # This installer needs binary package metadata. A deb-src-only stanza is not
  # sufficient for installing cuda-drivers and must not satisfy repo presence.
  [[ "$line" =~ ^[[:space:]]*deb([[:space:]]|\[) ]] || return 1
  [[ "$line" == *"$repo_root"* ]]
}

apt_list_line_signed_by_paths() {
  local line="$1"
  local signed token

  [[ "$line" == *"signed-by="* ]] || return 0
  signed="${line#*signed-by=}"
  signed="${signed%%]*}"
  signed="${signed%% *}"

  while IFS= read -r token; do
    [[ "$token" == /* ]] && printf '%s\n' "$token"
  done < <(printf '%s\n' "$signed" | tr ',' '\n')
}
apt_list_line_has_trusted_signed_by() {
  local line="$1"
  local keyring

  while IFS= read -r keyring; do
    cuda_keyring_file_usable "$keyring" && return 0
  done < <(apt_list_line_signed_by_paths "$line")

  return 1
}

deb822_block_is_enabled() {
  local block="$1"
  ! grep -Eiq '^[[:space:]]*Enabled:[[:space:]]*no([[:space:]]|$)' <<< "$block"
}

deb822_block_has_deb_type() {
  local block="$1"

  # Be strict when Types is present. If Types is absent in malformed input,
  # do not treat the block as an active source.
  grep -Eiq '^[[:space:]]*Types:[[:space:]]*([^[:space:]]+[[:space:]]+)*deb([[:space:]]|$)' <<< "$block"
}

deb822_block_is_active_repo() {
  local block="$1"
  local repo_root="$2"

  [[ "$block" == *"$repo_root"* ]] || return 1
  deb822_block_is_enabled "$block" || return 1
  deb822_block_has_deb_type "$block" || return 1
}


deb822_block_signed_by_paths() {
  local block="$1"
  local token_line token rest

  while IFS= read -r token_line; do
    [[ "$token_line" =~ ^[[:space:]]*Signed-By: ]] || continue
    rest="${token_line#*:}"
    while IFS= read -r token; do
      [[ "$token" == /* ]] && printf '%s\n' "$token"
    done < <(printf '%s\n' "$rest" | tr '[:space:]' '\n')
  done <<< "$block"
}
deb822_block_has_trusted_signed_by() {
  local block="$1"
  local keyring

  while IFS= read -r keyring; do
    cuda_keyring_file_usable "$keyring" && return 0
  done < <(deb822_block_signed_by_paths "$block")

  return 1
}


repo_present() {
  local repo_root="$1"
  local file line block

  while IFS= read -r file; do
    [[ -r "$file" ]] || continue

    case "$file" in
      *.list|/etc/apt/sources.list)
        while IFS= read -r line || [[ -n "$line" ]]; do
          apt_list_line_is_active_repo "$line" "$repo_root" && return 0
        done < "$file"
        ;;
      *.sources)
        block=""
        while IFS= read -r line || [[ -n "$line" ]]; do
          if [[ -z "$line" ]]; then
            if [[ -n "$block" ]] && deb822_block_is_active_repo "$block" "$repo_root"; then
              return 0
            fi
            block=""
          else
            block+="$line"$'\n'
          fi
        done < "$file"
        if [[ -n "$block" ]] && deb822_block_is_active_repo "$block" "$repo_root"; then
          return 0
        fi
        ;;
    esac
  done < <(source_file_candidates)

  return 1
}

list_source_signed_by_paths() {
  local repo_root="$1"
  local file line block

  while IFS= read -r file; do
    [[ -r "$file" ]] || continue

    case "$file" in
      *.list|/etc/apt/sources.list)
        while IFS= read -r line || [[ -n "$line" ]]; do
          apt_list_line_is_active_repo "$line" "$repo_root" || continue
          apt_list_line_signed_by_paths "$line"
        done < "$file"
        ;;
      *.sources)
        block=""
        while IFS= read -r line || [[ -n "$line" ]]; do
          if [[ -z "$line" ]]; then
            if [[ -n "$block" ]] && deb822_block_is_active_repo "$block" "$repo_root"; then
              deb822_block_signed_by_paths "$block"
            fi
            block=""
          else
            block+="$line"$'
'
          fi
        done < "$file"

        if [[ -n "$block" ]] && deb822_block_is_active_repo "$block" "$repo_root"; then
          deb822_block_signed_by_paths "$block"
        fi
        ;;
    esac
  done < <(source_file_candidates)
}

repo_has_untrusted_active_sources() {
  local repo_root="$1"
  local file line block

  while IFS= read -r file; do
    [[ -r "$file" ]] || continue

    case "$file" in
      *.list|/etc/apt/sources.list)
        while IFS= read -r line || [[ -n "$line" ]]; do
          apt_list_line_is_active_repo "$line" "$repo_root" || continue
          apt_list_line_has_trusted_signed_by "$line" || return 0
        done < "$file"
        ;;
      *.sources)
        block=""
        while IFS= read -r line || [[ -n "$line" ]]; do
          if [[ -z "$line" ]]; then
            if [[ -n "$block" ]] && deb822_block_is_active_repo "$block" "$repo_root"; then
              deb822_block_has_trusted_signed_by "$block" || return 0
            fi
            block=""
          else
            block+="$line"$'
'
          fi
        done < "$file"

        if [[ -n "$block" ]] && deb822_block_is_active_repo "$block" "$repo_root"; then
          deb822_block_has_trusted_signed_by "$block" || return 0
        fi
        ;;
    esac
  done < <(source_file_candidates)

  return 1
}

repo_active_sources_are_trusted() {
  local repo_root="$1"

  repo_present "$repo_root" || return 1
  repo_has_trusted_signed_by_keyring "$repo_root" || return 1
  ! repo_has_untrusted_active_sources "$repo_root"
}

repo_has_trusted_signed_by_keyring() {
  local repo_root="$1"
  local keyring

  while IFS= read -r keyring; do
    cuda_keyring_file_usable "$keyring" && return 0
  done < <(list_source_signed_by_paths "$repo_root" | sort -u)

  return 1
}


write_nvidia_cuda_source_from_verified_keyring() {
  local source_file repo_root
  repo_root="$(expected_repo_root)"
  source_file="$(cuda_repo_source_file)"

  trusted_cuda_keyring_present || return 1

  if (( DRY_RUN )); then
    DRY_RUN_WOULD_BOOTSTRAP_NVIDIA_REPO=1
    NVIDIA_REPO_CHANGED=1
    log "Dry run: would write NVIDIA CUDA APT source $source_file using existing verified keyring $NVIDIA_KEYRING_PATH"
    return 0
  fi

  cat > "$source_file" <<EOF
# Added by $SCRIPT_NAME.
deb [signed-by=$NVIDIA_KEYRING_PATH] $repo_root /
EOF
  NVIDIA_REPO_CHANGED=1
  log "Configured NVIDIA CUDA APT repo source: $source_file"
}

ensure_cuda_keyring_fetch_prereqs() {
  local -a packages=()

  if ! command_exists curl && ! command_exists wget; then
    packages+=(curl)
  fi

  if [[ ! -e /etc/ssl/certs/ca-certificates.crt ]]; then
    packages+=(ca-certificates)
  fi

  command_exists gpg || packages+=(gnupg)
  command_exists dpkg-deb || packages+=(dpkg)
  command_exists tar || packages+=(tar)
  command_exists mktemp || packages+=(coreutils)

  if (( ${#packages[@]} == 0 )); then
    return 0
  fi

  log "Installing prerequisites needed to fetch and verify NVIDIA cuda-keyring: ${packages[*]}"
  if (( ! SKIP_APT_UPDATE && ! DRY_RUN )); then
    log "Refreshing Debian APT metadata before installing fetch prerequisites..."
    apt-get update
  elif (( SKIP_APT_UPDATE )); then
    warn "--skip-apt-update is set; attempting prerequisite install without refreshing Debian APT metadata."
  fi
  run_apt_get install "${packages[@]}"

  if (( DRY_RUN )); then
    log "Dry run: prerequisite command availability will be checked during a real run, not after simulated package install."
    return 0
  fi

  command_exists gpg || die "gpg is still unavailable after installing prerequisites."
  command_exists dpkg-deb || die "dpkg-deb is still unavailable after installing prerequisites."
  command_exists tar || die "tar is still unavailable after installing prerequisites."
}

extract_deb_member_to_file() {
  local deb="$1"
  local member="$2"
  local destination="$3"

  dpkg-deb --fsys-tarfile "$deb" | tar -xOf - "$member" > "$destination" 2>/dev/null
}

verify_cuda_keyring_deb() {
  local deb="$1"
  local package version arch repo_root source_member tmp_keyring tmp_source
  local found_source=0
  local -a source_members=()

  package="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
  version="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
  arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)"

  if [[ "$package" != "$CUDA_KEYRING_EXPECTED_PACKAGE" ]]; then
    warn "Downloaded cuda-keyring package metadata mismatch: expected Package=$CUDA_KEYRING_EXPECTED_PACKAGE, found ${package:-unknown}."
    return 1
  fi
  if [[ "$version" != "$CUDA_KEYRING_EXPECTED_VERSION" ]]; then
    warn "Downloaded cuda-keyring package metadata mismatch: expected Version=$CUDA_KEYRING_EXPECTED_VERSION, found ${version:-unknown}."
    return 1
  fi
  if [[ "$arch" != "all" ]]; then
    warn "Downloaded cuda-keyring package metadata mismatch: expected Architecture=all, found ${arch:-unknown}."
    return 1
  fi

  tmp_keyring="$(mktemp)" || return 1
  tmp_source="$(mktemp)" || { rm -f "$tmp_keyring"; return 1; }

  if ! extract_deb_member_to_file "$deb" "./usr/share/keyrings/cuda-archive-keyring.gpg" "$tmp_keyring"; then
    warn "Downloaded cuda-keyring package does not contain ./usr/share/keyrings/cuda-archive-keyring.gpg."
    rm -f "$tmp_keyring" "$tmp_source"
    return 1
  fi
  if ! cuda_keyring_file_usable "$tmp_keyring"; then
    warn "Downloaded cuda-keyring package contains an unusable CUDA archive keyring file."
    rm -f "$tmp_keyring" "$tmp_source"
    return 1
  fi

  mapfile -t source_members < <(dpkg-deb --fsys-tarfile "$deb" | tar -tf - 2>/dev/null | grep -E '^\./etc/apt/sources\.list\.d/.*\.list$' || true)
  repo_root="$(expected_repo_root)"
  for source_member in "${source_members[@]}"; do
    if extract_deb_member_to_file "$deb" "$source_member" "$tmp_source" \
      && grep -Eq '^[[:space:]]*deb([[:space:]]|\[)' "$tmp_source" \
      && grep -Fqs "$repo_root" "$tmp_source" \
      && grep -Fqs "signed-by=$NVIDIA_KEYRING_PATH" "$tmp_source"; then
      found_source=1
      break
    fi
  done
  rm -f "$tmp_keyring" "$tmp_source"

  if (( ! found_source )); then
    warn "Downloaded cuda-keyring package does not contain an active signed-by source for $repo_root."
    return 1
  fi

  return 0
}

install_cuda_keyring_package() {
  local url tmp_dir tmp_deb
  url="$(cuda_keyring_url)"

  if (( DRY_RUN )); then
    DRY_RUN_WOULD_BOOTSTRAP_NVIDIA_REPO=1
    NVIDIA_REPO_CHANGED=1
    log "Dry run: would download, verify, and install NVIDIA cuda-keyring from $url"
    return 0
  fi

  ensure_cuda_keyring_fetch_prereqs
  tmp_dir="$(mktemp -d)" || die "Could not create temporary directory for cuda-keyring download."
  tmp_deb="$tmp_dir/$CUDA_KEYRING_DEB_NAME"

  log "Downloading NVIDIA cuda-keyring from $url"
  if ! fetch_url_to_file "$url" "$tmp_deb"; then
    rm -rf "$tmp_dir"
    die "Failed to download NVIDIA cuda-keyring from $url"
  fi
  if ! verify_cuda_keyring_deb "$tmp_deb"; then
    rm -rf "$tmp_dir"
    die "Downloaded NVIDIA cuda-keyring package failed metadata/source/keyring verification."
  fi

  log "Configuring NVIDIA CUDA APT repo by installing verified cuda-keyring package."
  if ! dpkg -i "$tmp_deb"; then
    rm -rf "$tmp_dir"
    die "dpkg failed while installing verified NVIDIA cuda-keyring package."
  fi
  rm -rf "$tmp_dir"
  NVIDIA_REPO_CHANGED=1

  if ! trusted_cuda_keyring_present; then
    die "Installed cuda-keyring, but $NVIDIA_KEYRING_PATH is missing or unusable."
  fi
}

ensure_nvidia_cuda_repo_configured() {
  local repo_root
  repo_root="$(expected_repo_root)"

  if repo_present "$repo_root"; then
    if repo_active_sources_are_trusted "$repo_root"; then
      return 0
    fi
    if (( ALLOW_UNVERIFIED_REPO )); then
      warn "NVIDIA CUDA APT repo is present but one or more active repo sources are not bound to a readable signed-by keyring. --allow-unverified-repo was passed, so the script will not auto-repair trust."
      return 0
    fi
    warn "NVIDIA CUDA APT repo is present, but active repo source trust is not anchored with signed-by and a readable keyring. Installing cuda-keyring to repair or recreate the managed source."
    install_cuda_keyring_package
    return 0
  fi

  if trusted_cuda_keyring_present; then
    warn "NVIDIA CUDA APT repo source is not configured, but a verified CUDA keyring already exists. Recreating the repo source idempotently."
    write_nvidia_cuda_source_from_verified_keyring || die "Could not write NVIDIA CUDA source from verified keyring."
  else
    warn "NVIDIA CUDA APT repo is not configured. Expected repo root: $repo_root"
    install_cuda_keyring_package
  fi

  if (( DRY_RUN )); then
    return 0
  fi

  if ! repo_present "$repo_root"; then
    if trusted_cuda_keyring_present; then
      warn "Verified cuda-keyring is installed, but the expected NVIDIA CUDA APT source is still missing. Recreating source explicitly."
      write_nvidia_cuda_source_from_verified_keyring || die "Could not recreate NVIDIA CUDA source from verified keyring."
    fi
  fi

  if ! repo_present "$repo_root"; then
    die "Configured cuda-keyring, but the expected active NVIDIA CUDA APT repo source was still not found: $repo_root"
  fi

  if ! repo_active_sources_are_trusted "$repo_root"; then
    die "Configured NVIDIA CUDA repo, but at least one active binary repo source for $repo_root is not signed-by a readable keyring. Disable or fix the untrusted NVIDIA source stanza, or pass --allow-unverified-repo for a deliberate exception."
  fi

  log "NVIDIA CUDA APT repo is configured and trusted."
}

verify_repo_preconditions() {
  local repo_root
  repo_root="$(expected_repo_root)"

  if ! repo_present "$repo_root"; then
    if (( DRY_RUN_WOULD_BOOTSTRAP_NVIDIA_REPO )); then
      log "Dry run: NVIDIA CUDA APT repo would be configured before repository trust checks."
      return 0
    fi
    die "The NVIDIA CUDA APT repo for Debian 13 / $(cuda_repo_arch_path) was not found in active APT sources. Expected repo root: $repo_root"
  fi

  if repo_active_sources_are_trusted "$repo_root"; then
    log "NVIDIA repo trust check passed: every active binary repo source for this repo uses signed-by with a readable keyring; apt-get update will validate repository signatures."
    return 0
  fi

  if (( ALLOW_UNVERIFIED_REPO )); then
    warn "NVIDIA repo trust check failed, but --allow-unverified-repo was passed. Continuing without auto-repair."
    return 0
  fi

  die "NVIDIA repo trust check failed. Install cuda-keyring, or configure the repo with signed-by pointing at a readable keyring file. Pass --allow-unverified-repo only for a deliberate exception."
}

apt_update() {
  if (( SKIP_APT_UPDATE )); then
    if (( NVIDIA_REPO_CHANGED || DRY_RUN_WOULD_BOOTSTRAP_NVIDIA_REPO )); then
      die "--skip-apt-update cannot be used when the NVIDIA CUDA repo was just bootstrapped or repaired. APT metadata must be refreshed before candidate checks."
    fi
    log "Skipping apt-get update by request."
    return 0
  fi

  if (( DRY_RUN )); then
    log "Dry run: would run apt-get update."
    return 0
  fi

  log "Refreshing APT metadata..."
  apt-get update
}

package_candidate_version() {
  local package="$1"
  local policy

  # Avoid `apt-cache policy | awk ... exit` under `set -o pipefail`: when awk exits
  # after reading Candidate:, apt-cache can receive SIGPIPE and produce status 141.
  # Capture the policy output first, then parse it without an early-closing pipe.
  policy="$(apt-cache policy "$package" 2>/dev/null || true)"
  awk '/Candidate:/ { print $2; found=1; exit } END { exit 0 }' <<< "$policy"
}

package_candidate_exists() {
  local package="$1"
  local candidate

  candidate="$(package_candidate_version "$package")"
  [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

require_candidate() {
  local package="$1"
  package_candidate_exists "$package" || die "APT cannot see a candidate for $package. Check repositories and apt update output."
}

preflight_dpkg_state() {
  local audit_output
  audit_output="$(dpkg --audit 2>&1 || true)"
  if [[ -n "$audit_output" ]]; then
    die_block "dpkg reports an inconsistent package state. Resolve this before running driver changes:" "$audit_output"
  fi
}

install_detection_tools() {
  if command_exists lspci; then
    return 0
  fi

  log "Installing pciutils for GPU detection..."
  run_apt_get install pciutils
  command_exists lspci || die "lspci is still unavailable after installing pciutils."
}

nvidia_pci_lines() {
  lspci -Dnn | awk 'tolower($0) ~ /nvidia/ && $0 ~ /\[(0300|0302|0380)\]/ { print }' || true
}

extract_pci_id_pair() {
  local line="$1"
  if [[ "$line" =~ \[([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})\] ]]; then
    printf '%s\n' "${BASH_REMATCH[1],,}"
  else
    printf 'unknown\n'
  fi
}

family_for_device_id() {
  local pci_id="$1"

  # This table intentionally covers common known devices only. Keep it small, auditable,
  # and expand it from observed fleet hardware. Unknown IDs fall back to lspci
  # name/chip-prefix heuristics and should be logged during staged rollout.
  case "$pci_id" in
    10de:1b06|10de:1b80|10de:1b81|10de:1b82|10de:1b83|10de:1b84|10de:1b87|10de:1b30)
      echo "pascal" ;;
    10de:1db4|10de:1db5|10de:1db6|10de:1db7|10de:1db8|10de:1df6)
      echo "volta" ;;
    10de:1e02|10de:1e04|10de:1e07|10de:1e30|10de:1e82|10de:1e84|10de:1eb8)
      echo "turing" ;;
    10de:20b0|10de:20b2|10de:20b5|10de:20b7|10de:2204|10de:2206|10de:2235|10de:2236)
      echo "ampere" ;;
    10de:2684|10de:2704|10de:26b1|10de:26b5|10de:26b9|10de:27b8)
      echo "ada" ;;
    10de:2330|10de:2331|10de:2339|10de:2321)
      echo "hopper" ;;
    *)
      echo "unknown" ;;
  esac
}

family_for_pci_line_heuristic() {
  local line="$1"
  local upper="${line^^}"
  local lower="${line,,}"
  local prefix=""

  if [[ "$upper" =~ (^|[^A-Z0-9])(GK|GM|GP|GV|TU|GA|AD|GH|GB)[0-9][0-9A-Z]* ]]; then
    prefix="${BASH_REMATCH[2]}"
  fi

  case "$prefix" in
    GK) echo "kepler"; return 0 ;;
    GM) echo "maxwell"; return 0 ;;
    GP) echo "pascal"; return 0 ;;
    GV) echo "volta"; return 0 ;;
    TU) echo "turing"; return 0 ;;
    GA) echo "ampere"; return 0 ;;
    AD) echo "ada"; return 0 ;;
    GH) echo "hopper"; return 0 ;;
    GB) echo "blackwell"; return 0 ;;
  esac

  case "$lower" in
    *"tesla k"*|*"quadro k"*|*"grid k"*|*"geforce gtx 6"*|*"geforce gtx 7"*|*"gtx 650"*|*"gtx 660"*|*"gtx 670"*|*"gtx 680"*|*"gtx 690"*|*"gtx 750"*|*"gtx 760"*|*"gtx 770"*|*"gtx 780"*)
      echo "kepler" ;;
    *"tesla m"*|*"quadro m"*|*"geforce gtx 9"*|*"gtx 950"*|*"gtx 960"*|*"gtx 970"*|*"gtx 980"*|*"titan x"*)
      echo "maxwell" ;;
    *"tesla p"*|*"quadro p"*|*"geforce gtx 10"*|*"gtx 1050"*|*"gtx 1060"*|*"gtx 1070"*|*"gtx 1080"*|*"p100"*|*"p4"*|*"p40"*|*"titan xp"*)
      echo "pascal" ;;
    *"tesla v"*|*"quadro gv"*|*"v100"*)
      echo "volta" ;;
    *"quadro rtx"*|*"rtx 20"*|*"geforce gtx 16"*|*"gtx 1630"*|*"gtx 1650"*|*"gtx 1660"*|*"t4"*|*"t400"*|*"t600"*|*"t1000"*)
      echo "turing" ;;
    *"rtx 30"*|*"a100"*|*"a800"*|*"a10"*|*"a16"*|*"a30"*|*"a40"*|*"a2"*|*"a4000"*|*"a4500"*|*"a5000"*|*"a5500"*|*"a6000"*)
      echo "ampere" ;;
    *"rtx 40"*|*"rtx 4000 ada"*|*"rtx 4500 ada"*|*"rtx 5000 ada"*|*"rtx 6000 ada"*|*"l4"*|*"l40"*)
      echo "ada" ;;
    *"h100"*|*"h200"*)
      echo "hopper" ;;
    *"rtx 50"*|*"b100"*|*"b200"*|*"gb200"*)
      echo "blackwell" ;;
    *)
      echo "unknown" ;;
  esac
}

classify_gpu_line() {
  local line="$1"
  local pci_id family

  pci_id="$(extract_pci_id_pair "$line")"
  family="$(family_for_device_id "$pci_id")"

  if [[ "$family" != "unknown" ]]; then
    printf '%s|device-id allowlist|%s\n' "$family" "$pci_id"
    return 0
  fi

  family="$(family_for_pci_line_heuristic "$line")"
  if [[ "$family" != "unknown" ]]; then
    printf '%s|lspci name/chip heuristic|%s\n' "$family" "$pci_id"
    return 0
  fi

  printf 'unknown|unclassified|%s\n' "$pci_id"
}

load_gpu_inventory_from_lines() {
  GPU_LINES=("$@")
  [[ ${#GPU_LINES[@]} -gt 0 ]] || die "No NVIDIA display, 3D, or compute GPU found with lspci."

  GPU_FAMILIES=()
  GPU_PCI_IDS=()
  GPU_CLASSIFICATION_METHODS=()

  local line result family method pci_id
  for line in "${GPU_LINES[@]}"; do
    result="$(classify_gpu_line "$line")"
    family="${result%%|*}"
    result="${result#*|}"
    method="${result%%|*}"
    pci_id="${result#*|}"
    GPU_FAMILIES+=("$family")
    GPU_CLASSIFICATION_METHODS+=("$method")
    GPU_PCI_IDS+=("$pci_id")
  done
}

load_gpu_inventory_from_lspci_text() {
  local text="$1"
  local -a lines=()

  mapfile -t lines < <(gpu_display_lines_from_lspci_text "$text" | awk 'tolower($0) ~ /nvidia/ { print }')
  load_gpu_inventory_from_lines "${lines[@]}"
}

load_gpu_inventory() {
  local -a lines=()

  mapfile -t lines < <(nvidia_pci_lines)
  load_gpu_inventory_from_lines "${lines[@]}"
}

show_gpu_inventory() {
  log "Detected NVIDIA PCI devices using heuristic GPU generation classification:"

  local i
  for (( i = 0; i < ${#GPU_LINES[@]}; i++ )); do
    printf '  - %s\n' "${GPU_LINES[$i]}"
    printf '    pci_id: %s\n' "${GPU_PCI_IDS[$i]}"
    printf '    family: %s\n' "${GPU_FAMILIES[$i]}"
    printf '    classification: %s\n' "${GPU_CLASSIFICATION_METHODS[$i]}"
  done

  warn "GPU generation detection is a policy heuristic based on lspci names, chip prefixes, and a small PCI ID table. Verify unfamiliar hardware before unattended rollout."
}

any_family_seen_in() {
  local family wanted
  for family in "${GPU_FAMILIES[@]}"; do
    for wanted in "$@"; do
      [[ "$family" == "$wanted" ]] && return 0
    done
  done
  return 1
}

all_families_are() {
  local wanted="$1"
  local family
  for family in "${GPU_FAMILIES[@]}"; do
    [[ "$family" == "$wanted" ]] || return 1
  done
  return 0
}

all_families_in() {
  local family wanted matched

  for family in "${GPU_FAMILIES[@]}"; do
    matched=0
    for wanted in "$@"; do
      if [[ "$family" == "$wanted" ]]; then
        matched=1
        break
      fi
    done
    (( matched )) || return 1
  done
  return 0
}

auto_driver_branch() {
  local saw_legacy_580=0
  local saw_current=0
  local saw_unknown=0
  local saw_kepler=0
  local family

  for family in "${GPU_FAMILIES[@]}"; do
    case "$family" in
      kepler) saw_kepler=1 ;;
      maxwell|pascal|volta) saw_legacy_580=1 ;;
      turing|ampere|ada|hopper|blackwell) saw_current=1 ;;
      unknown) saw_unknown=1 ;;
      *) saw_unknown=1 ;;
    esac
  done

  if (( saw_unknown && ! ALLOW_UNKNOWN_GPU )); then
    die "Could not infer one or more NVIDIA GPU generations. Pass --allow-unknown-gpu to use the current branch anyway."
  fi

  if (( saw_kepler )); then
    if (( saw_legacy_580 || saw_current || saw_unknown )); then
      die "Mixed Kepler and non-Kepler GPUs detected. Refusing automatic branch selection. Use an explicit branch only after checking NVIDIA support for every GPU on this host."
    fi

    if (( ALLOW_LEGACY_470 )); then
      echo "470"
      return 0
    fi
    die "Kepler GPUs need the legacy 470 branch, which this script refuses by default on Debian 13. Pass --allow-legacy-470 to try it."
  fi

  if (( saw_legacy_580 && saw_current )); then
    die "Mixed Maxwell/Pascal/Volta and newer NVIDIA GPUs detected. Refusing automatic branch selection. Pass --driver-branch 580 or --driver-branch current with --force-branch after checking support for every GPU on this host."
  fi

  if (( saw_legacy_580 )); then
    echo "580"
    return 0
  fi

  echo "current"
}

selected_driver_branch() {
  if [[ "$DRIVER_BRANCH" == "auto" ]]; then
    auto_driver_branch
  else
    echo "$DRIVER_BRANCH"
  fi
}

validate_branch_for_inventory() {
  local branch="$1"

  if any_family_seen_in unknown && (( ! ALLOW_UNKNOWN_GPU )); then
    die "Could not infer one or more NVIDIA GPU generations. Pass --allow-unknown-gpu to continue."
  fi

  if (( FORCE_BRANCH )); then
    warn "--force-branch is set. Skipping GPU-family compatibility guardrails for branch $branch."
    return 0
  fi

  case "$branch" in
    470)
      if (( ! ALLOW_LEGACY_470 )); then
        die "Branch 470 requires --allow-legacy-470."
      fi
      if ! all_families_are kepler; then
        die "Branch 470 was selected, but not every detected GPU is Kepler. Use --force-branch only after checking NVIDIA support for every GPU on this host."
      fi
      ;;
    580)
      if any_family_seen_in kepler; then
        die "Branch 580 does not cover Kepler in this policy. Use branch 470 for Kepler-only hosts."
      fi
      if any_family_seen_in turing ampere ada hopper blackwell unknown; then
        warn "Branch 580 selected with newer or unknown GPU families present. Verify branch 580 support for every GPU on this host."
      fi
      ;;
    current)
      if any_family_seen_in kepler maxwell pascal volta; then
        die "Current branch selected with Kepler/Maxwell/Pascal/Volta present. Use --force-branch only after checking NVIDIA support for every GPU on this host."
      fi
      ;;
    *)
      die "Unsupported branch policy: $branch"
      ;;
  esac

  return 0
}

available_pinning_packages_for_branch() {
  local branch="$1"
  local prefix="nvidia-driver-pinning-$branch"

  {
    apt-cache pkgnames "$prefix" 2>/dev/null || true
    apt-cache search "^$prefix" 2>/dev/null | awk '{ print $1 }' || true
  } | awk -v prefix="$prefix" '$0 == prefix || index($0, prefix ".") == 1 || index($0, prefix "-") == 1 { print }' | sort -Vu
}

pinning_package_matches_branch() {
  local package="$1"
  local branch="$2"
  local prefix="nvidia-driver-pinning-$branch"

  [[ "$package" == "$prefix" || "$package" == "$prefix."* || "$package" == "$prefix-"* ]]
}

pinning_package_diagnostics() {
  local branch="$1"
  local exact="nvidia-driver-pinning-$branch"

  {
    printf 'APT cannot see a candidate for %s or a versioned fallback.\n' "$exact"
    printf 'Available branch-pinning package names from apt-cache:\n'
    available_pinning_packages_for_branch "$branch" | sed 's/^/  - /'
    printf 'Relevant APT policy:\n'
    apt-cache policy "$exact" 2>/dev/null | sed 's/^/  /' || true
  } >&2
}

pinning_package_for_branch() {
  local branch="$1"
  local exact candidate selected=""
  local -a candidates=()

  case "$branch" in
    current)
      echo ""
      return 0
      ;;
    580|470)
      ;;
    *)
      printf '[%s] ERROR: Unsupported branch policy: %s\n' "$SCRIPT_NAME" "$branch" >&2
      return 1
      ;;
  esac

  exact="nvidia-driver-pinning-$branch"
  if package_candidate_exists "$exact"; then
    echo "$exact"
    return 0
  fi

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ "$candidate" != "$exact" ]] && package_candidate_exists "$candidate"; then
      candidates+=("$candidate")
    fi
  done < <(available_pinning_packages_for_branch "$branch")

  if (( ${#candidates[@]} )); then
    selected="$(printf '%s\n' "${candidates[@]}" | sort -Vu | tail -n 1)"
    warn "Exact package $exact has no candidate; using newest available matching package: $selected"
    echo "$selected"
    return 0
  fi

  return 1
}

require_pinning_package_for_branch() {
  local branch="$1"
  local pinning_package

  if ! pinning_package="$(pinning_package_for_branch "$branch")"; then
    pinning_package_diagnostics "$branch"
    die "No usable NVIDIA driver branch-pinning package is available for branch $branch."
  fi

  printf '%s\n' "$pinning_package"
}

fetch_url_to_file() {
  local url="$1"
  local destination="$2"
  local dest_dir tmp_file base

  case "$url" in
    https://*) ;;
    *)
      warn "Refusing non-HTTPS fetch URL: $url"
      return 1
      ;;
  esac

  dest_dir="$(dirname "$destination")"
  base="$(basename "$destination")"
  [[ -d "$dest_dir" ]] || { warn "Destination directory does not exist: $dest_dir"; return 1; }
  tmp_file="$(mktemp "$dest_dir/.${base}.tmp.XXXXXX")" || return 1

  if command_exists curl; then
    if curl --fail --silent --show-error --location \
      --retry 4 --retry-all-errors --connect-timeout 15 --max-time 300 \
      --proto '=https' --tlsv1.2 -o "$tmp_file" "$url"; then
      mv -f "$tmp_file" "$destination"
      return 0
    fi
    rm -f "$tmp_file"
    return 1
  fi

  if command_exists wget; then
    if wget --https-only --secure-protocol=TLSv1_2 --tries=4 --timeout=30 -qO "$tmp_file" "$url"; then
      mv -f "$tmp_file" "$destination"
      return 0
    fi
    rm -f "$tmp_file"
    return 1
  fi

  rm -f "$tmp_file"
  warn "curl or wget is required to fetch files."
  return 1
}

disable_deprecated_debian12_fallback_source_if_present() {
  local file disabled repo_root
  repo_root="$(debian12_fallback_repo_root)"

  while IFS= read -r file; do
    [[ -r "$file" ]] || continue
    grep -Fqs "$repo_root" "$file" || continue

    if [[ "$file" == "$DEPRECATED_DEBIAN12_580_FALLBACK_SOURCE_FILE" ]]; then
      disabled="${file}.disabled-by-${SCRIPT_NAME}"
      if (( DRY_RUN )); then
        warn "Dry run: would disable deprecated upstream Debian 12 NVIDIA fallback source: $file"
      else
        mv -f "$file" "$disabled"
        warn "Disabled deprecated upstream Debian 12 NVIDIA fallback source before apt-get update: $disabled"
      fi
    else
      die_block "An unmanaged NVIDIA Debian 12 CUDA APT source is configured. Disable it before running this Debian 13 installer; the vendored fallback does not use the upstream Debian 12 repo as an APT source:" "  - $file"
    fi
  done < <(source_file_candidates)
}

managed_vendor_580_source_file_owned() {
  [[ -r "$VENDOR_580_SOURCE_FILE" ]] || return 1
  grep -Fqx "$VENDOR_580_MANAGED_SENTINEL" "$VENDOR_580_SOURCE_FILE" 2>/dev/null && return 0
  grep -Fqs "Local signed vendor repo containing NVIDIA Debian 12 branch-580 driver packages" "$VENDOR_580_SOURCE_FILE" \
    && grep -Fqs "signed-by=$VENDOR_580_KEYRING_PATH" "$VENDOR_580_SOURCE_FILE" \
    && grep -Fqs "file:$VENDOR_580_REPO_DIR" "$VENDOR_580_SOURCE_FILE"
}

clear_existing_vendor_580_source_for_refresh() {
  # The local branch-580 vendor source is managed by this script. Disable any
  # previously managed source before the initial apt-get update so stale or
  # partially removed file: metadata cannot break an otherwise fresh install.
  # If branch 580 is needed later in the run, the source is rebuilt and apt-get
  # update is run again after the local repository metadata is regenerated.
  if [[ ! -e "$VENDOR_580_SOURCE_FILE" ]]; then
    return 0
  fi
  if ! managed_vendor_580_source_file_owned; then
    die "Refusing to remove unmanaged file at managed branch-580 vendor source path: $VENDOR_580_SOURCE_FILE"
  fi
  if (( DRY_RUN )); then
    warn "Dry run: would disable existing managed local branch-580 vendor source before refresh: $VENDOR_580_SOURCE_FILE"
    return 0
  fi
  rm -f "$VENDOR_580_SOURCE_FILE"
  warn "Disabled existing managed local branch-580 vendor source before refresh: $VENDOR_580_SOURCE_FILE"
}

vendor_580_packages_url() {
  printf '%s/Packages.gz' "$(debian12_fallback_repo_root)"
}

vendor_580_inrelease_url() {
  printf '%s/InRelease' "$(debian12_fallback_repo_root)"
}

vendor_580_pubkey_url() {
  printf '%s/%s.pub' "$(debian12_fallback_repo_root)" "$NVIDIA_DEBIAN12_KEY_SHORT"
}

install_vendor_580_prereqs() {
  local -a missing=()
  local cmd

  for cmd in python3 gpg gpgv dpkg-scanpackages gzip sha256sum sha512sum stat date; do
    command_exists "$cmd" || missing+=("$cmd")
  done

  if ! command_exists curl && ! command_exists wget; then
    missing+=("curl")
  fi

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  log "Installing local vendor-repo prerequisites: ca-certificates curl python3 gnupg dpkg-dev gzip coreutils"
  run_apt_get install ca-certificates curl python3 gnupg dpkg-dev gzip coreutils

  if (( DRY_RUN )); then
    log "Dry run: prerequisite command availability will be checked during a real run, not after simulated package install."
    return 0
  fi

  for cmd in python3 gpg gpgv dpkg-scanpackages gzip sha256sum sha512sum stat date; do
    command_exists "$cmd" || die "Required command is still unavailable after installing prerequisites: $cmd"
  done
}

verify_nvidia_debian12_pubkey() {
  local pubkey="$1"
  local fingerprint

  fingerprint="$(gpg --batch --show-keys --with-colons "$pubkey" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ "$fingerprint" == "$NVIDIA_DEBIAN12_KEY_FINGERPRINT" ]] \
    || die "NVIDIA Debian 12 public key fingerprint mismatch. Expected $NVIDIA_DEBIAN12_KEY_FINGERPRINT, found ${fingerprint:-unknown}. Check whether NVIDIA rotated the CUDA repo key before editing this script."
}

verify_packages_gz_against_release() {
  local release_file="$1"
  local packages_gz="$2"

  python3 - "$release_file" "$packages_gz" <<'VERIFY_PY'
import hashlib
import os
import sys

release_path, packages_path = sys.argv[1:3]
want_hash = None
want_size = None
in_sha256 = False
with open(release_path, encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        if line == "SHA256:":
            in_sha256 = True
            continue
        if in_sha256 and line and not line.startswith(" "):
            in_sha256 = False
        if not in_sha256:
            continue
        parts = line.split()
        if len(parts) != 3:
            continue
        digest, size, name = parts
        if name in {"Packages.gz", "./Packages.gz"}:
            want_hash = digest
            want_size = int(size)
            break
if want_hash is None:
    raise SystemExit("Signed Release metadata does not contain a SHA256 entry for Packages.gz")
actual_size = os.path.getsize(packages_path)
if actual_size != want_size:
    raise SystemExit(f"Packages.gz size mismatch: expected {want_size}, got {actual_size}")
h = hashlib.sha256()
with open(packages_path, "rb") as fh:
    for chunk in iter(lambda: fh.read(1024 * 1024), b""):
        h.update(chunk)
actual_hash = h.hexdigest()
if actual_hash.lower() != want_hash.lower():
    raise SystemExit(f"Packages.gz SHA256 mismatch: expected {want_hash}, got {actual_hash}")
VERIFY_PY
}

verify_nvidia_debian12_inrelease() {
  local tmpdir="$1"
  local pubkey keyring inrelease release_plain packages_gz
  pubkey="$tmpdir/${NVIDIA_DEBIAN12_KEY_SHORT}.pub"
  keyring="$tmpdir/nvidia-debian12-${NVIDIA_DEBIAN12_KEY_SHORT}.gpg"
  inrelease="$tmpdir/InRelease"
  release_plain="$tmpdir/Release.verified"
  packages_gz="$tmpdir/Packages.gz"

  fetch_url_to_file "$(vendor_580_pubkey_url)" "$pubkey"
  verify_nvidia_debian12_pubkey "$pubkey"
  gpg --batch --yes --dearmor -o "$keyring" "$pubkey"
  fetch_url_to_file "$(vendor_580_inrelease_url)" "$inrelease"
  fetch_url_to_file "$(vendor_580_packages_url)" "$packages_gz"

  # Debian 13 APT/sqv currently rejects NVIDIA's Debian 12 repo key because the
  # key binding relies on old SHA1-era certification. This break-glass path pins
  # the expected NVIDIA fingerprint above, then uses gpgv only for this upstream
  # metadata check. The resulting local repo is signed with a fresh local key.
  if ! gpgv --keyring "$keyring" --output "$release_plain" "$inrelease" >/dev/null 2>"$tmpdir/gpgv.err"; then
    warn "gpgv could not verify NVIDIA Debian 12 InRelease with the pinned key. stderr follows:"
    sed 's/^/  /' "$tmpdir/gpgv.err" >&2 || true
    die "Could not authenticate NVIDIA Debian 12 repository metadata for branch-580 vendoring."
  fi

  verify_packages_gz_against_release "$release_plain" "$packages_gz"
  printf '%s\n' "$packages_gz"
}

download_and_verify_debian12_580_packages_index() {
  local index_path="$1"
  local tmpdir packages_gz

  if (( DRY_RUN )); then
    log "Dry run: would authenticate NVIDIA Debian 12 InRelease, verify Packages.gz against signed Release metadata, and unpack the package index."
    return 0
  fi

  tmpdir="$(mktemp -d)"
  packages_gz="$(verify_nvidia_debian12_inrelease "$tmpdir")"
  install -d -m 0755 "$(dirname "$index_path")"
  gzip -cd "$packages_gz" > "$index_path"
  rm -rf "$tmpdir"
}

select_debian12_580_driver_version() {
  local index_path="$1"

  python3 - "$index_path" <<'PY' | sort -V | tail -n 1
import sys

ALLOWED_ARCHES = {"amd64", "all"}

path = sys.argv[1]
records = []
current = {}
last_key = None
with open(path, encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        if not line:
            if current:
                records.append(current)
            current = {}
            last_key = None
            continue
        if line.startswith((" ", "\t")) and last_key:
            current[last_key] += "\n" + line
            continue
        if ":" in line:
            key, value = line.split(":", 1)
            current[key] = value.strip()
            last_key = key
if current:
    records.append(current)

for rec in records:
    name = rec.get("Package", "")
    version = rec.get("Version", "")
    arch = rec.get("Architecture", "")
    if arch not in ALLOWED_ARCHES:
        continue
    if version.startswith("580.") and (name == "cuda-drivers" or name.startswith("nvidia-driver-pinning-580.")):
        print(version)
PY
}

build_vendor_580_manifest() {
  local index_path="$1"
  local selected_version="$2"
  local manifest_path="$3"

  python3 - "$index_path" "$selected_version" "$manifest_path" <<'PY'
import re
import sys
from collections import defaultdict, deque

ALLOWED_ARCHES = {"amd64", "all"}

index_path, selected_version, manifest_path = sys.argv[1:4]
records = []
current = {}
last_key = None
with open(index_path, encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        if not line:
            if current:
                records.append(current)
            current = {}
            last_key = None
            continue
        if line.startswith((" ", "\t")) and last_key:
            current[last_key] += "\n" + line
            continue
        if ":" in line:
            key, value = line.split(":", 1)
            current[key] = value.strip()
            last_key = key
if current:
    records.append(current)
by_name = defaultdict(list)
providers = defaultdict(list)
for rec in records:
    name = rec.get("Package")
    arch = rec.get("Architecture", "")
    if not name:
        continue
    if arch not in ALLOWED_ARCHES:
        continue
    by_name[name].append(rec)
    for provide in rec.get("Provides", "").split(","):
        provide = provide.strip()
        if not provide:
            continue
        provide = re.sub(r"\s*\([^)]*\)", "", provide).strip()
        provide = provide.split(":", 1)[0].strip()
        if provide:
            providers[provide].append(rec)
def version_key(v):
    return [int(x) if x.isdigit() else x for x in re.split(r"([0-9]+)", v)]
def arch_key(rec):
    # Prefer native amd64 over Architecture: all when both satisfy the same name/version.
    return 1 if rec.get("Architecture", "") == "amd64" else 0
def pick_best(candidates):
    return sorted(candidates, key=lambda r: (version_key(r.get("Version", "")), arch_key(r), r.get("Package", "")))[-1]
def pick_record(name):
    candidates = by_name.get(name, []) or providers.get(name, [])
    if not candidates:
        return None
    if name.startswith("nvidia-driver-pinning-580"):
        exact = [r for r in candidates if r.get("Version") == selected_version]
        if exact:
            return pick_best(exact)
        return pick_best(candidates)
    exact = [r for r in candidates if r.get("Version") == selected_version]
    if exact:
        return pick_best(exact)
    return None
def package_name_from_dep(text):
    text = text.strip()
    text = re.sub(r"\s*\([^)]*\)", "", text).strip()
    text = text.split(":", 1)[0].strip()
    return text
def dependency_names(rec):
    names = []
    for field in ("Pre-Depends", "Depends"):
        value = rec.get(field, "")
        if not value:
            continue
        for dep_group in value.split(","):
            for alt in dep_group.split("|"):
                name = package_name_from_dep(alt)
                if name:
                    names.append(name)
                    break
    return names
roots = ["cuda-drivers", "nvidia-driver-pinning-580", "nvidia-driver-pinning-" + selected_version.split("-", 1)[0]]
# Debian's native NVIDIA integration/helper packages are expected to come from
# the Debian 13 archive, not from the NVIDIA Debian 12 CUDA repo. They are
# deliberately omitted from the vendored repo and left for APT's solver.
ALLOWED_EXTERNAL_DEPENDENCIES = {
    "libnvidia-egl-gbm1",
    "libnvidia-egl-wayland1",
    "libnvidia-egl-xcb1",
    "libnvidia-egl-xlib1",
    "nvidia-installer-cleanup",
}
def should_vendor_missing(name):
    prefixes = (
        "cuda-drivers", "cuda-compat", "cuda-mps", "firmware-nvidia-gsp",
        "libcuda1", "libcudadebugger1", "libegl-nvidia0", "libgles-nvidia",
        "libglx-nvidia0", "libnvcuvid1", "libnvidia-", "libnvoptix1",
        "libnvsdm", "libxnvctrl", "nvidia-", "xserver-xorg-video-nvidia",
    )
    return name.startswith(prefixes)
queue = deque(roots)
selected = {}
missing = set()
external = set()
while queue:
    name = queue.popleft()
    if name in selected:
        continue
    rec = pick_record(name)
    if rec is None:
        if name in ALLOWED_EXTERNAL_DEPENDENCIES:
            external.add(name)
        elif should_vendor_missing(name):
            missing.add(name)
        continue
    selected[name] = rec
    for dep in dependency_names(rec):
        if dep not in selected:
            queue.append(dep)
if "cuda-drivers" not in selected:
    raise SystemExit("Could not find cuda-drivers for selected branch-580 version in NVIDIA Debian 12 index")
if missing:
    raise SystemExit(
        "Could not resolve required NVIDIA branch-580 dependencies for amd64/all from authenticated Debian 12 metadata. "
        "These were not in the explicit Debian-external allowlist either:\n  - "
        + "\n  - ".join(sorted(missing))
    )
with open(manifest_path, "w", encoding="utf-8") as out:
    for name in sorted(selected):
        rec = selected[name]
        arch = rec.get("Architecture", "")
        if arch not in ALLOWED_ARCHES:
            raise SystemExit(f"Selected non-amd64 package for {name}: Architecture={arch}")
        for field in ("Version", "Filename", "SHA256", "Size"):
            if not rec.get(field):
                raise SystemExit(f"Record for {name} lacks {field}")
        out.write("\t".join([name, rec["Version"], arch, rec["Filename"], rec["SHA256"], rec["Size"]]) + "\n")
PY
}

download_vendor_580_packages_from_manifest() {
  local manifest_path="$1"
  local repo_dir="$2"
  local repo_root filename rel basename destination package version arch sha256 size
  repo_root="$(debian12_fallback_repo_root)"
  install -d -m 0755 "$repo_dir"
  while IFS=$'\t' read -r package version arch filename sha256 size; do
    [[ -n "$package" ]] || continue
    rel="${filename#./}"
    basename="$(basename "$rel")"
    destination="$repo_dir/$basename"
    if [[ -r "$destination" ]] && printf '%s  %s\n' "$sha256" "$destination" | sha256sum -c - >/dev/null 2>&1; then
      log "Vendored package already present and checksum-valid: $basename"
      continue
    fi
    if (( DRY_RUN )); then
      log "Dry run: would download $repo_root/$rel -> $destination"
      continue
    fi
    log "Downloading NVIDIA branch-580 package: $basename"
    fetch_url_to_file "$repo_root/$rel" "$destination"
    printf '%s  %s\n' "$sha256" "$destination" | sha256sum -c - >/dev/null
  done < "$manifest_path"
}

ensure_vendor_580_signing_key() {
  local tmpkey key_params
  require_vendor_580_path_absent_or_owned "$VENDOR_580_WORK_DIR" "work directory" managed_vendor_580_work_dir_owned
  require_vendor_580_path_absent_or_owned "$VENDOR_580_KEYRING_PATH" "APT keyring" managed_vendor_580_keyring_owned
  if (( DRY_RUN )); then
    log "Dry run: would create/export local vendor repo signing key at $VENDOR_580_KEYRING_PATH"
    return 0
  fi
  install -d -m 0700 "$VENDOR_580_GNUPG_HOME"
  chmod 0700 "$VENDOR_580_GNUPG_HOME"
  if ! gpg --homedir "$VENDOR_580_GNUPG_HOME" --batch --list-keys "$VENDOR_580_SIGNING_UID" >/dev/null 2>&1; then
    key_params="$(mktemp)"
    cat > "$key_params" <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: Local NVIDIA Driver 580 Vendor Repo
Name-Email: root@localhost
Expire-Date: 0
%commit
EOF
    gpg --homedir "$VENDOR_580_GNUPG_HOME" --batch --generate-key "$key_params"
    rm -f "$key_params"
  fi
  tmpkey="$(mktemp)"
  gpg --homedir "$VENDOR_580_GNUPG_HOME" --batch --yes --export "$VENDOR_580_SIGNING_UID" > "$tmpkey"
  install -d -m 0755 "$(dirname "$VENDOR_580_KEYRING_PATH")"
  install -m 0644 "$tmpkey" "$VENDOR_580_KEYRING_PATH"
  rm -f "$tmpkey"
}

file_sha256_line() {
  local file="$1"
  local rel="$2"
  local hash size
  hash="$(sha256sum "$file" | awk '{ print $1 }')"
  size="$(stat -c '%s' "$file")"
  printf ' %s %s %s\n' "$hash" "$size" "$rel"
}

file_sha512_line() {
  local file="$1"
  local rel="$2"
  local hash size
  hash="$(sha512sum "$file" | awk '{ print $1 }')"
  size="$(stat -c '%s' "$file")"
  printf ' %s %s %s\n' "$hash" "$size" "$rel"
}

generate_vendor_580_repo_metadata() {
  local repo_dir="$1"
  local release_file
  if (( DRY_RUN )); then
    log "Dry run: would generate and sign local APT repo metadata under $repo_dir"
    return 0
  fi
  (
    cd "$repo_dir"
    dpkg-scanpackages . /dev/null > Packages
    gzip -9cn Packages > Packages.gz
  )
  release_file="$repo_dir/Release"
  {
    printf 'Origin: %s\n' "$VENDOR_580_REPO_ORIGIN"
    printf 'Label: %s\n' "$VENDOR_580_REPO_LABEL"
    printf 'Suite: stable\n'
    printf 'Codename: nvidia-driver-580-local\n'
    printf 'Date: %s\n' "$(LC_ALL=C date -Ru)"
    printf 'Architectures: amd64\n'
    printf 'Components: .\n'
    printf 'Description: Local vendored NVIDIA branch-580 driver packages for Debian 13 compatibility\n'
    printf 'SHA256:\n'
    file_sha256_line "$repo_dir/Packages" "Packages"
    file_sha256_line "$repo_dir/Packages.gz" "Packages.gz"
    printf 'SHA512:\n'
    file_sha512_line "$repo_dir/Packages" "Packages"
    file_sha512_line "$repo_dir/Packages.gz" "Packages.gz"
  } > "$release_file"
  ensure_vendor_580_signing_key
  gpg --homedir "$VENDOR_580_GNUPG_HOME" --batch --yes --digest-algo SHA512 --clearsign -o "$repo_dir/InRelease" "$release_file"
  gpg --homedir "$VENDOR_580_GNUPG_HOME" --batch --yes --digest-algo SHA512 --detach-sign -o "$repo_dir/Release.gpg" "$release_file"
}

write_vendor_580_source() {
  require_vendor_580_path_absent_or_owned "$VENDOR_580_SOURCE_FILE" "APT source file" managed_vendor_580_source_file_owned
  if (( DRY_RUN )); then
    log "Dry run: would write local vendor APT source $VENDOR_580_SOURCE_FILE"
    return 0
  fi
  cat > "$VENDOR_580_SOURCE_FILE" <<EOF
# Added by $SCRIPT_NAME.
$VENDOR_580_MANAGED_SENTINEL
# Local signed vendor repo containing NVIDIA Debian 12 branch-580 driver packages for Debian 13 compatibility.
deb [arch=amd64 signed-by=$VENDOR_580_KEYRING_PATH] file:$VENDOR_580_REPO_DIR ./
EOF
  log "Configured local NVIDIA branch-580 vendor repo: $VENDOR_580_SOURCE_FILE"
}

write_vendor_580_preferences() {
  local manifest_path="$1"
  local package_list
  require_vendor_580_path_absent_or_owned "$VENDOR_580_PREF_FILE" "APT preferences file" managed_vendor_580_pref_file_owned
  package_list="$(awk -F '\t' '{ print $1 }' "$manifest_path" | sort -u | paste -sd' ' -)"
  [[ -n "$package_list" ]] || die "Internal error: local vendor manifest produced no package list."
  if (( DRY_RUN )); then
    log "Dry run: would write $VENDOR_580_PREF_FILE for vendored packages: $package_list"
    return 0
  fi
  {
    cat <<EOF
# Added by $SCRIPT_NAME.
$VENDOR_580_MANAGED_SENTINEL
# Purpose: block unlisted packages from the local vendor repo and prefer the exact
# package versions captured in the authenticated branch-580 manifest.

Package: *
Pin: release o=$VENDOR_580_REPO_ORIGIN
Pin-Priority: -1

EOF
    awk -F '\t' '
      NF >= 2 {
        printf "Package: %s\n", $1
        printf "Pin: version %s\n", $2
        printf "Pin-Priority: 1001\n\n"
      }
    ' "$manifest_path"
  } > "$VENDOR_580_PREF_FILE"
  log "Wrote local NVIDIA branch-580 vendor APT preferences: $VENDOR_580_PREF_FILE"
}

managed_vendor_580_pref_file_owned() {
  [[ -r "$VENDOR_580_PREF_FILE" ]] || return 1
  grep -Fqx "$VENDOR_580_MANAGED_SENTINEL" "$VENDOR_580_PREF_FILE" 2>/dev/null && return 0
  grep -Fqs "package versions captured in the authenticated branch-580 manifest" "$VENDOR_580_PREF_FILE" \
    && grep -Fqs "Pin: release o=$VENDOR_580_REPO_ORIGIN" "$VENDOR_580_PREF_FILE"
}

managed_vendor_580_repo_dir_owned() {
  [[ -d "$VENDOR_580_REPO_DIR" ]] || return 1
  if [[ -r "$VENDOR_580_REPO_DIR/Release" ]]; then
    grep -Fqx "Origin: $VENDOR_580_REPO_ORIGIN" "$VENDOR_580_REPO_DIR/Release" \
      && grep -Fqx "Label: $VENDOR_580_REPO_LABEL" "$VENDOR_580_REPO_DIR/Release" && return 0
  fi
  [[ -r "$VENDOR_580_REPO_DIR/InRelease" ]] \
    && grep -Fqs "Origin: $VENDOR_580_REPO_ORIGIN" "$VENDOR_580_REPO_DIR/InRelease" \
    && grep -Fqs "Label: $VENDOR_580_REPO_LABEL" "$VENDOR_580_REPO_DIR/InRelease"
}

managed_vendor_580_work_dir_owned() {
  [[ -d "$VENDOR_580_WORK_DIR" ]] || return 1
  [[ -r "$VENDOR_580_MANAGED_SENTINEL_FILE" ]] && grep -Fqx "$VENDOR_580_MANAGED_SENTINEL" "$VENDOR_580_MANAGED_SENTINEL_FILE" && return 0
  [[ -r "$VENDOR_580_WORK_DIR/nvidia-driver-580-manifest.tsv" ]] && grep -Eq '(^|[[:space:]])cuda-drivers[[:space:]]' "$VENDOR_580_WORK_DIR/nvidia-driver-580-manifest.tsv"
}

managed_vendor_580_keyring_owned_by_surrounding_state() {
  [[ -r "$VENDOR_580_KEYRING_PATH" ]] || return 1
  managed_vendor_580_source_file_owned || return 1
  managed_vendor_580_work_dir_owned || return 1

  # When gpg is temporarily unavailable, do not strand a clearly script-owned
  # previous branch-580 vendor installation. Require multiple independent
  # managed artifacts before inferring keyring ownership without parsing the
  # keyring itself. This intentionally remains narrower than accepting any
  # readable file at the managed keyring path.
  managed_vendor_580_pref_file_owned || managed_vendor_580_repo_dir_owned
}

managed_vendor_580_keyring_owned() {
  [[ -r "$VENDOR_580_KEYRING_PATH" ]] || return 1

  if command_exists gpg; then
    gpg --batch --show-keys "$VENDOR_580_KEYRING_PATH" 2>/dev/null | grep -Fq "$VENDOR_580_SIGNING_UID"
    return
  fi

  managed_vendor_580_keyring_owned_by_surrounding_state
}

path_exists_or_symlink() {
  [[ -e "$1" || -L "$1" ]]
}

require_vendor_580_path_absent_or_owned() {
  local path="$1"
  local description="$2"
  local owner_function="$3"

  path_exists_or_symlink "$path" || return 0
  if [[ -L "$path" ]]; then
    die "Refusing to rebuild the branch-580 local vendor repo because $description is a symbolic link at the managed path: $path"
  fi
  if ! "$owner_function"; then
    die "Refusing to rebuild the branch-580 local vendor repo because unmanaged $description exists at the managed path: $path"
  fi
}

preflight_vendor_580_rebuild_ownership() {
  require_vendor_580_path_absent_or_owned "$VENDOR_580_SOURCE_FILE" "APT source file" managed_vendor_580_source_file_owned
  require_vendor_580_path_absent_or_owned "$VENDOR_580_PREF_FILE" "APT preferences file" managed_vendor_580_pref_file_owned
  require_vendor_580_path_absent_or_owned "$VENDOR_580_KEYRING_PATH" "APT keyring" managed_vendor_580_keyring_owned
  require_vendor_580_path_absent_or_owned "$VENDOR_580_REPO_DIR" "APT repo directory" managed_vendor_580_repo_dir_owned
  require_vendor_580_path_absent_or_owned "$VENDOR_580_WORK_DIR" "work directory" managed_vendor_580_work_dir_owned
}

remove_managed_file_by_owner_check() {
  local path="$1"
  local description="$2"
  local owner_function="$3"

  [[ -e "$path" ]] || return 0
  if ! "$owner_function"; then
    warn "Leaving unmanaged $description in place: $path"
    return 0
  fi
  if (( DRY_RUN )); then
    log "Dry run: would remove managed $description: $path"
    return 0
  fi
  rm -f "$path"
  log "Removed managed $description: $path"
}

remove_managed_dir_by_owner_check() {
  local path="$1"
  local description="$2"
  local owner_function="$3"

  [[ -e "$path" ]] || return 0
  if [[ ! -d "$path" ]]; then
    warn "Leaving non-directory $description path in place: $path"
    return 0
  fi
  if ! "$owner_function"; then
    warn "Leaving unmanaged $description in place: $path"
    return 0
  fi
  if (( DRY_RUN )); then
    log "Dry run: would remove managed $description directory: $path"
    return 0
  fi
  rm -rf "$path"
  log "Removed managed $description directory: $path"
}

remove_managed_apt_vendor_artifacts() {
  # Remove the keyring before the surrounding source/pref/repo/work artifacts so
  # gpg-missing ownership fallback can still use those artifacts as proof of a
  # previous managed branch-580 vendor run.
  remove_managed_file_by_owner_check "$VENDOR_580_KEYRING_PATH" "branch-580 vendor APT keyring" managed_vendor_580_keyring_owned
  remove_managed_file_by_owner_check "$VENDOR_580_SOURCE_FILE" "branch-580 vendor APT source" managed_vendor_580_source_file_owned
  remove_managed_file_by_owner_check "$VENDOR_580_PREF_FILE" "branch-580 vendor APT preferences" managed_vendor_580_pref_file_owned
  remove_managed_dir_by_owner_check "$VENDOR_580_REPO_DIR" "branch-580 vendor APT repo" managed_vendor_580_repo_dir_owned
  remove_managed_dir_by_owner_check "$VENDOR_580_WORK_DIR" "branch-580 vendor work" managed_vendor_580_work_dir_owned
}

verify_vendor_580_manifest_candidates() {
  local manifest_path="$1"
  local package version arch filename sha256 size candidate

  while IFS=$'\t' read -r package version arch filename sha256 size; do
    [[ -n "$package" ]] || continue
    case "$arch" in
      amd64|all) ;;
      *) die "Internal error: vendored manifest selected non-amd64 package $package with Architecture=$arch." ;;
    esac
    candidate="$(package_candidate_version "$package")"
    [[ "$candidate" == "$version" ]] \
      || die "Expected $package candidate $version after branch-580 vendoring, but APT sees ${candidate:-none}. This usually means the local vendor repo is incomplete or APT selected a package from another source."
  done < "$manifest_path"
}

verify_vendor_580_external_dependency_candidates() {
  local -a packages=(
    libnvidia-egl-gbm1
    libnvidia-egl-wayland1
    libnvidia-egl-xcb1
    libnvidia-egl-xlib1
    nvidia-installer-cleanup
  )
  local package candidate

  for package in "${packages[@]}"; do
    candidate="$(package_candidate_version "$package")"
    [[ -n "$candidate" ]] \
      || die "Expected Debian/native dependency $package to have an APT candidate after branch-580 vendoring, but APT sees none. This package is intentionally not vendored from NVIDIA Debian 12; fix Debian repositories or package availability before installing."
  done
}

bootstrap_local_debian12_580_vendor_repo() {
  local work_dir index_path manifest_path selected_version manifest_count
  if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    die "The local Debian 12 branch-580 vendor fallback is only implemented for Debian amd64/x86_64 hosts."
  fi
  preflight_vendor_580_rebuild_ownership
  install_vendor_580_prereqs
  work_dir="$VENDOR_580_WORK_DIR"
  index_path="$work_dir/debian12-x86_64-Packages"
  manifest_path="$work_dir/nvidia-driver-580-manifest.tsv"
  if (( DRY_RUN )); then
    log "Dry run: would authenticate NVIDIA Debian 12 repo metadata, build a local NVIDIA branch-580 vendor repo under $VENDOR_580_REPO_DIR, write exact package pins, and refresh APT metadata."
    return 0
  fi
  install -d -m 0755 "$work_dir"
  printf '%s\n' "$VENDOR_580_MANAGED_SENTINEL" > "$VENDOR_580_MANAGED_SENTINEL_FILE"
  rm -rf "$VENDOR_580_REPO_DIR"
  install -d -m 0755 "$VENDOR_580_REPO_DIR"
  download_and_verify_debian12_580_packages_index "$index_path"
  selected_version="$(select_debian12_580_driver_version "$index_path")"
  [[ -n "$selected_version" ]] || die "Could not find a branch-580 cuda-drivers/versioned pinning package in authenticated NVIDIA Debian 12 package metadata."
  build_vendor_580_manifest "$index_path" "$selected_version" "$manifest_path"
  manifest_count="$(wc -l < "$manifest_path" | tr -d ' ')"
  log "Vendoring NVIDIA branch-580 driver stack version $selected_version ($manifest_count packages)."
  download_vendor_580_packages_from_manifest "$manifest_path" "$VENDOR_580_REPO_DIR"
  generate_vendor_580_repo_metadata "$VENDOR_580_REPO_DIR"
  write_vendor_580_preferences "$manifest_path"
  write_vendor_580_source
  log "Refreshing APT metadata for local NVIDIA branch-580 vendor repo..."
  apt-get update
  verify_vendor_580_manifest_candidates "$manifest_path"
  verify_vendor_580_external_dependency_candidates
}

use_managed_debian12_580_vendor_repo() {
  local reason="$1"
  local pinning_package

  warn "$reason"
  log "Preparing a local signed vendor repo from authenticated NVIDIA Debian 12 branch-580 metadata. Any previous managed local branch-580 repo will be rebuilt."
  bootstrap_local_debian12_580_vendor_repo
  DEBIAN12_580_FALLBACK_ACTIVE=1

  if (( DRY_RUN )); then
    log "Dry run: skipping post-bootstrap candidate check because the local vendor repo was not actually created."
    return 0
  fi

  if ! pinning_package="$(pinning_package_for_branch 580)"; then
    pinning_package_diagnostics 580
    die "Local branch-580 vendor repo was created, but no usable 580 pinning package became available."
  fi

  log "Using local vendored NVIDIA branch-580 repo on Debian 13. Selected pinning package: $pinning_package"
}

auto_debian12_580_fallback_allowed() {
  [[ "$DRIVER_BRANCH" == "auto" ]] || return 1
  (( ! NO_AUTO_DEBIAN12_580_FALLBACK )) || return 1
  all_families_in maxwell pascal volta
}

prepare_debian12_580_fallback() {
  local branch="$1"
  [[ "$branch" == "580" ]] || return 0

  if pinning_package_for_branch 580 >/dev/null 2>&1; then
    return 0
  fi

  if (( ALLOW_DEBIAN12_580_FALLBACK )); then
    if (( ! ACCEPT_CROSS_RELEASE_DRIVER_PACKAGES )); then
      die "The Debian 12 branch-580 fallback installs cross-release driver packages on Debian 13. Add --accept-cross-release-driver-packages to acknowledge this break-glass compatibility path."
    fi
    use_managed_debian12_580_vendor_repo "Break-glass path active: refreshing the managed local NVIDIA Debian 12 branch-580 vendor repo for use on Debian 13. This is a compatibility exception for Maxwell/Pascal/Volta hosts, not a general supported path."
    return 0
  fi

  if auto_debian12_580_fallback_allowed; then
    use_managed_debian12_580_vendor_repo "Debian 13 NVIDIA repo does not expose branch 580, but auto branch policy selected 580 for a Maxwell/Pascal/Volta-only host. Using the managed local Debian 12 branch-580 vendor fallback automatically. Pass --no-auto-debian12-580-fallback to require an explicit opt-in instead."
    return 0
  fi

  die "Debian 13 NVIDIA repo does not expose branch 580. For Maxwell/Pascal/Volta hosts, rerun with --allow-debian12-580-fallback --accept-cross-release-driver-packages, or use auto branch mode without --no-auto-debian12-580-fallback to use the managed local branch-580 vendor fallback."
}

is_driver_package_name() {
  local pkg="$1"

  case "$pkg" in
    nvidia-driver-pinning-*) return 1 ;;
  esac

  case "$pkg" in
    cuda-compat*|cuda-drivers*|cuda-mps*|firmware-nvidia-gsp*|libcuda1*|libcudadebugger1*|libegl-nvidia0*|libgles-nvidia1*|libgles-nvidia2*|libglx-nvidia0*|libnvcuvid1*|libnvidia-*|libnvoptix1*|libnvsdm*|libxnvctrl*|nvidia-alternative*|nvidia-detect*|nvidia-driver*|nvidia-egl-common*|nvidia-egl-icd*|nvidia-fabricmanager*|nvidia-imex*|nvidia-kernel*|nvidia-legacy*|nvidia-modprobe*|nvidia-open*|nvidia-opencl*|nvidia-persistenced*|nvidia-powerd*|nvidia-settings*|nvidia-smi*|nvidia-support*|nvidia-suspend-common*|nvidia-vdpau-driver*|nvidia-vulkan*|nvidia-xconfig*|xserver-xorg-video-nvidia*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_pinning_package_name() {
  [[ "$1" == nvidia-driver-pinning-* ]]
}

is_cuda_toolkit_package_name() {
  local pkg="$1"

  case "$pkg" in
    cuda-keyring*|cuda-drivers*|cuda-compat*|cuda-mps*) return 1 ;;
  esac

  case "$pkg" in
    cuda|cuda-[0-9]*|cuda-toolkit*|cuda-compiler*|cuda-command-line-tools*|cuda-cudart*|cuda-nvcc*|cuda-nvprof*|cuda-nvtx*|cuda-cupti*|cuda-gdb*|cuda-libraries*|cuda-libraries-dev*|libcublas*|libcufft*|libcufile*|libcurand*|libcusolver*|libcusparse*|libnpp*|libnvjpeg*|nsight*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

list_dpkg_packages() {
  local status_prefix="$1"
  local kind="$2"
  local pkg

  {
    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 2>/dev/null || true
  } | awk -v prefix="$status_prefix" '$1 ~ "^" prefix { print $2 }' | while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue

    case "$kind" in
      driver)
        if is_driver_package_name "$pkg"; then
          printf '%s\n' "$pkg"
        fi
        ;;
      pinning)
        if is_pinning_package_name "$pkg"; then
          printf '%s\n' "$pkg"
        fi
        ;;
      toolkit)
        if is_cuda_toolkit_package_name "$pkg"; then
          printf '%s\n' "$pkg"
        fi
        ;;
      driver-or-pinning)
        if is_driver_package_name "$pkg" || is_pinning_package_name "$pkg"; then
          printf '%s\n' "$pkg"
        fi
        ;;
      *)
        die "Internal error: unknown package kind: $kind"
        ;;
    esac
  done | sort -u
}

installed_driver_packages() {
  list_dpkg_packages ii driver
}

residual_driver_packages() {
  list_dpkg_packages rc driver-or-pinning
}

installed_cuda_toolkit_packages() {
  list_dpkg_packages ii toolkit
}

installed_pinning_packages() {
  list_dpkg_packages ii pinning
}

package_installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

has_installed_driver_packages() {
  [[ -n "$(installed_driver_packages)" ]]
}

nonpackaged_nvidia_runtime_present() {
  command_exists nvidia-smi \
    || [[ -e /proc/driver/nvidia/version ]] \
    || [[ -x /usr/bin/nvidia-uninstall ]] \
    || { command_exists lsmod && lsmod | awk '{print $1}' | grep -Eq '^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm)$'; }
}

show_package_list() {
  local title="$1"
  local pkgs="$2"

  if [[ -n "$pkgs" ]]; then
    log "$title"
    printf '%s\n' "$pkgs" | sed 's/^/  - /'
  fi
}

show_detected_driver_packages() {
  show_package_list "Detected installed NVIDIA driver-related packages:" "$(installed_driver_packages)"
  show_package_list "Detected installed NVIDIA branch-pinning packages:" "$(installed_pinning_packages)"
}

show_runtime_traces() {
  if command_exists nvidia-smi; then
    warn "nvidia-smi exists at: $(command -v nvidia-smi)"
  fi

  if [[ -e /proc/driver/nvidia/version ]]; then
    warn "/proc/driver/nvidia/version exists:"
    sed 's/^/  /' /proc/driver/nvidia/version >&2 || true
  fi

  if [[ -x /usr/bin/nvidia-uninstall ]]; then
    warn "NVIDIA runfile driver uninstaller exists: /usr/bin/nvidia-uninstall"
  fi

  if command_exists lsmod && lsmod | awk '{print $1}' | grep -Eq '^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm)$'; then
    warn "NVIDIA kernel modules are currently loaded:"
    lsmod | awk '$1 ~ /^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm)$/ { print "  " $1 }' >&2
  fi
}

report_reset_blockers() {
  local blockers=0
  local unit
  local -a devices=()

  if compgen -G '/dev/nvidia*' >/dev/null; then
    mapfile -t devices < <(compgen -G '/dev/nvidia*' | sort)
    if command_exists fuser; then
      if fuser "${devices[@]}" >/dev/null 2>&1; then
        blockers=1
        warn "Active processes are using NVIDIA device files:"
        fuser -v "${devices[@]}" >&2 || true
      fi
    else
      blockers=1
      warn "fuser is not installed; cannot check active /dev/nvidia* users."
    fi
  fi

  if command_exists systemctl; then
    for unit in display-manager.service nvidia-persistenced.service; do
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        blockers=1
        warn "Service is active and may block driver teardown: $unit"
      fi
    done
  fi

  if (( blockers )); then
    if (( IGNORE_RESET_BLOCKERS )); then
      warn "Reset blockers were detected, but --ignore-reset-blockers was passed. Continuing."
      return 0
    fi
    die "Active GPU users or key services were detected. Stop them or pass --ignore-reset-blockers during a maintenance window."
  fi
}

purge_packages() {
  local -a packages=("$@")

  if ((${#packages[@]} == 0)); then
    return 0
  fi

  printf '%s\n' "${packages[@]}" | sed 's/^/  - /'
  run_apt_get purge "${packages[@]}"
}

purge_driver_packages() {
  local -a packages=()
  local pkgs

  pkgs="$(installed_driver_packages)"
  if [[ -n "$pkgs" ]]; then
    log "Purging installed NVIDIA driver-related packages..."
    mapfile -t packages <<< "$pkgs"
    purge_packages "${packages[@]}"
  else
    log "No installed NVIDIA driver-related APT packages detected."
  fi

  pkgs="$(installed_pinning_packages)"
  if [[ -n "$pkgs" ]]; then
    log "Purging installed NVIDIA branch-pinning packages..."
    mapfile -t packages <<< "$pkgs"
    purge_packages "${packages[@]}"
  fi

  pkgs="$(residual_driver_packages)"
  if [[ -n "$pkgs" ]]; then
    log "Purging residual NVIDIA driver package configuration..."
    mapfile -t packages <<< "$pkgs"
    purge_packages "${packages[@]}"
  fi

  run_apt_get autoremove
}

purge_cuda_toolkit_packages_if_requested() {
  if (( ! PURGE_CUDA_TOOLKIT )); then
    return 0
  fi

  local pkgs
  local -a packages=()

  pkgs="$(installed_cuda_toolkit_packages)"
  if [[ -z "$pkgs" ]]; then
    log "No CUDA Toolkit APT packages detected."
    return 0
  fi

  log "Purging CUDA Toolkit APT packages by request..."
  mapfile -t packages <<< "$pkgs"
  purge_packages "${packages[@]}"
  run_apt_get autoremove
}

run_runfile_driver_uninstaller_if_present() {
  if [[ ! -x /usr/bin/nvidia-uninstall ]]; then
    return 0
  fi

  if (( DRY_RUN )); then
    log "Dry run: would run /usr/bin/nvidia-uninstall --silent"
    return 0
  fi

  log "Detected NVIDIA runfile driver uninstaller. Running: /usr/bin/nvidia-uninstall --silent"
  if ! /usr/bin/nvidia-uninstall --silent; then
    die "nvidia-uninstall failed. Resolve the runfile installation manually before continuing."
  fi
}

warn_about_runfile_toolkit_uninstallers() {
  local found=0

  while IFS= read -r uninstaller; do
    [[ -n "$uninstaller" ]] || continue
    found=1
    warn "CUDA Toolkit runfile uninstaller exists: $uninstaller"
  done < <(find /usr/local -maxdepth 3 -type f -path '/usr/local/cuda-*/bin/cuda-uninstaller' 2>/dev/null | sort -V)

  if (( found && ! PURGE_CUDA_TOOLKIT )); then
    warn "Driver reset does not run CUDA Toolkit runfile uninstallers. Use them manually if toolkit cleanup is also wanted."
  fi
}

confirm_reset_action() {
  local action="$1"

  show_detected_driver_packages
  show_runtime_traces
  report_reset_blockers

  if (( PURGE_CUDA_TOOLKIT )); then
    show_package_list "Detected CUDA Toolkit packages selected by --purge-cuda-toolkit:" "$(installed_cuda_toolkit_packages)"
  fi

  confirm "$action" || die "User declined. No changes made."
}

reset_nvidia_driver_state() {
  local action="Proceed with NVIDIA driver reset/purge"
  confirm_reset_action "$action"

  log "Resetting NVIDIA driver state..."
  remove_laptop_power_managed_artifacts
  remove_managed_apt_vendor_artifacts
  run_runfile_driver_uninstaller_if_present
  purge_driver_packages
  purge_cuda_toolkit_packages_if_requested
  warn_about_runfile_toolkit_uninstallers
  log "NVIDIA driver reset step complete."
}

check_nouveau() {
  if command_exists lsmod && lsmod | awk '{print $1}' | grep -qx 'nouveau'; then
    warn "nouveau is currently loaded. A reboot may be required before the NVIDIA driver can bind to the GPU."
  fi
}

check_secure_boot() {
  if ! command_exists mokutil; then
    return 0
  fi

  local state
  state="$(mokutil --sb-state 2>/dev/null || true)"
  if printf '%s\n' "$state" | grep -qi 'SecureBoot enabled'; then
    warn "Secure Boot is enabled. DKMS-built NVIDIA kernel modules may need local signing/MOK enrollment before they can load."
  fi
}

check_pinning_conflicts() {
  local branch="$1"
  local desired_pinning
  local installed_pinning

  if (( DRY_RUN && DEBIAN12_580_FALLBACK_ACTIVE )) && [[ "$branch" == "580" ]]; then
    log "Dry run: would check NVIDIA driver branch pinning conflicts after creating the local branch-580 vendor repo."
    return 0
  fi

  if ! desired_pinning="$(pinning_package_for_branch "$branch")"; then
    pinning_package_diagnostics "$branch"
    die "No usable NVIDIA driver branch-pinning package is available for branch $branch."
  fi
  installed_pinning="$(installed_pinning_packages)"

  if [[ -z "$installed_pinning" ]]; then
    return 0
  fi

  if [[ -z "$desired_pinning" ]]; then
    die_block "Existing NVIDIA driver pinning package detected. Run with --reset to purge it before installing the current branch:" "$(printf '%s\n' "$installed_pinning" | sed 's/^/  - /')"
  fi

  local count existing
  count="$(printf '%s\n' "$installed_pinning" | grep -c '^' || true)"
  if [[ "$count" -ne 1 ]]; then
    die_block "Multiple NVIDIA driver pinning packages are installed. Run with --reset to purge old pinning first:" "$(printf '%s\n' "$installed_pinning" | sed 's/^/  - /')"
  fi

  existing="$installed_pinning"
  if ! pinning_package_matches_branch "$existing" "$branch"; then
    die_block "Conflicting NVIDIA driver pinning package detected. Wanted branch: $branch. Selected target: $desired_pinning" "$(printf '%s\n' "$installed_pinning" | sed 's/^/  - /')"
  fi

  if [[ "$existing" == "$desired_pinning" ]]; then
    log "Desired NVIDIA driver branch pinning package is already installed: $desired_pinning"
  else
    log "Installed NVIDIA driver pinning package matches branch $branch: $existing"
    log "Selected pinning target for this run: $desired_pinning"
  fi
}

install_headers() {
  require_candidate "$HEADER_PACKAGE"
  log "Installing kernel headers for $(uname -r)..."
  run_apt_get install "$HEADER_PACKAGE"
}

install_driver_branch_pinning() {
  local branch="$1"
  local pinning_package

  if (( DRY_RUN && DEBIAN12_580_FALLBACK_ACTIVE )) && [[ "$branch" == "580" ]]; then
    log "Dry run: would install selected NVIDIA branch-580 pinning package from the local vendor repo."
    return 0
  fi

  if ! pinning_package="$(pinning_package_for_branch "$branch")"; then
    pinning_package_diagnostics "$branch"
    die "No usable NVIDIA driver branch-pinning package is available for branch $branch."
  fi

  if [[ -z "$pinning_package" ]]; then
    log "Using current NVIDIA driver branch; no pinning package will be installed."
    return 0
  fi

  if package_installed "$pinning_package"; then
    log "NVIDIA driver branch pinning package already installed: $pinning_package"
    return 0
  fi

  require_candidate "$pinning_package"
  log "Installing NVIDIA driver branch pinning package: $pinning_package"
  run_apt_get install "$pinning_package"
}

install_driver() {
  if (( DRY_RUN && DEBIAN12_580_FALLBACK_ACTIVE )); then
    log "Dry run: would install NVIDIA driver package from the prepared local vendor repo: $DEFAULT_DRIVER_PACKAGE"
    return 0
  fi
  require_candidate "$DEFAULT_DRIVER_PACKAGE"
  log "Installing NVIDIA driver package: $DEFAULT_DRIVER_PACKAGE"
  run_apt_get install "$DEFAULT_DRIVER_PACKAGE"
}

preflight_install_plan() {
  local branch="$1"
  local pinning_package
  local -a packages=("$HEADER_PACKAGE")

  if (( DRY_RUN && DEBIAN12_580_FALLBACK_ACTIVE )) && [[ "$branch" == "580" ]]; then
    log "Dry run: would simulate target install transaction after creating the local branch-580 vendor repo."
    return 0
  fi

  if ! pinning_package="$(pinning_package_for_branch "$branch")"; then
    pinning_package_diagnostics "$branch"
    die "No usable NVIDIA driver branch-pinning package is available for branch $branch."
  fi
  if [[ -n "$pinning_package" ]]; then
    packages+=("$pinning_package")
  fi
  packages+=("$DEFAULT_DRIVER_PACKAGE")

  local package
  for package in "${packages[@]}"; do
    require_candidate "$package"
  done

  log "Simulating target install transaction before any reset..."
  apt-get -s install -V "${packages[@]}" >/dev/null
}

show_branch_guidance() {
  local branch="$1"

  case "$branch" in
    580)
      warn "Branch 580 selected for Maxwell/Pascal/Volta compatibility."
      warn "This script installs the driver only. For CUDA compilation targeting these GPUs, use CUDA Toolkit 12.x rather than CUDA Toolkit 13.x."
      ;;
    470)
      warn "Branch 470 selected. This is a legacy branch and may not build or operate correctly on Debian 13 kernels."
      ;;
    current)
      log "Current NVIDIA driver branch selected."
      ;;
  esac
}

handle_remove_only() {
  preflight_dpkg_state
  reset_nvidia_driver_state
  log "Done. Reboot before trying a fresh install."
}

is_portable_chassis_type() {
  local raw="$1"
  local code

  for code in $raw; do
    case "$code" in
      8|9|10|11|14|30|31|32)
        return 0
        ;;
    esac
  done

  return 1
}

is_known_nonportable_chassis_type() {
  local raw="$1"
  local code

  for code in $raw; do
    case "$code" in
      3|4|5|6|7|12|13|15|16|17|18|19|20|21|22|23|24)
        return 0
        ;;
    esac
  done

  return 1
}

known_nonportable_chassis_detected() {
  local file="${1:-/sys/class/dmi/id/chassis_type}"
  local raw=""

  [[ -r "$file" ]] || return 1
  raw="$(tr -cd '0-9[:space:]' < "$file" 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 1
  is_known_nonportable_chassis_type "$raw"
}

chassis_type_label() {
  local code="$1"

  case "$code" in
    1) echo "other" ;;
    2) echo "unknown" ;;
    3) echo "desktop" ;;
    4) echo "low-profile-desktop" ;;
    5) echo "pizza-box" ;;
    6) echo "mini-tower" ;;
    7) echo "tower" ;;
    8) echo "portable" ;;
    9) echo "laptop" ;;
    10) echo "notebook" ;;
    11) echo "hand-held" ;;
    12) echo "docking-station" ;;
    13) echo "all-in-one" ;;
    14) echo "sub-notebook" ;;
    15) echo "space-saving" ;;
    16) echo "lunch-box" ;;
    17) echo "main-server-chassis" ;;
    18) echo "expansion-chassis" ;;
    19) echo "sub-chassis" ;;
    20) echo "bus-expansion-chassis" ;;
    21) echo "peripheral-chassis" ;;
    22) echo "raid-chassis" ;;
    23) echo "rack-mount-chassis" ;;
    24) echo "sealed-case-pc" ;;
    30) echo "tablet" ;;
    31) echo "convertible" ;;
    32) echo "detachable" ;;
    *) echo "unknown-$code" ;;
  esac
}

portable_chassis_reasons_from_file() {
  local file="${1:-/sys/class/dmi/id/chassis_type}"
  local raw="" code label

  [[ -r "$file" ]] || return 0
  raw="$(tr -cd '0-9[:space:]' < "$file" 2>/dev/null || true)"
  for code in $raw; do
    label="$(chassis_type_label "$code")"
    if is_portable_chassis_type "$code"; then
      printf 'portable chassis_type=%s (%s)\n' "$code" "$label"
    else
      printf 'non-portable chassis_type=%s (%s)\n' "$code" "$label"
    fi
  done
}

portable_chassis_detected() {
  local file="${1:-/sys/class/dmi/id/chassis_type}"
  local raw=""

  [[ -r "$file" ]] || return 1
  raw="$(tr -cd '0-9[:space:]' < "$file" 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 1
  is_portable_chassis_type "$raw"
}

battery_detected() {
  local root="${1:-/sys/class/power_supply}"
  local entry type

  [[ -d "$root" ]] || return 1
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ -r "$entry/type" ]]; then
      type="$(tr '[:upper:]' '[:lower:]' < "$entry/type" 2>/dev/null || true)"
      [[ "$type" == "battery" ]] && return 0
    fi
    case "$(basename "$entry")" in
      BAT|BAT[0-9]*|battery|Battery*) return 0 ;;
    esac
  done < <(find "$root" -maxdepth 1 -mindepth 1 -type d -name 'BAT*' -o -type d -name 'battery*' -o -type d -name 'Battery*' 2>/dev/null || true)

  return 1
}

internal_panel_detected() {
  local root="${1:-/sys/class/drm}"

  [[ -d "$root" ]] || return 1
  compgen -G "$root/card*-eDP-*" >/dev/null && return 0
  compgen -G "$root/card*-LVDS-*" >/dev/null && return 0
  compgen -G "$root/card*-DSI-*" >/dev/null && return 0
  return 1
}

lspci_text_current() {
  command_exists lspci || return 0
  lspci -Dnn 2>/dev/null || true
}

gpu_display_lines_from_lspci_text() {
  local text="$1"
  awk '$0 ~ /^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[[:xdigit:]]/ && $0 ~ /\[(0300|0302|0380)\]/ { print }' <<< "$text"
}

nvidia_bdfs_from_lspci_text() {
  local text="$1"
  gpu_display_lines_from_lspci_text "$text" \
    | awk 'tolower($0) ~ /nvidia/ { print $1 }' \
    | awk '$0 ~ /^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[[:xdigit:]]$/ { print tolower($0) }' \
    | sort -V -u
}

integrated_gpu_detected_from_lspci_text() {
  local text="$1"
  local line lower

  while IFS= read -r line; do
    lower="${line,,}"
    case "$lower" in
      *intel*|*amd*|*advanced\ micro\ devices*|*ati*)
        case "$lower" in
          *nvidia*) ;;
          *) return 0 ;;
        esac
        ;;
    esac
  done < <(gpu_display_lines_from_lspci_text "$text")

  return 1
}

nvidia_gpu_detected_from_lspci_text() {
  local text="$1"
  [[ -n "$(nvidia_bdfs_from_lspci_text "$text")" ]]
}

hybrid_gpu_detected_from_lspci_text() {
  local text="$1"
  integrated_gpu_detected_from_lspci_text "$text" && nvidia_gpu_detected_from_lspci_text "$text"
}

nvidia_bdf_prefix() {
  local bdf="$1"

  if [[ "$bdf" =~ ^([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2})\.[0-9a-fA-F]$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1],,}"
    return 0
  fi

  return 1
}

nvidia_sibling_bdfs_for_bdf() {
  local bdf="$1"
  local sys_root="${2:-/sys/bus/pci/devices}"
  local prefix entry found=0

  prefix="$(nvidia_bdf_prefix "$bdf")" || return 1
  if [[ -d "$sys_root" ]]; then
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      printf '%s\n' "$(basename "$entry" | tr '[:upper:]' '[:lower:]')"
      found=1
    done < <(find "$sys_root" -maxdepth 1 -mindepth 1 -type d -name "${prefix}.*" 2>/dev/null | sort -V)
  fi

  if (( ! found )); then
    printf '%s\n' "${bdf,,}"
  fi
}

runtime_d3_status_from_text() {
  local text="$1"
  local lower="${text,,}"

  if grep -Eiq 'runtime[[:space:]]+d3.*enabled.*fine' <<< "$text"; then
    echo "enabled-fine-grained"
  elif grep -Eiq 'runtime[[:space:]]+d3.*enabled' <<< "$text"; then
    echo "enabled"
  elif grep -Eiq 'runtime[[:space:]]+d3.*(not supported|unsupported)' <<< "$text"; then
    echo "unsupported"
  elif grep -Eiq 'runtime[[:space:]]+d3.*disabled' <<< "$text"; then
    echo "disabled"
  elif [[ "$lower" == *"runtime d3"* ]]; then
    echo "unknown"
  else
    echo "unknown"
  fi
}

runtime_d3_status_for_bdf() {
  local bdf="$1"
  local proc_root="${2:-/proc/driver/nvidia/gpus}"
  local file="$proc_root/${bdf}/power"

  if [[ -r "$file" ]]; then
    runtime_d3_status_from_text "$(cat "$file" 2>/dev/null || true)"
  else
    echo "unavailable"
  fi
}

pci_power_path() {
  local bdf="$1"
  local attr="$2"
  local sys_root="${3:-/sys/bus/pci/devices}"

  printf '%s/%s/power/%s\n' "$sys_root" "$bdf" "$attr"
}

pci_power_read() {
  local bdf="$1"
  local attr="$2"
  local sys_root="${3:-/sys/bus/pci/devices}"
  local path

  path="$(pci_power_path "$bdf" "$attr" "$sys_root")"
  if [[ -r "$path" ]]; then
    cat "$path" 2>/dev/null || true
  else
    echo "unavailable"
  fi
}

laptop_power_confidence_from_signals() {
  local portable_chassis="$1"
  local battery="$2"
  local internal_panel="$3"
  local hybrid="$4"

  [[ "$hybrid" == "yes" ]] || return 1
  [[ "$portable_chassis" == "yes" ]] && return 0
  [[ "$battery" == "yes" && "$internal_panel" == "yes" ]] && return 0
  return 1
}

laptop_power_decision_for_mode() {
  local mode="$1"
  local assume_yes="$2"
  local confident="$3"

  case "$mode" in
    off)
      echo "skip"
      ;;
    on)
      echo "apply"
      ;;
    auto)
      if [[ "$confident" == "yes" ]]; then
        echo "apply"
      else
        echo "skip"
      fi
      ;;
    ask)
      if [[ "$confident" != "yes" ]]; then
        echo "skip"
      elif [[ "$assume_yes" == "1" ]]; then
        echo "apply"
      else
        echo "prompt"
      fi
      ;;
    *)
      echo "skip"
      ;;
  esac
}

laptop_power_on_topology_status() {
  local known_nonportable_chassis="$1"
  local hybrid="$2"
  local nvidia_gpu="$3"

  if [[ "$nvidia_gpu" != "yes" ]]; then
    echo "no-nvidia"
  elif [[ "$known_nonportable_chassis" == "yes" ]]; then
    echo "known-nonportable"
  elif [[ "$hybrid" != "yes" ]]; then
    echo "non-hybrid"
  else
    echo "allowed"
  fi
}

managed_file_has_sentinel() {
  local path="$1"
  local sentinel="$2"

  [[ -r "$path" ]] || return 1
  grep -Fqx "$sentinel" "$path" 2>/dev/null
}

preflight_managed_file_write() {
  local path="$1"
  local sentinel="$2"
  local dir

  if [[ -e "$path" ]] && ! managed_file_has_sentinel "$path" "$sentinel"; then
    die "Refusing to overwrite unmanaged file: $path"
  fi

  dir="$(dirname "$path")"
  if [[ -e "$dir" && ! -d "$dir" ]]; then
    die "Refusing to write managed file because parent path is not a directory: $dir"
  fi
}

write_managed_file() {
  local path="$1"
  local sentinel="$2"
  local mode="$3"
  local content="$4"
  local dir tmp

  preflight_managed_file_write "$path" "$sentinel"

  if [[ -r "$path" ]] && cmp -s <(printf '%s' "$content") "$path"; then
    log "Managed file already up to date: $path"
    return 0
  fi

  if (( DRY_RUN )); then
    log "Dry run: would write managed file: $path"
    printf '%s' "$content" | sed 's/^/  | /'
    return 0
  fi

  dir="$(dirname "$path")"
  install -d -m 0755 "$dir"
  tmp="$(mktemp "$dir/.${SCRIPT_NAME}.tmp.XXXXXX")"
  printf '%s' "$content" > "$tmp"
  install -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  log "Wrote managed file: $path"
}

remove_managed_file_if_sentinel() {
  local path="$1"
  local sentinel="$2"

  [[ -e "$path" ]] || return 0
  if ! managed_file_has_sentinel "$path" "$sentinel"; then
    warn "Leaving unmanaged file in place: $path"
    return 0
  fi

  if (( DRY_RUN )); then
    log "Dry run: would remove managed file: $path"
    return 0
  fi

  rm -f "$path"
  log "Removed managed file: $path"
}

prime_run_helper_body() {
  cat <<'EOF'
exec env \
  __NV_PRIME_RENDER_OFFLOAD=1 \
  __GLX_VENDOR_LIBRARY_NAME=nvidia \
  __VK_LAYER_NV_optimus=NVIDIA_only \
  "$@"
EOF
}

prime_run_helper_content() {
  cat <<EOF
#!/bin/sh
$PRIME_RUN_SENTINEL
$(prime_run_helper_body)
EOF
}

legacy_prime_run_helper_content() {
  cat <<'EOF'
#!/bin/sh
exec env \
  __NV_PRIME_RENDER_OFFLOAD=1 \
  __GLX_VENDOR_LIBRARY_NAME=nvidia \
  __VK_LAYER_NV_optimus=NVIDIA_only \
  "$@"
EOF
}

prime_run_helper_is_managed() {
  local expected legacy

  [[ -r "$PRIME_RUN_PATH" ]] || return 1
  expected="$(prime_run_helper_content)"$'\n'
  legacy="$(legacy_prime_run_helper_content)"$'\n'
  grep -Fqx "$PRIME_RUN_SENTINEL" "$PRIME_RUN_PATH" 2>/dev/null && return 0
  cmp -s <(printf '%s' "$expected") "$PRIME_RUN_PATH" && return 0
  cmp -s <(printf '%s' "$legacy") "$PRIME_RUN_PATH" && return 0
  return 1
}

write_prime_run_helper_if_absent() {
  local content

  if [[ -e "$PRIME_RUN_PATH" ]]; then
    log "Leaving existing prime-run helper untouched: $PRIME_RUN_PATH"
    return 0
  fi

  content="$(prime_run_helper_content)"$'\n'
  if (( DRY_RUN )); then
    log "Dry run: would create managed PRIME offload helper: $PRIME_RUN_PATH"
    printf '%s' "$content" | sed 's/^/  | /'
    return 0
  fi

  install -d -m 0755 "$(dirname "$PRIME_RUN_PATH")"
  printf '%s' "$content" > "$PRIME_RUN_PATH"
  chmod 0755 "$PRIME_RUN_PATH"
  log "Created managed PRIME offload helper: $PRIME_RUN_PATH"
}

remove_prime_run_helper_if_managed() {
  [[ -e "$PRIME_RUN_PATH" ]] || return 0
  if ! prime_run_helper_is_managed; then
    warn "Leaving existing prime-run helper untouched because it does not match this script's helper: $PRIME_RUN_PATH"
    return 0
  fi

  if (( DRY_RUN )); then
    log "Dry run: would remove script-owned PRIME offload helper: $PRIME_RUN_PATH"
    return 0
  fi

  rm -f "$PRIME_RUN_PATH"
  log "Removed script-owned PRIME offload helper: $PRIME_RUN_PATH"
}

run_update_initramfs_if_available() {
  if ! command_exists update-initramfs; then
    warn "update-initramfs is unavailable; reboot-time module-option changes may not be picked up until initramfs is updated manually."
    return 0
  fi

  if (( DRY_RUN )); then
    log "Dry run: would run update-initramfs -u"
    return 0
  fi

  log "Updating initramfs for NVIDIA module-option changes..."
  update-initramfs -u
}

systemd_unit_exists() {
  local unit="$1"

  command_exists systemctl || return 1
  systemctl list-unit-files "$unit" --no-legend 2>/dev/null | awk '{ print $1 }' | grep -Fxq "$unit" \
    || systemctl cat "$unit" >/dev/null 2>&1
}


nvidia_persistenced_mask_marker_is_owned() {
  grep -Fqx "$MANAGED_SENTINEL nvidia-persistenced-mask" "$NVIDIA_PERSISTENCED_MASK_MARKER" 2>/dev/null
}

preflight_nvidia_persistenced_mask_marker() {
  local marker_dir

  marker_dir="$(dirname "$NVIDIA_PERSISTENCED_MASK_MARKER")"
  if [[ -e "$marker_dir" && ! -d "$marker_dir" ]]; then
    die "Refusing to manage nvidia-persistenced mask marker because parent path is not a directory: $marker_dir"
  fi

  if [[ -e "$NVIDIA_PERSISTENCED_MASK_MARKER" ]] && ! nvidia_persistenced_mask_marker_is_owned; then
    die "Refusing to overwrite unmanaged nvidia-persistenced mask marker: $NVIDIA_PERSISTENCED_MASK_MARKER"
  fi
}

systemd_unit_is_masked() {
  local unit="$1"
  local state=""

  command_exists systemctl || return 1
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  [[ "$state" == masked || "$state" == masked-runtime ]]
}

persistenced_mask_action_for_state() {
  local aggressive="$1"
  local currently_masked="$2"
  local marker_owned="$3"

  if [[ "$aggressive" != "1" ]]; then
    echo "skip"
  elif [[ "$currently_masked" == "yes" && "$marker_owned" == "yes" ]]; then
    echo "already-owned"
  elif [[ "$currently_masked" == "yes" ]]; then
    echo "preexisting-mask"
  else
    echo "create"
  fi
}

create_managed_nvidia_persistenced_mask_if_unowned() {
  local masked="no" marker_owned="no" action

  preflight_nvidia_persistenced_mask_marker

  if ! command_exists systemctl; then
    warn "systemctl is unavailable; cannot mask nvidia-persistenced.service."
    return 0
  fi

  if systemd_unit_is_masked nvidia-persistenced.service; then
    masked="yes"
  fi
  if nvidia_persistenced_mask_marker_is_owned; then
    marker_owned="yes"
  fi

  action="$(persistenced_mask_action_for_state "$LAPTOP_POWER_AGGRESSIVE" "$masked" "$marker_owned")"
  case "$action" in
    skip)
      return 0
      ;;
    already-owned)
      log "nvidia-persistenced.service is already masked by this script; managed marker is present."
      return 0
      ;;
    preexisting-mask)
      warn "nvidia-persistenced.service is already masked. Leaving the administrator-owned mask untouched and not recording script ownership."
      return 0
      ;;
    create)
      warn "Aggressive laptop power policy will mask nvidia-persistenced.service. This is reversible only when this script creates the mask and records its managed marker."
      if (( DRY_RUN )); then
        log "Dry run: would mask nvidia-persistenced.service and create $NVIDIA_PERSISTENCED_MASK_MARKER because the service is not currently masked"
        return 0
      fi

      install -d -m 0755 "$SCRIPT_STATE_DIR"
      if systemctl mask nvidia-persistenced.service >/dev/null 2>&1; then
        printf '%s\n' "$MANAGED_SENTINEL nvidia-persistenced-mask" > "$NVIDIA_PERSISTENCED_MASK_MARKER"
        log "Masked nvidia-persistenced.service and recorded managed marker: $NVIDIA_PERSISTENCED_MASK_MARKER"
      else
        warn "Could not mask nvidia-persistenced.service; no managed mask marker was written."
      fi
      ;;
    *)
      die "Internal error: unknown persistenced mask action: $action"
      ;;
  esac
}

disable_nvidia_persistenced_for_laptop_power() {
  if (( KEEP_NVIDIA_PERSISTENCED )); then
    log "Keeping nvidia-persistenced enabled by request."
    return 0
  fi

  warn "nvidia-persistenced helps repeated CUDA and server-style workloads avoid startup overhead, but laptop-first idle behavior usually wants persistence off so the dGPU can sleep after work finishes."

  if command_exists nvidia-smi; then
    if (( DRY_RUN )); then
      log "Dry run: would run nvidia-smi -pm 0"
    else
      log "Best-effort disabling NVIDIA persistence mode with nvidia-smi -pm 0."
      nvidia-smi -pm 0 >/dev/null 2>&1 || warn "nvidia-smi -pm 0 failed; continuing with service policy."
    fi
  fi

  if systemd_unit_exists nvidia-persistenced.service; then
    if (( DRY_RUN )); then
      log "Dry run: would disable and stop nvidia-persistenced.service"
    else
      systemctl disable --now nvidia-persistenced.service >/dev/null 2>&1 \
        || warn "Could not disable/stop nvidia-persistenced.service; continuing."
      log "Disabled and stopped nvidia-persistenced.service when possible."
    fi

    if (( LAPTOP_POWER_AGGRESSIVE )); then
      create_managed_nvidia_persistenced_mask_if_unowned
    fi
  else
    log "nvidia-persistenced.service is not present; no persistence service change needed."
  fi
}

write_laptop_runtime_pm_udev_rule() {
  local content
  content="$(cat <<EOF
$LAPTOP_POWER_UDEV_SENTINEL
# Set NVIDIA PCI functions to runtime PM auto so hybrid laptops can power down the dGPU at idle.
ACTION=="add|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", TEST=="power/control", ATTR{power/control}="auto"
EOF
)"$'\n'

  write_managed_file "$LAPTOP_POWER_UDEV_RULE_PATH" "$LAPTOP_POWER_UDEV_SENTINEL" 0644 "$content"

  if command_exists udevadm; then
    if (( DRY_RUN )); then
      log "Dry run: would reload udev rules after writing $LAPTOP_POWER_UDEV_RULE_PATH"
    else
      udevadm control --reload-rules >/dev/null 2>&1 || warn "udevadm control --reload-rules failed."
      log "Reloaded udev rules."
    fi
  else
    warn "udevadm is unavailable; udev rules will be loaded on next boot."
  fi
}

all_nvidia_families_ampere_or_newer() {
  local family

  ((${#GPU_FAMILIES[@]} > 0)) || return 1
  for family in "${GPU_FAMILIES[@]}"; do
    case "$family" in
      ampere|ada|hopper|blackwell) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

all_nvidia_families_runtime_d3_modprobe_supported() {
  local family

  ((${#GPU_FAMILIES[@]} > 0)) || return 1
  for family in "${GPU_FAMILIES[@]}"; do
    case "$family" in
      turing|ampere|ada|hopper|blackwell) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

runtime_d3_modprobe_decision_for_statuses() {
  local supported_family="$1"
  local ampere_or_newer="$2"
  shift 2
  local status saw_any=0 saw_fine=0 saw_enabled=0 saw_disabled=0 saw_unavailable=0 saw_unknown=0 saw_unsupported=0

  for status in "$@"; do
    case "$status" in
      enabled-fine-grained)
        saw_any=1
        saw_fine=1
        ;;
      enabled)
        saw_any=1
        saw_enabled=1
        ;;
      disabled)
        saw_any=1
        saw_disabled=1
        ;;
      unsupported)
        saw_any=1
        saw_unsupported=1
        ;;
      unavailable)
        saw_unavailable=1
        ;;
      unknown|*)
        saw_any=1
        saw_unknown=1
        ;;
    esac
  done

  if (( saw_unsupported )); then
    echo "skip-unsupported"
  elif [[ "$supported_family" != "yes" ]]; then
    echo "skip-unsupported-family"
  elif (( saw_disabled )); then
    echo "write-disabled"
  elif (( saw_unavailable )); then
    echo "write-unavailable"
  elif (( saw_unknown )); then
    echo "write-unknown"
  elif (( saw_fine )) && [[ "$ampere_or_newer" == "yes" ]]; then
    echo "skip-driver-default"
  elif (( saw_enabled )); then
    echo "skip-enabled"
  elif (( ! saw_any )); then
    echo "write-unavailable"
  else
    echo "skip-enabled"
  fi
}

runtime_d3_statuses_for_bdfs() {
  local -a bdfs=("$@")
  local bdf

  for bdf in "${bdfs[@]}"; do
    runtime_d3_status_for_bdf "$bdf"
  done
}

runtime_d3_modprobe_decision_for_bdfs() {
  local -a bdfs=("$@")
  local -a statuses=()
  local supported_family="no" ampere_or_newer="no"

  all_nvidia_families_runtime_d3_modprobe_supported && supported_family="yes"
  all_nvidia_families_ampere_or_newer && ampere_or_newer="yes"
  mapfile -t statuses < <(runtime_d3_statuses_for_bdfs "${bdfs[@]}")
  runtime_d3_modprobe_decision_for_statuses "$supported_family" "$ampere_or_newer" "${statuses[@]}"
}

runtime_d3_modprobe_needed_for_bdfs() {
  local decision

  decision="$(runtime_d3_modprobe_decision_for_bdfs "$@")"
  [[ "$decision" == write-* ]]
}

write_runtime_d3_modprobe_if_needed() {
  local -a bdfs=("$@")
  local content decision

  decision="$(runtime_d3_modprobe_decision_for_bdfs "${bdfs[@]}")"
  case "$decision" in
    write-disabled)
      warn "Runtime D3 diagnostics report disabled on supported NVIDIA hardware. Writing a managed Dynamic Power Management option."
      ;;
    write-unavailable)
      warn "Runtime D3 diagnostics are unavailable, which is common before the first post-install reboot. Writing a managed Dynamic Power Management option for supported NVIDIA laptop hardware so boot-time policy is deterministic."
      ;;
    write-unknown)
      warn "Runtime D3 diagnostics are inconclusive on supported NVIDIA hardware. Writing a managed Dynamic Power Management option."
      ;;
    skip-driver-default)
      log "Runtime D3 modprobe override not written: Ampere-or-newer diagnostics already report fine-grained Runtime D3 enabled."
      return 0
      ;;
    skip-enabled)
      log "Runtime D3 modprobe override not written: driver diagnostics already report Runtime D3 enabled."
      return 0
      ;;
    skip-unsupported)
      warn "Runtime D3 diagnostics report unsupported. Not writing NVreg_DynamicPowerManagement=0x02 because a module option cannot make unsupported hardware/driver paths supported."
      return 0
      ;;
    skip-unsupported-family)
      warn "Runtime D3 modprobe override not written: NVIDIA GPU family is unknown or not in the supported modern runtime-D3 policy set."
      return 0
      ;;
    *)
      die "Internal error: unknown Runtime D3 modprobe decision: $decision"
      ;;
  esac

  content="$(cat <<EOF
$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL
# Enable NVIDIA Runtime D3 dynamic power management for supported laptop dGPUs when diagnostics are disabled, unavailable, or inconclusive.
options nvidia NVreg_DynamicPowerManagement=0x02
EOF
)"$'\n'
  write_managed_file "$LAPTOP_RUNTIME_PM_MODPROBE_PATH" "$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL" 0644 "$content"
  run_update_initramfs_if_available
  warn "A reboot is required for the managed Runtime D3 module option to take effect."
}

apply_runtime_pm_auto_now() {
  local -a bdfs=("$@")
  local bdf sibling path value
  local -A seen=()

  for bdf in "${bdfs[@]}"; do
    while IFS= read -r sibling; do
      [[ -n "$sibling" ]] || continue
      [[ -z "${seen[$sibling]:-}" ]] || continue
      seen[$sibling]=1
      path="$(pci_power_path "$sibling" control)"
      if [[ ! -e "$path" ]]; then
        log "Runtime PM control is unavailable for PCI function $sibling ($path)."
        continue
      fi
      value="$(pci_power_read "$sibling" control)"
      if [[ "$value" == "auto" ]]; then
        log "PCI runtime PM already auto for $sibling."
        continue
      fi
      if (( DRY_RUN )); then
        log "Dry run: would write auto to $path"
      else
        if printf 'auto\n' > "$path" 2>/dev/null; then
          log "Set PCI runtime PM control=auto for $sibling."
        else
          warn "Could not write auto to $path; this is best-effort before reboot."
        fi
      fi
    done < <(nvidia_sibling_bdfs_for_bdf "$bdf")
  done
}

nvidia_smi_gpu_power_report() {
  command_exists nvidia-smi || return 1
  nvidia-smi --query-gpu=pci.bus_id,display_active,persistence_mode --format=csv,noheader,nounits 2>/dev/null || return 1
}

nvidia_smi_report_has_active_display_or_persistence() {
  local report="$1"

  awk -F, '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return tolower(s) }
    function truthy(s) { s = trim(s); return s ~ /^(enabled|active|yes|on)$/ }
    NF >= 2 { for (i = 2; i <= NF; i++) if (truthy($i)) found = 1 }
    END { exit found ? 0 : 1 }
  ' <<< "$report"
}

find_unmanaged_laptop_power_policy_conflicts() {
  local modprobe_dir="${1:-$MODPROBE_POLICY_DIR}"
  local udev_dir="${2:-$UDEV_RULES_DIR}"
  local file line lower

  if [[ -d "$modprobe_dir" ]]; then
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      case "$file" in
        "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"|"$NVIDIA_SUSPEND_MODPROBE_PATH") continue ;;
      esac
      while IFS= read -r line; do
        [[ -n "$line" ]] && printf '%s:%s\n' "$file" "$line"
      done < <(grep -nE 'NVreg_(DynamicPowerManagement|PreserveVideoMemoryAllocations)' "$file" 2>/dev/null || true)
    done < <(find "$modprobe_dir" -maxdepth 1 -type f \( -name '*.conf' -o -name '*.options' \) -print 2>/dev/null | sort)
  fi

  if [[ -d "$udev_dir" ]]; then
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      [[ "$file" == "$LAPTOP_POWER_UDEV_RULE_PATH" ]] && continue
      while IFS= read -r line; do
        lower="${line,,}"
        if [[ "$lower" == *'0x10de'* && "$lower" == *'power/control'* ]]; then
          case "$lower" in
            *'attr{power/control}="on"'*|*'attr{power/control}=on'*|*'power/control}="on"'*|*'power/control}=on'*)
              printf '%s:%s\n' "$file" "$line"
              ;;
          esac
        fi
      done < <(grep -nE '0x10de|NVIDIA|nvidia|power/control' "$file" 2>/dev/null || true)
    done < <(find "$udev_dir" -maxdepth 1 -type f -name '*.rules' -print 2>/dev/null | sort)
  fi
}

report_laptop_power_policy_conflicts() {
  local conflicts

  conflicts="$(find_unmanaged_laptop_power_policy_conflicts || true)"
  if [[ -z "$conflicts" ]]; then
    printf '  unmanaged NVIDIA power-policy conflicts: none detected\n'
    return 0
  fi

  printf '  unmanaged NVIDIA power-policy conflicts or overrides detected:\n'
  printf '%s\n' "$conflicts" | sed 's/^/    - /'
  printf '  These findings are diagnostic only; ambiguous real-world policy variance is reported, not treated as an installer failure.\n'
}

warn_about_laptop_power_limits() {
  warn "External displays wired through NVIDIA may keep the dGPU awake."
  warn "CUDA workloads will still heat the GPU while they run; this policy aims to let the GPU sleep afterward."

  if command_exists nvidia-smi; then
    local report
    report="$(nvidia_smi_gpu_power_report || true)"
    if [[ -n "$report" ]]; then
      printf '%s\n' "$report" | sed 's|^|[nvidia-cuda-installer] NVIDIA display/persistence: |'
      if nvidia_smi_report_has_active_display_or_persistence "$report"; then
        warn "NVIDIA display output or persistence mode appears active; runtime suspend may not occur until displays, clients, or persistence release the dGPU."
      fi
    fi
  fi
}

configure_nvidia_suspend_services() {
  local content unit saw_unit=0

  preflight_nvidia_suspend_service_config
  warn "NVIDIA suspend/hibernate support preserves VRAM across sleep states. It is not an idle-cooling feature."
  content="$(cat <<EOF
$NVIDIA_SUSPEND_MODPROBE_SENTINEL
# Preserve NVIDIA VRAM allocations across suspend/hibernate and keep temporary backing store off small tmpfs mounts.
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp
EOF
)"$'\n'

  write_managed_file "$NVIDIA_SUSPEND_MODPROBE_PATH" "$NVIDIA_SUSPEND_MODPROBE_SENTINEL" 0644 "$content"

  if command_exists systemctl; then
    for unit in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
      if systemd_unit_exists "$unit"; then
        saw_unit=1
        if (( DRY_RUN )); then
          log "Dry run: would enable $unit"
        else
          systemctl enable "$unit" >/dev/null 2>&1 || warn "Could not enable $unit."
          log "Enabled $unit."
        fi
      fi
    done
    (( saw_unit )) || log "No NVIDIA suspend/resume/hibernate systemd units were found to enable."
  else
    warn "systemctl is unavailable; cannot enable NVIDIA suspend/resume/hibernate units."
  fi

  run_update_initramfs_if_available
  warn "A reboot is required for NVIDIA suspend/hibernate module options to take effect."
}

remove_managed_nvidia_persistenced_mask() {
  if [[ ! -e "$NVIDIA_PERSISTENCED_MASK_MARKER" ]]; then
    return 0
  fi
  if ! nvidia_persistenced_mask_marker_is_owned; then
    warn "Leaving unexpected nvidia-persistenced mask marker untouched: $NVIDIA_PERSISTENCED_MASK_MARKER"
    return 0
  fi

  if (( DRY_RUN )); then
    log "Dry run: would unmask nvidia-persistenced.service only because this script owns the mask marker, then remove $NVIDIA_PERSISTENCED_MASK_MARKER"
    return 0
  fi

  if ! command_exists systemctl; then
    warn "systemctl is unavailable; leaving managed nvidia-persistenced mask marker in place: $NVIDIA_PERSISTENCED_MASK_MARKER"
    return 0
  fi

  if systemd_unit_is_masked nvidia-persistenced.service; then
    if ! systemctl unmask nvidia-persistenced.service >/dev/null 2>&1; then
      warn "Could not unmask nvidia-persistenced.service; leaving managed marker in place."
      return 0
    fi
    log "Unmasked nvidia-persistenced.service because this script owned the mask marker."
  else
    log "Managed nvidia-persistenced mask marker existed, but the service is no longer masked. Removing stale marker."
  fi

  rm -f "$NVIDIA_PERSISTENCED_MASK_MARKER"
  log "Removed managed nvidia-persistenced mask marker. The service was not re-enabled."
}

remove_laptop_power_managed_artifacts() {
  remove_managed_file_if_sentinel "$LAPTOP_POWER_UDEV_RULE_PATH" "$LAPTOP_POWER_UDEV_SENTINEL"
  remove_managed_file_if_sentinel "$LAPTOP_RUNTIME_PM_MODPROBE_PATH" "$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL"
  remove_managed_file_if_sentinel "$NVIDIA_SUSPEND_MODPROBE_PATH" "$NVIDIA_SUSPEND_MODPROBE_SENTINEL"
  remove_prime_run_helper_if_managed
  remove_managed_nvidia_persistenced_mask
}

laptop_power_detection_snapshot() {
  local lspci_text="$1"
  local portable="no" known_nonportable="no" battery="no" panel="no" integrated="no" nvidia="no" hybrid="no" confident="no"

  portable_chassis_detected && portable="yes"
  known_nonportable_chassis_detected && known_nonportable="yes"
  battery_detected && battery="yes"
  internal_panel_detected && panel="yes"
  integrated_gpu_detected_from_lspci_text "$lspci_text" && integrated="yes"
  nvidia_gpu_detected_from_lspci_text "$lspci_text" && nvidia="yes"
  hybrid_gpu_detected_from_lspci_text "$lspci_text" && hybrid="yes"
  if laptop_power_confidence_from_signals "$portable" "$battery" "$panel" "$hybrid"; then
    confident="yes"
  fi

  printf 'portable_chassis=%s
' "$portable"
  printf 'known_nonportable_chassis=%s
' "$known_nonportable"
  printf 'battery=%s
' "$battery"
  printf 'internal_panel=%s
' "$panel"
  printf 'integrated_gpu=%s
' "$integrated"
  printf 'nvidia_gpu=%s
' "$nvidia"
  printf 'hybrid=%s
' "$hybrid"
  printf 'confident=%s
' "$confident"
}

snapshot_value() {
  local snapshot="$1"
  local key="$2"
  awk -F= -v k="$key" '$1 == k { print $2; exit }' <<< "$snapshot"
}

show_laptop_power_detection_reasons() {
  local lspci_text="$1"
  local reasons

  printf '\nLaptop / hybrid graphics detection:\n'
  reasons="$(portable_chassis_reasons_from_file || true)"
  if [[ -n "$reasons" ]]; then
    printf '%s\n' "$reasons" | sed 's/^/  - /'
  else
    printf '  - chassis_type unavailable\n'
  fi

  if battery_detected; then
    printf '  - battery detected under /sys/class/power_supply\n'
  else
    printf '  - no BAT* battery detected under /sys/class/power_supply\n'
  fi

  if internal_panel_detected; then
    printf '  - internal laptop panel connector detected (eDP/LVDS/DSI)\n'
  else
    printf '  - no internal laptop panel connector detected\n'
  fi

  if integrated_gpu_detected_from_lspci_text "$lspci_text"; then
    printf '  - integrated Intel/AMD GPU detected by lspci\n'
  else
    printf '  - no integrated Intel/AMD GPU detected by lspci\n'
  fi

  if nvidia_gpu_detected_from_lspci_text "$lspci_text"; then
    printf '  - NVIDIA dGPU detected by lspci\n'
  else
    printf '  - no NVIDIA dGPU detected by lspci\n'
  fi
}

preflight_laptop_power_policy_mutations() {
  local -a bdfs=("$@")

  preflight_managed_file_write "$LAPTOP_POWER_UDEV_RULE_PATH" "$LAPTOP_POWER_UDEV_SENTINEL"
  if runtime_d3_modprobe_needed_for_bdfs "${bdfs[@]}"; then
    preflight_managed_file_write "$LAPTOP_RUNTIME_PM_MODPROBE_PATH" "$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL"
  fi
  if (( LAPTOP_POWER_AGGRESSIVE && ! KEEP_NVIDIA_PERSISTENCED )); then
    preflight_nvidia_persistenced_mask_marker
  fi
}

preflight_nvidia_suspend_service_config() {
  preflight_managed_file_write "$NVIDIA_SUSPEND_MODPROBE_PATH" "$NVIDIA_SUSPEND_MODPROBE_SENTINEL"
}

apply_laptop_power_policy() {
  local -a bdfs=("$@")

  preflight_laptop_power_policy_mutations "${bdfs[@]}"
  warn_about_laptop_power_limits
  disable_nvidia_persistenced_for_laptop_power
  write_laptop_runtime_pm_udev_rule
  apply_runtime_pm_auto_now "${bdfs[@]}"
  write_runtime_d3_modprobe_if_needed "${bdfs[@]}"
  write_prime_run_helper_if_absent
  report_laptop_power_policy_conflicts
  log "Laptop CUDA idle power policy configured. Reboot, then validate with: sudo ./$SCRIPT_NAME --check"
  log "For an explicit idle probe after reboot, run: sudo ./$SCRIPT_NAME --check-laptop-power-idle"
}

maybe_configure_laptop_power_policy() {
  local lspci_text snapshot confident hybrid nvidia_gpu known_nonportable topology_status decision
  local -a nvidia_bdfs=()

  [[ "$LAPTOP_POWER_MODE" != "off" ]] || return 0

  if ! command_exists lspci; then
    if [[ "$LAPTOP_POWER_MODE" == "on" ]]; then
      die "--laptop-power=on requires lspci for NVIDIA BDF discovery. Install pciutils or run the full installer path first."
    fi
    warn "lspci is unavailable; laptop power detection cannot be completed and no laptop policy was applied."
    return 0
  fi

  lspci_text="$(lspci_text_current)"
  mapfile -t nvidia_bdfs < <(nvidia_bdfs_from_lspci_text "$lspci_text")
  snapshot="$(laptop_power_detection_snapshot "$lspci_text")"
  confident="$(snapshot_value "$snapshot" confident)"
  hybrid="$(snapshot_value "$snapshot" hybrid)"
  nvidia_gpu="$(snapshot_value "$snapshot" nvidia_gpu)"
  known_nonportable="$(snapshot_value "$snapshot" known_nonportable_chassis)"

  show_laptop_power_detection_reasons "$lspci_text"
  if ((${#nvidia_bdfs[@]} == 0)); then
    if [[ "$LAPTOP_POWER_MODE" == "on" ]]; then
      die "--laptop-power=on was requested, but no NVIDIA display/3D/compute PCI device was detected."
    fi
    log "Laptop power policy skipped: no NVIDIA dGPU detected."
    return 0
  fi

  load_gpu_inventory_from_lspci_text "$lspci_text"

  decision="$(laptop_power_decision_for_mode "$LAPTOP_POWER_MODE" "$ASSUME_YES" "$confident")"
  case "$decision" in
    apply)
      if [[ "$LAPTOP_POWER_MODE" == "on" ]]; then
        topology_status="$(laptop_power_on_topology_status "$known_nonportable" "$hybrid" "$nvidia_gpu")"
        case "$topology_status" in
          allowed)
            if [[ "$confident" != "yes" ]]; then
              warn "--laptop-power=on explicitly requested on a hybrid topology, but portable-device signals are not confident. Proceeding because the topology is not known desktop/server or NVIDIA-only."
            fi
            ;;
          no-nvidia)
            die "--laptop-power=on was requested, but no NVIDIA display/3D/compute PCI device was detected."
            ;;
          known-nonportable)
            die "--laptop-power=on refuses a known non-portable chassis. This laptop policy is only for portable hybrid graphics systems; no desktop/server override is implemented."
            ;;
          non-hybrid)
            die "--laptop-power=on refuses a non-hybrid or NVIDIA-only topology. This laptop policy is only for Intel/AMD integrated GPU plus NVIDIA dGPU systems; no workstation/server override is implemented."
            ;;
          *)
            die "Internal error: unknown laptop power topology status: $topology_status"
            ;;
        esac
      elif [[ "$confident" != "yes" ]]; then
        log "Laptop power policy skipped: detection is not confident. Use --laptop-power=on only for portable hybrid systems after reviewing topology."
        return 0
      fi
      apply_laptop_power_policy "${nvidia_bdfs[@]}"
      ;;
    prompt)
      printf '\nThe system looks like a portable hybrid-graphics machine.\n'
      printf 'This policy disables persistence-style idle behavior and enables PCI runtime PM so CUDA can use the NVIDIA dGPU and let it sleep afterward.\n'
      if confirm "Apply laptop CUDA idle power policy"; then
        apply_laptop_power_policy "${nvidia_bdfs[@]}"
      else
        log "Laptop power policy declined. No laptop-power changes made."
      fi
      ;;
    skip)
      if [[ "$LAPTOP_POWER_MODE" == "auto" || "$LAPTOP_POWER_MODE" == "ask" ]]; then
        log "Laptop power policy skipped: portable hybrid detection is not confident. No desktop/server/ambiguous policy was applied."
      fi
      ;;
  esac
}


pci_vendor_label_for_bdf() {
  local bdf="$1"
  local sys_root="${2:-/sys/bus/pci/devices}"
  local vendor=""

  if [[ -r "$sys_root/$bdf/vendor" ]]; then
    vendor="$(tr '[:upper:]' '[:lower:]' < "$sys_root/$bdf/vendor" 2>/dev/null || true)"
  fi

  case "$vendor" in
    0x10de) echo "NVIDIA" ;;
    0x8086) echo "Intel" ;;
    0x1002|0x1022) echo "AMD" ;;
    "") echo "unknown" ;;
    *) echo "vendor-$vendor" ;;
  esac
}

boot_vga_bdfs() {
  local sys_root="${1:-/sys/bus/pci/devices}"
  local entry bdf value

  [[ -d "$sys_root" ]] || return 0
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    bdf="$(basename "$entry" | tr '[:upper:]' '[:lower:]')"
    value="$(cat "$entry/boot_vga" 2>/dev/null || true)"
    [[ "$value" == "1" ]] && printf '%s|%s\n' "$bdf" "$(pci_vendor_label_for_bdf "$bdf" "$sys_root")"
  done < <(find "$sys_root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V)
  return 0
}

drm_node_names_for_bdf() {
  local bdf="$1"
  local sys_root="${2:-/sys/bus/pci/devices}"
  local drm_dir="$sys_root/$bdf/drm"
  local entry name

  [[ -d "$drm_dir" ]] || return 0
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="$(basename "$entry")"
    case "$name" in
      card[0-9]*|renderD[0-9]*) printf '%s\n' "$name" ;;
    esac
  done < <(find "$drm_dir" -maxdepth 1 -mindepth 1 \( -name 'card[0-9]*' -o -name 'renderD[0-9]*' \) 2>/dev/null | sort -V)
  return 0
}

drm_dev_nodes_for_bdf() {
  local bdf="$1"
  local sys_root="${2:-/sys/bus/pci/devices}"
  local dev_root="${3:-/dev/dri}"
  local name

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    printf '%s/%s\n' "$dev_root" "$name"
  done < <(drm_node_names_for_bdf "$bdf" "$sys_root")
  return 0
}

drm_card_names_for_bdf() {
  local bdf="$1"
  local sys_root="${2:-/sys/bus/pci/devices}"
  local name

  while IFS= read -r name; do
    case "$name" in
      card[0-9]*) printf '%s\n' "$name" ;;
    esac
  done < <(drm_node_names_for_bdf "$bdf" "$sys_root")
  return 0
}

drm_connectors_for_bdf() {
  local bdf="$1"
  local sys_root="${2:-/sys/bus/pci/devices}"
  local drm_root="${3:-/sys/class/drm}"
  local card connector status name

  [[ -d "$drm_root" ]] || return 0
  while IFS= read -r card; do
    [[ -n "$card" ]] || continue
    while IFS= read -r connector; do
      [[ -n "$connector" ]] || continue
      name="$(basename "$connector")"
      status="$(cat "$connector/status" 2>/dev/null || printf 'unknown')"
      printf '%s|%s|%s\n' "$bdf" "$name" "$status"
    done < <(find "$drm_root" -maxdepth 1 -mindepth 1 -type d -name "${card}-*" 2>/dev/null | sort -V)
  done < <(drm_card_names_for_bdf "$bdf" "$sys_root")
  return 0
}

all_drm_connectors_with_vendors() {
  local sys_root="${1:-/sys/bus/pci/devices}"
  local drm_root="${2:-/sys/class/drm}"
  local entry bdf vendor line connector status

  [[ -d "$sys_root" ]] || return 0
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    bdf="$(basename "$entry" | tr '[:upper:]' '[:lower:]')"
    vendor="$(pci_vendor_label_for_bdf "$bdf" "$sys_root")"
    while IFS='|' read -r _ connector status; do
      [[ -n "$connector" ]] || continue
      printf '%s|%s|%s|%s\n' "$bdf" "$vendor" "$connector" "$status"
    done < <(drm_connectors_for_bdf "$bdf" "$sys_root" "$drm_root")
  done < <(find "$sys_root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V)
  return 0
}

nvidia_connector_connected_for_bdfs() {
  local sys_root="${1:-/sys/bus/pci/devices}"
  local drm_root="${2:-/sys/class/drm}"
  shift 2 || true
  local bdf _ connector status

  for bdf in "$@"; do
    while IFS='|' read -r _ connector status; do
      [[ -n "$connector" ]] || continue
      [[ "${status,,}" == "connected" ]] && return 0
    done < <(drm_connectors_for_bdf "$bdf" "$sys_root" "$drm_root")
  done
  return 1
}

non_nvidia_internal_panel_connected() {
  local sys_root="${1:-/sys/bus/pci/devices}"
  local drm_root="${2:-/sys/class/drm}"
  local bdf vendor connector status lower

  while IFS='|' read -r bdf vendor connector status; do
    [[ -n "$connector" ]] || continue
    lower="${connector,,}"
    case "$lower" in
      *-edp-*|*-lvds-*|*-dsi-*)
        [[ "$vendor" != "NVIDIA" && "${status,,}" == "connected" ]] && return 0
        ;;
    esac
  done < <(all_drm_connectors_with_vendors "$sys_root" "$drm_root")
  return 1
}

nvidia_display_routing_not_required() {
  local sys_root="${1:-/sys/bus/pci/devices}"
  local drm_root="${2:-/sys/class/drm}"
  shift 2 || true
  local boot_line boot_vendor saw_non_nvidia_boot=0

  while IFS='|' read -r _ boot_vendor; do
    [[ -n "$boot_vendor" ]] || continue
    [[ "$boot_vendor" != "NVIDIA" ]] && saw_non_nvidia_boot=1
  done < <(boot_vga_bdfs "$sys_root")

  (( saw_non_nvidia_boot )) || return 1
  non_nvidia_internal_panel_connected "$sys_root" "$drm_root" || return 1
  ! nvidia_connector_connected_for_bdfs "$sys_root" "$drm_root" "$@"
}

proc_fb_report() {
  local fb_file="${1:-/proc/fb}"

  if [[ -r "$fb_file" ]]; then
    sed 's/^/  framebuffer: /' "$fb_file" 2>/dev/null || true
  else
    printf '  framebuffer: /proc/fb unavailable\n'
  fi
}

existing_paths_from_list() {
  local path
  for path in "$@"; do
    [[ -e "$path" ]] && printf '%s\n' "$path"
  done
}

inspect_device_clients() {
  local label="$1"
  shift
  local -a devices=("$@")
  local -a existing=()
  local output status=unknown joined_devices=""

  mapfile -t existing < <(existing_paths_from_list "${devices[@]}")
  if ((${#devices[@]} == 0)); then
    printf 'status=none\n'
    printf 'tool=none\n'
    printf 'message=%s: no device nodes discovered\n' "$label"
    return 0
  fi
  if ((${#existing[@]} == 0)); then
    printf 'status=none\n'
    printf 'tool=none\n'
    printf 'message=%s: discovered nodes are absent under /dev\n' "$label"
    return 0
  fi

  joined_devices="$(printf '%s ' "${existing[@]}")"
  joined_devices="${joined_devices% }"

  if command_exists lsof; then
    output="$(lsof -nP -- "${existing[@]}" 2>&1 || true)"
    if [[ -n "$output" && "$output" != *"no such file"* ]]; then
      status=clients
    else
      status=none
    fi
    printf 'status=%s\n' "$status"
    printf 'tool=lsof\n'
    printf 'devices=%s\n' "$joined_devices"
    if [[ -n "$output" ]]; then
      printf 'output<<EOF\n%s\nEOF\n' "$output"
    fi
    return 0
  fi

  if command_exists fuser; then
    if fuser "${existing[@]}" >/dev/null 2>&1; then
      status=clients
      output="$(fuser -v "${existing[@]}" 2>&1 || true)"
    else
      status=none
      output="$(fuser -v "${existing[@]}" 2>&1 || true)"
    fi
    printf 'status=%s\n' "$status"
    printf 'tool=fuser\n'
    printf 'devices=%s\n' "$joined_devices"
    if [[ -n "$output" ]]; then
      printf 'output<<EOF\n%s\nEOF\n' "$output"
    fi
    return 0
  fi

  printf 'status=unknown\n'
  printf 'tool=none\n'
  printf 'devices=%s\n' "$joined_devices"
  printf 'message=%s client inspection skipped because neither lsof nor fuser is available\n' "$label"
}

client_report_value() {
  local report="$1"
  local key="$2"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' <<< "$report"
}

client_report_output_body() {
  local report="$1"
  awk '
    $0 == "output<<EOF" { in_body=1; next }
    $0 == "EOF" && in_body { in_body=0; next }
    in_body { print }
  ' <<< "$report"
}

print_client_report() {
  local indent="$1"
  local report="$2"
  local status tool message devices body

  status="$(client_report_value "$report" status)"
  tool="$(client_report_value "$report" tool)"
  message="$(client_report_value "$report" message)"
  devices="$(client_report_value "$report" devices)"
  body="$(client_report_output_body "$report")"

  [[ -n "$message" ]] && printf '%s%s\n' "$indent" "$message"
  [[ -n "$devices" ]] && printf '%sdevices: %s\n' "$indent" "$devices"
  case "$status" in
    clients)
      printf '%sclients detected by %s:\n' "$indent" "$tool"
      [[ -n "$body" ]] && printf '%s\n' "$body" | sed "s/^/${indent}  /"
      ;;
    none)
      printf '%sclients: none reported by %s\n' "$indent" "$tool"
      ;;
    unknown)
      printf '%sclients: inspection skipped; neither lsof nor fuser is available\n' "$indent"
      ;;
  esac
}

nvidia_dev_client_status() {
  local -a devices=()
  local report

  if ! compgen -G '/dev/nvidia*' >/dev/null; then
    echo "none"
    return 0
  fi
  mapfile -t devices < <(compgen -G '/dev/nvidia*' | sort)
  report="$(inspect_device_clients "/dev/nvidia*" "${devices[@]}")"
  client_report_value "$report" status
}

nvidia_persistenced_disabled_or_absent() {
  local active enabled

  command_exists systemctl || return 1
  if ! systemd_unit_exists nvidia-persistenced.service; then
    return 0
  fi
  active="$(systemctl is-active nvidia-persistenced.service 2>/dev/null || true)"
  enabled="$(systemctl is-enabled nvidia-persistenced.service 2>/dev/null || true)"
  [[ "$active" != "active" ]] || return 1
  case "$enabled" in
    enabled|enabled-runtime) return 1 ;;
  esac
  return 0
}

nvidia_audio_sibling_nonblocking_for_bdf() {
  local bdf="$1"
  local sys_root="${2:-/sys/bus/pci/devices}"
  local sibling class status saw_audio=0

  while IFS= read -r sibling; do
    [[ -n "$sibling" ]] || continue
    [[ "$sibling" != "$bdf" ]] || continue
    class="$(cat "$sys_root/$sibling/class" 2>/dev/null || true)"
    case "${class,,}" in
      0x0403*|0x040000|0x040300)
        saw_audio=1
        status="$(pci_power_read "$sibling" runtime_status "$sys_root")"
        case "$status" in
          suspended|unavailable) ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done < <(nvidia_sibling_bdfs_for_bdf "$bdf" "$sys_root")

  return 0
}

drm_client_output_has_graphical_process() {
  local output="${1,,}"
  grep -Eiq '(xorg|xwayland|gdm|gdm3|gnome-shell|mutter|kwin|sddm|lightdm|wayland)' <<< "$output"
}

drm_client_output_has_logind() {
  grep -Eiq 'systemd-logind|logind' <<< "$1"
}

drm_client_output_is_logind_only() {
  local output="$1"
  drm_client_output_has_logind "$output" || return 1
  ! drm_client_output_has_graphical_process "$output"
}

nvidia_bdf_runtime_policy_configured() {
  local bdf="$1"
  local sys_root="${2:-/sys/bus/pci/devices}"
  local control status d3

  control="$(pci_power_read "$bdf" control "$sys_root")"
  status="$(pci_power_read "$bdf" runtime_status "$sys_root")"
  d3="$(runtime_d3_status_for_bdf "$bdf")"
  [[ "$control" == "auto" ]] || return 1
  case "$d3" in
    enabled|enabled-fine-grained) ;;
    *) return 1 ;;
  esac
  return 0
}

nvidia_drm_nodes_for_bdfs() {
  local sys_root="${1:-/sys/bus/pci/devices}"
  local dev_root="${2:-/dev/dri}"
  shift 2 || true
  local bdf

  for bdf in "$@"; do
    drm_dev_nodes_for_bdf "$bdf" "$sys_root" "$dev_root"
  done | sort -V -u
  return 0
}

report_display_path_cross_checks() {
  local sys_root="${1:-/sys/bus/pci/devices}"
  local drm_root="${2:-/sys/class/drm}"
  local fb_file="${3:-/proc/fb}"
  shift 3 || true
  local bdf vendor connector status any_connector=0
  local boot_report=""

  printf '  Display path cross-checks:\n'
  if [[ -d "$sys_root" ]]; then
    boot_report="$(boot_vga_bdfs "$sys_root" || true)"
    if [[ -n "$boot_report" ]]; then
      while IFS='|' read -r bdf vendor; do
        [[ -n "$bdf" ]] || continue
        printf '    boot_vga=1: %s (%s)\n' "$bdf" "$vendor"
      done <<< "$boot_report"
    else
      printf '    boot_vga=1: none reported by sysfs\n'
    fi
  else
    printf '    boot_vga=1: PCI sysfs unavailable\n'
  fi

  while IFS='|' read -r bdf vendor connector status; do
    [[ -n "$connector" ]] || continue
    any_connector=1
    printf '    connector: %s (%s) %s %s\n' "$bdf" "$vendor" "$connector" "$status"
  done < <(all_drm_connectors_with_vendors "$sys_root" "$drm_root")
  (( any_connector )) || printf '    connectors: none reported by DRM sysfs\n'

  proc_fb_report "$fb_file" | sed 's/^/  /'

  if ((${#} > 0)); then
    if nvidia_connector_connected_for_bdfs "$sys_root" "$drm_root" "$@"; then
      printf '    NVIDIA connector state: at least one NVIDIA connector is connected; display routing may keep the dGPU awake.\n'
    else
      printf '    NVIDIA connector state: no connected NVIDIA connector reported.\n'
    fi
    if nvidia_display_routing_not_required "$sys_root" "$drm_root" "$@"; then
      printf '    Active display routing does not appear to require the NVIDIA dGPU; the likely blocker is a userspace DRM client.\n'
    fi
  fi
  return 0
}

report_nvidia_drm_nodes_and_clients() {
  local sys_root="${1:-/sys/bus/pci/devices}"
  local dev_root="${2:-/dev/dri}"
  shift 2 || true
  local bdf name node report
  local -a nodes=()
  local -a names=()

  printf '  NVIDIA DRM device nodes:\n'
  for bdf in "$@"; do
    mapfile -t names < <(drm_node_names_for_bdf "$bdf" "$sys_root" || true)
    if ((${#names[@]})); then
      for name in "${names[@]}"; do
        [[ -n "$name" ]] || continue
        node="$dev_root/$name"
        printf '    - %s -> %s\n' "$bdf" "$node"
        nodes+=("$node")
      done
    else
      printf '    - %s -> no DRM nodes discovered under sysfs\n' "$bdf"
    fi
  done

  report="$(inspect_device_clients "NVIDIA DRM" "${nodes[@]}")"
  printf '  NVIDIA DRM clients:\n'
  print_client_report '    ' "$report"
  return 0
}

report_nvidia_drm_and_display_diagnostics() {
  local -a bdfs=("$@")

  if ((${#bdfs[@]} == 0)); then
    return 0
  fi
  report_display_path_cross_checks /sys/bus/pci/devices /sys/class/drm /proc/fb "${bdfs[@]}"
  report_nvidia_drm_nodes_and_clients /sys/bus/pci/devices /dev/dri "${bdfs[@]}"
}

classify_laptop_power_idle_blockers() {
  local sys_root="${1:-/sys/bus/pci/devices}"
  local drm_root="${2:-/sys/class/drm}"
  local dev_root="${3:-/dev/dri}"
  shift 3 || true
  local bdf report status output configured=0 all_configured=1
  local nvidia_dev_status persistenced_ok=0 display_not_required=0 nvidia_connected=0 audio_ok=1
  local -a drm_nodes=()

  ((${#} > 0)) || return 0
  mapfile -t drm_nodes < <(nvidia_drm_nodes_for_bdfs "$sys_root" "$dev_root" "$@")
  report="$(inspect_device_clients "NVIDIA DRM" "${drm_nodes[@]}")"
  status="$(client_report_value "$report" status)"
  output="$(client_report_output_body "$report")"

  printf '  Idle blocker diagnostics:\n'
  for bdf in "$@"; do
    if ! nvidia_bdf_runtime_policy_configured "$bdf" "$sys_root"; then
      all_configured=0
    fi
    if ! nvidia_audio_sibling_nonblocking_for_bdf "$bdf" "$sys_root"; then
      audio_ok=0
    fi
  done
  (( all_configured )) && configured=1
  nvidia_dev_status="$(nvidia_dev_client_status)"
  nvidia_persistenced_disabled_or_absent && persistenced_ok=1
  nvidia_display_routing_not_required "$sys_root" "$drm_root" "$@" && display_not_required=1
  nvidia_connector_connected_for_bdfs "$sys_root" "$drm_root" "$@" && nvidia_connected=1

  printf '    Runtime D3 / PCI runtime PM configured: %s\n' "$([[ $configured -eq 1 ]] && echo yes || echo no)"
  printf '    nvidia-persistenced disabled or absent: %s\n' "$([[ $persistenced_ok -eq 1 ]] && echo yes || echo unknown-or-no)"
  printf '    /dev/nvidia* clients: %s\n' "$nvidia_dev_status"
  printf '    NVIDIA audio companion function blocking: %s\n' "$([[ $audio_ok -eq 1 ]] && echo no || echo possible)"
  print_client_report '    NVIDIA DRM ' "$report"

  if (( nvidia_connected )); then
    printf '    NVIDIA display wiring: at least one NVIDIA connector is connected; display routing may keep the dGPU awake.\n'
  fi

  if [[ "$status" == "clients" ]]; then
    if drm_client_output_is_logind_only "$output"; then
      printf '    systemd-logind is holding the NVIDIA DRM node. Treat this as supporting evidence, not the sole root cause, unless runtime usage remains nonzero or another graphical process is also present.\n'
      return 0
    fi
    if (( configured && persistenced_ok && audio_ok )) && [[ "$nvidia_dev_status" == "none" ]] && (( display_not_required )); then
      printf '    The NVIDIA dGPU is configured for runtime suspend, but the graphical stack is holding the NVIDIA DRM device open. This commonly prevents Runtime D3 idle suspend even when CUDA clients are absent.\n'
      printf '    Future remediation: configure GDM/Xorg not to auto-open the NVIDIA DRM device on hybrid laptops, preserving Intel-primary display with explicit PRIME/CUDA offload. This installer does not apply that desktop-manager policy yet.\n'
      printf '    Temporary proof step, from SSH or a TTY because stopping GDM interrupts the graphical session:\n'
      printf '      sudo systemctl stop gdm3\n'
      printf '      sleep 120\n'
      for bdf in "$@"; do
        printf '      cat /sys/bus/pci/devices/%s/power/runtime_status\n' "$bdf"
      done
      printf '      sudo systemctl start gdm3\n'
    else
      printf '    NVIDIA DRM clients are present. They may keep the dGPU awake even when no CUDA clients are using /dev/nvidia*.\n'
    fi
  elif [[ "$status" == "unknown" ]]; then
    printf '    NVIDIA DRM client inspection was skipped, so this check cannot rule out GDM/Xorg/Wayland DRM clients.\n'
  else
    printf '    No NVIDIA DRM clients were reported by available inspection tools.\n'
  fi
  return 0
}

report_nvidia_dev_users() {
  local -a devices=()

  if ! compgen -G '/dev/nvidia*' >/dev/null; then
    printf '  /dev/nvidia* users: no NVIDIA device nodes found\n'
    return 0
  fi

  mapfile -t devices < <(compgen -G '/dev/nvidia*' | sort)
  if command_exists fuser; then
    if fuser "${devices[@]}" >/dev/null 2>&1; then
      printf '  /dev/nvidia* users:\n'
      fuser -v "${devices[@]}" 2>&1 | sed 's/^/    /' || true
    else
      printf '  /dev/nvidia* users: none reported by fuser\n'
    fi
  else
    printf '  /dev/nvidia* users: fuser unavailable\n'
  fi
}

report_nvidia_persistenced_state() {
  if ! command_exists systemctl; then
    printf '  nvidia-persistenced.service: systemctl unavailable\n'
    return 0
  fi

  if systemd_unit_exists nvidia-persistenced.service; then
    printf '  nvidia-persistenced.service active: %s\n' "$(systemctl is-active nvidia-persistenced.service 2>/dev/null || true)"
    printf '  nvidia-persistenced.service enabled: %s\n' "$(systemctl is-enabled nvidia-persistenced.service 2>/dev/null || true)"
  else
    printf '  nvidia-persistenced.service: not present\n'
  fi
}

report_managed_laptop_power_files() {
  local path sentinel

  while IFS='|' read -r path sentinel; do
    [[ -n "$path" ]] || continue
    if managed_file_has_sentinel "$path" "$sentinel"; then
      printf '  managed file present: %s\n' "$path"
    elif [[ -e "$path" ]]; then
      printf '  unmanaged file at managed path: %s\n' "$path"
    else
      printf '  managed file absent: %s\n' "$path"
    fi
  done <<EOF
$LAPTOP_POWER_UDEV_RULE_PATH|$LAPTOP_POWER_UDEV_SENTINEL
$LAPTOP_RUNTIME_PM_MODPROBE_PATH|$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL
$NVIDIA_SUSPEND_MODPROBE_PATH|$NVIDIA_SUSPEND_MODPROBE_SENTINEL
EOF

  if [[ -e "$PRIME_RUN_PATH" ]]; then
    if prime_run_helper_is_managed; then
      printf '  script-owned prime-run helper present: %s\n' "$PRIME_RUN_PATH"
    else
      printf '  existing non-script prime-run helper present: %s\n' "$PRIME_RUN_PATH"
    fi
  else
    printf '  prime-run helper absent: %s\n' "$PRIME_RUN_PATH"
  fi

  if [[ -e "$NVIDIA_PERSISTENCED_MASK_MARKER" ]]; then
    printf '  managed nvidia-persistenced mask marker present: %s\n' "$NVIDIA_PERSISTENCED_MASK_MARKER"
  else
    printf '  managed nvidia-persistenced mask marker absent: %s\n' "$NVIDIA_PERSISTENCED_MASK_MARKER"
  fi
}

run_laptop_power_check_section() {
  local lspci_text report bdf sibling status
  local -a bdfs=()
  local -A seen=()

  printf '\nLaptop power policy diagnostics:\n'
  if command_exists lspci; then
    lspci_text="$(lspci_text_current)"
  else
    lspci_text=""
    printf '  lspci: unavailable\n'
  fi

  show_laptop_power_detection_reasons "$lspci_text"

  mapfile -t bdfs < <(nvidia_bdfs_from_lspci_text "$lspci_text")
  if ((${#bdfs[@]})); then
    printf '  NVIDIA BDFs:\n'
    printf '    - %s\n' "${bdfs[@]}"
  else
    printf '  NVIDIA BDFs: none detected\n'
  fi

  if command_exists nvidia-smi; then
    report="$(nvidia_smi_gpu_power_report || true)"
    if [[ -n "$report" ]]; then
      printf '  nvidia-smi display/persistence state:\n'
      printf '%s\n' "$report" | sed 's/^/    /'
    else
      printf '  nvidia-smi display/persistence state: unavailable\n'
    fi
  else
    printf '  nvidia-smi display/persistence state: nvidia-smi unavailable\n'
  fi

  report_nvidia_persistenced_state
  report_nvidia_dev_users
  report_nvidia_drm_and_display_diagnostics "${bdfs[@]}"

  if ((${#bdfs[@]})); then
    printf '  PCI runtime PM state:\n'
    for bdf in "${bdfs[@]}"; do
      while IFS= read -r sibling; do
        [[ -n "$sibling" ]] || continue
        [[ -z "${seen[$sibling]:-}" ]] || continue
        seen[$sibling]=1
        printf '    - %s power/control: %s\n' "$sibling" "$(pci_power_read "$sibling" control)"
        printf '      %s runtime_status: %s\n' "$sibling" "$(pci_power_read "$sibling" runtime_status)"
        printf '      %s runtime_suspended_time: %s\n' "$sibling" "$(pci_power_read "$sibling" runtime_suspended_time)"
      done < <(nvidia_sibling_bdfs_for_bdf "$bdf")
      status="$(runtime_d3_status_for_bdf "$bdf")"
      printf '    - %s NVIDIA Runtime D3: %s\n' "$bdf" "$status"
    done
  fi

  report_managed_laptop_power_files
  report_laptop_power_policy_conflicts
}

run_laptop_power_idle_probe() {
  local lspci_text bdf sibling before_status after_status before_time after_time delta
  local -a bdfs=()
  local -A before_status_by_bdf=()
  local -A before_time_by_bdf=()
  local -A seen=()
  local observed=0

  printf '\nLaptop power idle probe:\n'
  if ! command_exists lspci; then
    printf '  Cannot run idle probe: lspci unavailable.\n'
    return 0
  fi
  lspci_text="$(lspci_text_current)"
  mapfile -t bdfs < <(nvidia_bdfs_from_lspci_text "$lspci_text")
  if ((${#bdfs[@]} == 0)); then
    printf '  Cannot run idle probe: no NVIDIA BDFs detected.\n'
    return 0
  fi

  printf '  Reading sysfs runtime PM counters, waiting 60 seconds without invoking nvidia-smi, then reading sysfs again.\n'
  for bdf in "${bdfs[@]}"; do
    while IFS= read -r sibling; do
      [[ -n "$sibling" ]] || continue
      [[ -z "${seen[$sibling]:-}" ]] || continue
      seen[$sibling]=1
      before_status_by_bdf[$sibling]="$(pci_power_read "$sibling" runtime_status)"
      before_time_by_bdf[$sibling]="$(pci_power_read "$sibling" runtime_suspended_time)"
    done < <(nvidia_sibling_bdfs_for_bdf "$bdf")
  done

  sleep 60

  for sibling in "${!before_status_by_bdf[@]}"; do
    before_status="${before_status_by_bdf[$sibling]}"
    before_time="${before_time_by_bdf[$sibling]}"
    after_status="$(pci_power_read "$sibling" runtime_status)"
    after_time="$(pci_power_read "$sibling" runtime_suspended_time)"
    printf '  - %s runtime_status: %s -> %s\n' "$sibling" "$before_status" "$after_status"
    printf '    %s runtime_suspended_time: %s -> %s\n' "$sibling" "$before_time" "$after_time"
    if [[ "$after_status" == "suspended" ]]; then
      observed=1
    fi
    if [[ "$before_time" =~ ^[0-9]+$ && "$after_time" =~ ^[0-9]+$ ]]; then
      delta=$((after_time - before_time))
      printf '    %s runtime_suspended_time_delta: %s\n' "$sibling" "$delta"
      if (( delta > 0 )); then
        observed=1
      fi
    fi
  done

  if (( observed )); then
    printf '  Result: runtime PM idle progress observed.\n'
  else
    printf '  Result: runtime PM idle progress not observed during this 60-second window. Active clients, display wiring, persistence, or driver policy may be keeping the dGPU awake.\n'
    classify_laptop_power_idle_blockers /sys/bus/pci/devices /sys/class/drm /dev/dri "${bdfs[@]}"
  fi
}

check_result() {
  local description="$1"
  shift

  if "$@"; then
    printf 'PASS: %s\n' "$description"
    return 0
  fi

  printf 'FAIL: %s\n' "$description"
  return 1
}


loaded_nvidia_modules() {
  command_exists lsmod || return 1
  lsmod 2>/dev/null | awk '$1 ~ /^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm)$/ { found=1 } END { exit found ? 0 : 1 }'
}

dkms_status_output() {
  command_exists dkms || return 1
  dkms status 2>/dev/null || true
}

dkms_has_nvidia_entries() {
  local status
  command_exists dkms || return 1
  status="$(dkms_status_output)"
  grep -qi nvidia <<< "$status"
}

show_dkms_check_status() {
  local status

  if ! command_exists dkms; then
    printf 'WARN: dkms command is not installed\n'
    return 0
  fi

  status="$(dkms_status_output)"
  if grep -qi nvidia <<< "$status"; then
    printf 'PASS: dkms status has NVIDIA entries\n'
  else
    printf 'WARN: dkms status has no NVIDIA entries\n'
  fi
}

show_cuda_drivers_validation_status() {
  local smi_exists_status="$1"
  local smi_works_status="$2"
  local modinfo_status="$3"
  local modules_status="$4"
  local dkms_status="$5"

  if package_installed "$DEFAULT_DRIVER_PACKAGE"; then
    printf 'PASS: cuda-drivers package is installed\n'
    return 0
  fi

  if (( smi_exists_status == 0 && smi_works_status == 0 && modinfo_status == 0 )); then
    printf 'WARN: cuda-drivers package is not installed, but the NVIDIA driver is functional via nvidia-smi and modinfo. Treating cuda-drivers as provenance, not required functionality.\n'
    return 0
  fi

  if (( smi_works_status == 0 && modules_status == 0 )); then
    printf 'WARN: cuda-drivers package is not installed, but nvidia-smi communicates with loaded NVIDIA modules. Treating cuda-drivers as provenance, not required functionality.\n'
    return 0
  fi

  if (( modinfo_status == 0 && modules_status == 0 )); then
    printf 'WARN: cuda-drivers package is not installed, but modinfo and loaded NVIDIA modules show an installed NVIDIA driver. Treating cuda-drivers as provenance, not required functionality.\n'
    return 0
  fi

  if (( smi_works_status == 0 && dkms_status == 0 )); then
    printf 'WARN: cuda-drivers package is not installed, but nvidia-smi and DKMS NVIDIA entries show a working NVIDIA driver. Treating cuda-drivers as provenance, not required functionality.\n'
    return 0
  fi

  printf 'FAIL: cuda-drivers package is not installed and the NVIDIA driver is not demonstrably functional\n'
  return 1
}

show_check_context() {
  local dkms_status
  local lsmod_output

  printf '\nAPT policy summary:\n'
  apt-cache policy cuda-drivers nvidia-driver-pinning-580 nvidia-driver-pinning-470 2>/dev/null | sed 's/^/  /' || true

  if command_exists dkms; then
    printf '\nDKMS status entries containing nvidia:\n'
    dkms_status="$(dkms_status_output)"
    grep -i nvidia <<< "$dkms_status" | sed 's/^/  /' || printf '  none\n'
  fi

  if command_exists lsmod; then
    printf '\nLoaded NVIDIA modules:\n'
    lsmod_output="$(lsmod 2>/dev/null || true)"
    awk '$1 ~ /^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm)$/ { print "  " $0; found=1 } END { if (!found) print "  none" }' <<< "$lsmod_output"
  fi
}

nvidia_smi_works() {
  [[ -n "$NVIDIA_SMI_OUT" && -n "$NVIDIA_SMI_ERR" ]] || die "Internal error: NVIDIA_SMI_OUT and NVIDIA_SMI_ERR are unset."
  nvidia-smi >"$NVIDIA_SMI_OUT" 2>"$NVIDIA_SMI_ERR"
}

modinfo_nvidia_works() {
  [[ -n "$MODINFO_OUT" && -n "$MODINFO_ERR" ]] || die "Internal error: MODINFO_OUT and MODINFO_ERR are unset."
  modinfo nvidia >"$MODINFO_OUT" 2>"$MODINFO_ERR"
}

run_post_reboot_check() {
  local failures=0
  local check_tmp=""
  local smi_exists_status=1
  local smi_works_status=1
  local modinfo_status=1
  local modules_status=1
  local dkms_status=1

  check_tmp="$(mktemp -d)" || die "Could not create a temporary directory for validation output."
  trap 'rm -rf "$check_tmp"' RETURN

  NVIDIA_SMI_OUT="$check_tmp/nvidia-smi.out"
  NVIDIA_SMI_ERR="$check_tmp/nvidia-smi.err"
  MODINFO_OUT="$check_tmp/modinfo-nvidia.out"
  MODINFO_ERR="$check_tmp/modinfo-nvidia.err"

  log "Running NVIDIA driver validation checks."

  if check_result "nvidia-smi exists" command_exists nvidia-smi; then
    smi_exists_status=0
  else
    failures=$((failures + 1))
  fi

  if check_result "nvidia-smi can communicate with the driver" nvidia_smi_works; then
    smi_works_status=0
  else
    failures=$((failures + 1))
  fi

  if check_result "modinfo can read the nvidia kernel module" modinfo_nvidia_works; then
    modinfo_status=0
  else
    failures=$((failures + 1))
  fi

  if loaded_nvidia_modules; then
    modules_status=0
  fi
  if dkms_has_nvidia_entries; then
    dkms_status=0
  fi

  show_cuda_drivers_validation_status "$smi_exists_status" "$smi_works_status" "$modinfo_status" "$modules_status" "$dkms_status" || failures=$((failures + 1))
  show_dkms_check_status

  check_secure_boot
  show_check_context
  run_laptop_power_check_section
  if (( CHECK_LAPTOP_POWER_IDLE )); then
    run_laptop_power_idle_probe
  fi

  if (( failures )); then
    warn "Validation failed with $failures required check(s) failing."
    if [[ -n "$NVIDIA_SMI_ERR" && -s "$NVIDIA_SMI_ERR" ]]; then
      printf '\nnvidia-smi stderr:\n' >&2
      sed 's/^/  /' "$NVIDIA_SMI_ERR" >&2 || true
    fi
    if [[ -n "$MODINFO_ERR" && -s "$MODINFO_ERR" ]]; then
      printf '\nmodinfo stderr:\n' >&2
      sed 's/^/  /' "$MODINFO_ERR" >&2 || true
    fi
    exit 1
  fi

  log "Validation checks passed."
}

main() {
  validate_test_path_override_gate
  parse_args "$@"
  acquire_execution_lock

  if (( YOLO )); then
    warn "--yolo enabled: equivalent to --reset -y --allow-debian12-580-fallback --accept-cross-release-driver-packages --ignore-reset-blockers."
  fi

  require_root
  parse_os_release

  if (( CHECK_ONLY )); then
    run_post_reboot_check
    exit 0
  fi

  if (( REMOVE_ONLY )); then
    handle_remove_only
    exit 0
  fi

  preflight_dpkg_state

  if has_installed_driver_packages || nonpackaged_nvidia_runtime_present; then
    if (( ! RESET )); then
      show_detected_driver_packages
      show_runtime_traces
      if [[ "$LAPTOP_POWER_MODE" != "off" || "$ENABLE_NVIDIA_SUSPEND_SERVICES" -eq 1 ]]; then
        log "Existing NVIDIA driver state was detected. Skipping driver install/reset and evaluating only requested laptop power or suspend policy."
        if [[ "$LAPTOP_POWER_MODE" != "off" ]]; then
          maybe_configure_laptop_power_policy
        fi
        if (( ENABLE_NVIDIA_SUSPEND_SERVICES )); then
          configure_nvidia_suspend_services
        fi
        log "Policy-only run complete. Validate after reboot with: sudo ./$SCRIPT_NAME --check"
        exit 0
      fi
      log "Existing NVIDIA driver state was detected. No changes made."
      log "Run again with --reset to purge existing driver state and install freshly."
      exit 0
    fi
  fi

  disable_deprecated_debian12_fallback_source_if_present
  clear_existing_vendor_580_source_for_refresh

  ensure_nvidia_cuda_repo_configured
  verify_repo_preconditions
  apt_update
  install_detection_tools
  load_gpu_inventory
  show_gpu_inventory

  local branch
  branch="$(selected_driver_branch)"
  validate_branch_for_inventory "$branch"

  log "Selected NVIDIA driver branch policy: $branch"
  show_branch_guidance "$branch"
  prepare_debian12_580_fallback "$branch"
  preflight_install_plan "$branch"

  if has_installed_driver_packages || nonpackaged_nvidia_runtime_present; then
    show_detected_driver_packages
    show_runtime_traces
    reset_nvidia_driver_state
  fi

  check_nouveau
  check_secure_boot
  check_pinning_conflicts "$branch"
  install_headers
  install_driver_branch_pinning "$branch"
  install_driver

  maybe_configure_laptop_power_policy
  if (( ENABLE_NVIDIA_SUSPEND_SERVICES )); then
    configure_nvidia_suspend_services
  fi

  log "Install complete. Reboot the system before using the driver."
  log "After reboot, validate with: sudo ./$SCRIPT_NAME --check"
}

if [[ "${NVIDIA_CUDA_INSTALLER_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
