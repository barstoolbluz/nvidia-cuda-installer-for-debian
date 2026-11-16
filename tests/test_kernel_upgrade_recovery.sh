#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$test_dir/../nvidia-cuda-installer.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export NVIDIA_CUDA_INSTALLER_TEST_MODE=1
export NVIDIA_CUDA_INSTALLER_LOCK_FILE="$tmp/run/lock"
export NVIDIA_CUDA_INSTALLER_LEGACY_LOCK_FILE="$tmp/run/legacy.lock"
export NVIDIA_CUDA_INSTALLER_STATE_DIR="$tmp/state"
export NVIDIA_CUDA_INSTALLER_LAPTOP_POWER_UDEV_RULE_PATH="$tmp/etc/udev/rules.d/power.rules"
export NVIDIA_CUDA_INSTALLER_LAPTOP_RUNTIME_PM_MODPROBE_PATH="$tmp/etc/modprobe.d/pm.conf"
export NVIDIA_CUDA_INSTALLER_NVIDIA_SUSPEND_MODPROBE_PATH="$tmp/etc/modprobe.d/suspend.conf"
export NVIDIA_CUDA_INSTALLER_PRIME_RUN_PATH="$tmp/bin/prime-run"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_REPO_DIR="$tmp/repo"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_WORK_DIR="$tmp/vendor-work"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_SOURCE_FILE="$tmp/etc/apt/sources.list.d/vendor.list"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_PREF_FILE="$tmp/etc/apt/preferences.d/vendor.pref"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_KEYRING_PATH="$tmp/vendor.gpg"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_GNUPG_HOME="$tmp/gnupg"
export NVIDIA_CUDA_INSTALLER_MODPROBE_DIR="$tmp/etc/modprobe.d"
export NVIDIA_CUDA_INSTALLER_UDEV_RULES_DIR="$tmp/etc/udev/rules.d"

# The original installer is sourced, without root operations or any real probe.
NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1 source "$SCRIPT_UNDER_TEST"
trap - ERR
trap 'rm -rf "$tmp"' EXIT

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
assert_grep() { grep -Fq -- "$2" "$3" && ok "$1" || not_ok "$1: missing <$2> in $3"; }
assert_not_grep() { if [[ -f "$3" ]] && grep -Fq -- "$2" "$3"; then not_ok "$1: unexpected <$2> in $3"; else ok "$1"; fi; }
assert_file_absent() { [[ ! -e "$2" ]] && ok "$1" || not_ok "$1: unexpected $2"; }
assert_file_present() { [[ -e "$2" ]] && ok "$1" || not_ok "$1: missing $2"; }
assert_status() { [[ "$(cat "$2")" == "$3" ]] && ok "$1" || not_ok "$1: status $(cat "$2"), expected $3"; }

# Every simulated read and mutation is contained in CASE_ROOT. External commands
# are shell functions; accidental attempts to reach a real mutator fail the test.
new_case() {
  local name="$1" n
  CASE_ROOT="$tmp/cases/$name"
  mkdir -p "$CASE_ROOT"
  printf '%s\n' 580.173.02 > "$CASE_ROOT/version"
  printf 'nvidia/580.173.02, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
  cat > "$CASE_ROOT/grub.cfg" <<'GRUB'
submenu 'Advanced options for Debian GNU/Linux' $menuentry_id_option 'gnulinux-advanced' {
    menuentry 'Debian GNU/Linux, with Linux 6.12.94+deb13-amd64' --class debian {
    }
    menuentry 'Debian GNU/Linux, with Linux 6.12.94+deb13-amd64 (recovery mode)' {
    }
}
GRUB
  for (( n=1; n<=45; n++ )); do printf 'build log line %s\n' "$n"; done > "$CASE_ROOT/make.log"
}

# This function gets sourced inside a fresh subshell per scenario. It cannot
# see the host's driver state, packages, GRUB config, or kernel modules.
mock_host() {
  DRIVER_BRANCH=auto
  ASSUME_YES=0
  RESET=0
  REMOVE_ONLY=0
  REPAIR_KERNEL=0
  CHECK_ONLY=0
  DRY_RUN=0
  CHECK_LAPTOP_POWER_IDLE=0
  LAPTOP_POWER_MODE=off
  ENABLE_NVIDIA_SUSPEND_SERVICES=0
  RECOVERY_BUILD_FAILED=0
  RECOVERY_LAST_MODPROBE_ERROR=""
  kernel_running_version() { printf '%s\n' '6.12.117+deb13-amd64'; }
  dpkg() { [[ "$1" == --print-architecture ]] && printf 'amd64\n'; }
  parse_os_release() { :; }
  # Every case exercises the installation logic, not the EUID gate.
  # Lock tests use a test-only path and still take a real flock.
  require_root() { :; }
  preflight_dpkg_state() { :; }
  package_installed() {
    case "$1" in
      linux-headers-6.12.117+deb13-amd64) [[ -e "$CASE_ROOT/versioned.headers" ]] ;;
      linux-headers-amd64) [[ -e "$CASE_ROOT/meta.headers" ]] ;;
      nvidia-kernel-dkms|cuda-drivers|unattended-upgrades) return 0 ;;
      *) return 1 ;;
    esac
  }
  has_installed_driver_packages() { return 0; }
  installed_driver_packages() { printf 'nvidia-driver\nnvidia-kernel-dkms\n'; }
  installed_pinning_packages() {
    # Model the pin as an installed package, independently of the driver
    # version. An unpinned 580 source can belong to a Turing host.
    [[ -e "$CASE_ROOT/no-pinning" ]] && return 0
    [[ "$(cat "$CASE_ROOT/version")" == 580.* ]] && printf '%s\n' nvidia-driver-pinning-580 || true
  }
  nonpackaged_nvidia_runtime_present() { return 0; }
  package_candidate_exists() { [[ ! -e "$CASE_ROOT/missing-candidate.$1" ]]; }
  kernel_modinfo_running() { [[ -e "$CASE_ROOT/module.dkms" ]]; }
  kernel_nvidia_module_loaded() { [[ -e "$CASE_ROOT/module.loaded" ]]; }
  kernel_nvidia_loaded_version() {
    if [[ -e "$CASE_ROOT/loaded-version-differs" ]]; then
      printf '535.999.99\n'
    else
      cat "$CASE_ROOT/version"
    fi
  }
  kernel_modprobe_dry_run() { [[ -e "$CASE_ROOT/module.dkms" ]] && [[ ! -e "$CASE_ROOT/reject-probe" ]]; }
  dkms_status_output() {
    cat "$CASE_ROOT/older-dkms"
    if [[ -e "$CASE_ROOT/module.dkms" || -e "$CASE_ROOT/stale-status" ]]; then
      printf 'nvidia/%s, 6.12.117+deb13-amd64, x86_64: installed\n' "$(cat "$CASE_ROOT/version")"
    elif [[ -e "$CASE_ROOT/added" ]]; then
      printf 'nvidia/%s: added\n' "$(cat "$CASE_ROOT/version")"
    fi
  }
  nvidia_pci_lines() {
    if [[ -e "$CASE_ROOT/gpu-turing" ]]; then
      printf '0000:01:00.0 VGA compatible controller [0300]: NVIDIA TU102 [GeForce RTX 2080 Ti] [10de:1e04]\n'
    elif [[ -e "$CASE_ROOT/gpu-unknown" ]]; then
      printf '0000:01:00.0 VGA compatible controller [0300]: NVIDIA Unknown [10de:9999]\n'
    elif [[ -e "$CASE_ROOT/gpu-pascal" || "$(cat "$CASE_ROOT/version")" == 580.* ]]; then
      printf '0000:01:00.0 VGA compatible controller [0300]: NVIDIA GP102 [GeForce GTX 1080 Ti] [10de:1b06]\n'
    elif [[ -e "$CASE_ROOT/gpu-kepler" || "$(cat "$CASE_ROOT/version")" == 470.* ]]; then
      printf '0000:01:00.0 VGA compatible controller [0300]: NVIDIA GK110 [GeForce GTX 780 Ti] [10de:100a]\n'
    else
      printf '0000:01:00.0 VGA compatible controller [0300]: NVIDIA TU102 [GeForce RTX 2080 Ti] [10de:1e04]\n'
    fi
  }
  command_exists() {
    case "$1" in
      flock|dkms|modprobe|modinfo|lsmod|nvidia-smi|systemctl|mokutil|apt-cache|grub-reboot|apt-mark|update-initramfs|lspci|dmesg) return 0 ;;
      *) return 1 ;;
    esac
  }
  dkms() {
    printf 'dkms %s\n' "$(printf '%q ' "$@")" >> "$CASE_ROOT/calls"
    case "$1" in
      status) dkms_status_output ;;
      autoinstall)
        [[ ! -e "$CASE_ROOT/build-failure" ]] || { printf 'unsupported kernel header interface\n' >&2; return 10; }
        if [[ ! -e "$CASE_ROOT/autoinstall-noop" && ! -e "$CASE_ROOT/stale-status" ]]; then
          touch "$CASE_ROOT/module.dkms"
        fi
        if [[ -e "$CASE_ROOT/other-dkms-failure" ]]; then
          printf 'Unrelated DKMS module failed to build\n' >&2
          return 9
        fi
        ;;
      install)
        [[ ! -e "$CASE_ROOT/build-failure" ]] || return 11
        touch "$CASE_ROOT/module.dkms"
        if [[ -e "$CASE_ROOT/uvm-restores-on-force" && "${@: -1}" == --force ]]; then
          rm -f "$CASE_ROOT/uvm-missing"
        fi
        ;;
      *) printf 'unexpected dkms invocation\n' >&2; return 1 ;;
    esac
  }
  modprobe() {
    printf 'modprobe %s\n' "$(printf '%q ' "$@")" >> "$CASE_ROOT/calls"
    if [[ "$1" == --dry-run ]]; then
      [[ -e "$CASE_ROOT/module.dkms" ]] && [[ ! -e "$CASE_ROOT/reject-probe" ]]
      return $?
    fi
    if [[ -e "$CASE_ROOT/reject-load" ]]; then
      printf 'modprobe: ERROR: could not insert nvidia: Required key not available\n' >&2
      return 1
    fi
    if [[ -e "$CASE_ROOT/reject-eperm" ]]; then
      printf 'modprobe: ERROR: could not insert nvidia: Operation not permitted\n' >&2
      return 1
    fi
    if [[ "$1" == nvidia-drm && -e "$CASE_ROOT/reject-drm" ]]; then
      printf 'modprobe: ERROR: could not insert nvidia-drm: Invalid argument\n' >&2
      return 1
    fi
    if [[ "$1" == nvidia-uvm && -e "$CASE_ROOT/reject-uvm" ]]; then
      printf 'modprobe: ERROR: could not insert nvidia-uvm: Required key not available\n' >&2
      return 1
    fi
    [[ -e "$CASE_ROOT/module.dkms" ]] || return 1
    if [[ "$1" == nvidia-uvm ]]; then
      [[ ! -e "$CASE_ROOT/uvm-missing" && ! -e "$CASE_ROOT/no-accessories" ]] || return 1
      touch "$CASE_ROOT/uvm.loaded"
    fi
    [[ "$1" == nvidia ]] && touch "$CASE_ROOT/module.loaded"
    return 0
  }
  modinfo() {
    if [[ "$1" == -F && "$2" == version && "$3" == nvidia ]]; then
      [[ -e "$CASE_ROOT/module.dkms" ]] || return 1
      cat "$CASE_ROOT/version"
    elif [[ "$1" == -k && "$2" == '6.12.94+deb13-amd64' ]]; then
      printf 'modinfo -k %s\n' "$2" >> "$CASE_ROOT/fallback-reads"
      [[ ! -e "$CASE_ROOT/fallback-module-missing" ]] || return 1
      if [[ "${3:-}" == -F && "${4:-}" == version && "${5:-}" == nvidia* ]]; then
        if [[ "${5:-}" == nvidia-uvm && -e "$CASE_ROOT/fallback-uvm-missing" ]]; then
          return 1
        fi
        cat "$CASE_ROOT/version"
      elif [[ "${3:-}" == nvidia ]]; then
        printf 'filename: /mock/older/nvidia.ko\n'
      else
        return 1
      fi
    elif [[ "$1" == nvidia ]]; then
      [[ -e "$CASE_ROOT/module.dkms" ]] || return 1
      printf 'filename: /mock/nvidia.ko\n'
    elif [[ "$1" == nvidia-uvm ]]; then
      # UVM is mandatory for CUDA, even when the base driver and nvidia-smi work.
      [[ ! -e "$CASE_ROOT/uvm-missing" && ! -e "$CASE_ROOT/no-accessories" ]]
    else
      [[ ! -e "$CASE_ROOT/no-accessories" ]]
    fi
  }
  lsmod() {
    [[ ! -e "$CASE_ROOT/nouveau" ]] || printf 'nouveau 1 0\n'
    [[ ! -e "$CASE_ROOT/module.loaded" ]] || printf 'nvidia 1 0\n'
    [[ ! -e "$CASE_ROOT/uvm.loaded" ]] || printf 'nvidia_uvm 1 0\n'
  }
  nvidia-smi() {
    if [[ -e "$CASE_ROOT/version-mismatch" ]]; then
      printf 'Failed to initialize NVML: Driver/library version mismatch\n' >&2
      return 1
    fi
    if [[ -e "$CASE_ROOT/autoload-on-smi" && -e "$CASE_ROOT/module.dkms" && ! -e "$CASE_ROOT/reject-load" ]]; then
      # Real nvidia-smi can cause a module to be loaded by an existing service
      # or device access. Check should observe the final state after smi.
      touch "$CASE_ROOT/module.loaded"
      [[ ! -e "$CASE_ROOT/autoload-uvm-on-smi" ]] || touch "$CASE_ROOT/uvm.loaded"
    fi
    if [[ -e "$CASE_ROOT/module.loaded" ]]; then
      printf 'NVIDIA-SMI mock\n'
      return 0
    fi
    return 1
  }
  dmesg() {
    [[ -e "$CASE_ROOT/lockdown-log" ]] || return 0
    printf 'Lockdown: modprobe: unsigned module loading is restricted; see man kernel_lockdown.7\n'
  }
  mokutil() {
    [[ "$1" == --sb-state ]] || return 1
    if [[ -e "$CASE_ROOT/secure-boot" ]]; then
      printf 'SecureBoot enabled\n'
    else
      printf 'SecureBoot disabled\n'
    fi
  }
  systemctl() {
    case "$1" in
      is-enabled) [[ -e "$CASE_ROOT/persistenced-failed" ]] ;;
      is-failed) [[ -e "$CASE_ROOT/persistenced-failed" ]] ;;
      restart) printf 'systemctl %s\n' "$(printf '%q ' "$@")" >> "$CASE_ROOT/calls" ;;
      *) return 1 ;;
    esac
  }
  update-initramfs() { printf 'update-initramfs %s\n' "$(printf '%q ' "$@")" >> "$CASE_ROOT/calls"; }
  kernel_initramfs_includes_nvidia_drm() { [[ -e "$CASE_ROOT/initramfs-needs-drm" ]]; }
  run_apt_get() {
    printf 'apt-get %s\n' "$(printf '%q ' "$@")" >> "$CASE_ROOT/calls"
    if [[ "$1" != install ]]; then return 8; fi
    if [[ "${2:-}" == --reinstall && -e "$CASE_ROOT/reinstall-failure" ]]; then
      printf 'APT: NVIDIA DKMS package configuration returned exit status 10\n' >&2
      return 100
    fi
    if [[ -e "$CASE_ROOT/apt-headers-fail" ]]; then
      printf 'APT: DKMS hook returned error 10 while processing kernel headers\n' >&2
      return 100
    fi
    if [[ "${2:-}" == --only-upgrade && -e "$CASE_ROOT/upgrade-new-source" ]]; then
      printf '595.99.01\n' > "$CASE_ROOT/version"
      printf 'nvidia/595.99.01, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
      rm -f "$CASE_ROOT/build-failure"
    fi
    for arg in "$@"; do
      [[ "$arg" != linux-headers-6.12.117+deb13-amd64 ]] || touch "$CASE_ROOT/versioned.headers"
      [[ "$arg" != linux-headers-amd64 ]] || touch "$CASE_ROOT/meta.headers"
      if [[ "$arg" == --only-upgrade && -e "$CASE_ROOT/upgrade-fixes-dkms" ]]; then
        touch "$CASE_ROOT/module.dkms"
      fi
    done
  }
  installed_linux_image_packages() {
    printf 'linux-image-6.12.94+deb13-amd64\nlinux-image-6.12.101+deb13-amd64\nlinux-image-6.12.117+deb13-amd64\n'
  }
  recovery_grub_config_file() { printf '%s\n' "$CASE_ROOT/grub.cfg"; }
  recovery_kernel_boot_artifacts_present() {
    [[ ! -e "$CASE_ROOT/fallback-boot-artifacts-missing" ]]
  }
  recovery_dkms_make_log_path() { printf '%s\n' "$CASE_ROOT/make.log"; }
  grub-reboot() { printf 'grub-reboot %s\n' "$(printf '%q ' "$@")" >> "$CASE_ROOT/calls"; }
  apt-mark() { printf 'apt-mark %s\n' "$(printf '%q ' "$@")" >> "$CASE_ROOT/calls"; }
  run_laptop_power_check_section() { :; }
  maybe_configure_laptop_power_policy() { printf 'laptop-policy\n' >> "$CASE_ROOT/calls"; }
  check_secure_boot() { :; }
  apt-cache() { [[ "$1" != policy ]] || printf 'cuda-drivers: mock policy\n'; }
}

run_case() {
  local name="$1"
  shift
  local case_dir="$tmp/cases/$name"
  local output="$case_dir/output" status=0
  (
    CASE_ROOT="$case_dir"
    mock_host
    main "$@"
  ) > "$output" 2>&1 || status=$?
  printf '%s\n' "$status" > "$case_dir/status"
}

new_case auto-recovery
run_case auto-recovery -y
assert_status 'ordinary install recovers prior 580 DKMS state' "$CASE_ROOT/status" 0
assert_file_present 'versioned headers installed during recovery' "$CASE_ROOT/versioned.headers"
assert_file_present 'headers metapackage installed during recovery' "$CASE_ROOT/meta.headers"
assert_file_present 'DKMS module rebuilt for running kernel' "$CASE_ROOT/module.dkms"
assert_file_present 'running-kernel NVIDIA module loaded' "$CASE_ROOT/module.loaded"
assert_grep 'DKMS rebuilt for running kernel' 'dkms autoinstall -k 6.12.117+deb13-amd64' "$CASE_ROOT/calls"
assert_grep 'modprobe invoked' 'modprobe nvidia' "$CASE_ROOT/calls"
assert_grep 're-probe reports healthy state' 'Kernel recovery complete: healthy' "$CASE_ROOT/output"
assert_not_grep 'recovery never reports no changes' 'No changes made' "$CASE_ROOT/output"
assert_not_grep 'recovery never purges' 'purge' "$CASE_ROOT/calls"
original_call_count="$(wc -l < "$CASE_ROOT/calls")"
run_case auto-recovery -y
assert_status 'repeat install is successful' "$CASE_ROOT/status" 0
if [[ "$(wc -l < "$CASE_ROOT/calls")" == "$original_call_count" ]]; then
  ok 'repeat install performs no recovery mutations'
else
  not_ok 'repeat install ran mutators on a healthy installation'
fi
assert_grep 'repeat install acknowledges healthy state' 'No changes made' "$CASE_ROOT/output"

new_case dryrun
run_case dryrun --repair-kernel --dry-run -y
assert_status 'explicit recovery dry-run succeeds' "$CASE_ROOT/status" 0
assert_grep 'dry-run plans versioned and tracking headers' 'linux-headers-amd64' "$CASE_ROOT/output"
assert_grep 'dry-run plans DKMS autoinstall' 'dkms autoinstall -k' "$CASE_ROOT/output"
assert_grep 'dry-run explains fallback for added DKMS module' 'would run dkms install' "$CASE_ROOT/output"
assert_grep 'dry-run plans module load' 'modprobe nvidia' "$CASE_ROOT/output"
assert_grep 'dry-run plans validation' 'would re-probe' "$CASE_ROOT/output"
assert_file_absent 'dry-run never invokes any mutator' "$CASE_ROOT/calls"
assert_file_absent 'dry-run never creates headers' "$CASE_ROOT/versioned.headers"
assert_file_absent 'dry-run never builds module' "$CASE_ROOT/module.dkms"

new_case unrelated-dkms-failure
touch "$CASE_ROOT/other-dkms-failure"
run_case unrelated-dkms-failure --repair-kernel -y
assert_status 'another DKMS module failure cannot misclassify a successful NVIDIA rebuild' "$CASE_ROOT/status" 0
assert_file_present 'NVIDIA module is available despite unrelated DKMS failure' "$CASE_ROOT/module.loaded"
assert_not_grep 'already-installed NVIDIA module is not reinstalled' 'dkms install nvidia/' "$CASE_ROOT/calls"

new_case unrelated-dkms-failure-with-noop
touch "$CASE_ROOT/other-dkms-failure" "$CASE_ROOT/autoinstall-noop" "$CASE_ROOT/added"
run_case unrelated-dkms-failure-with-noop --repair-kernel -y
assert_status 'an unrelated autoinstall failure permits a targeted NVIDIA DKMS install' "$CASE_ROOT/status" 0
assert_grep 'targeted NVIDIA DKMS installation follows unrelated failure' 'dkms install nvidia/580.173.02 -k 6.12.117+deb13-amd64' "$CASE_ROOT/calls"

new_case autoinstall-noop
touch "$CASE_ROOT/autoinstall-noop" "$CASE_ROOT/added"
run_case autoinstall-noop --repair-kernel -y
assert_status 'added-state DKMS autoinstall no-op recovers via explicit install' "$CASE_ROOT/status" 0
assert_grep 'fallback dkms install invoked' 'dkms install nvidia/580.173.02 -k 6.12.117+deb13-amd64' "$CASE_ROOT/calls"

new_case stale-dkms-installed
# DKMS says "installed" but the module file is absent; force re-install it.
touch "$CASE_ROOT/stale-status" "$CASE_ROOT/autoinstall-noop"
run_case stale-dkms-installed --repair-kernel -y
assert_status 'stale DKMS installed status is repairable' "$CASE_ROOT/status" 0
assert_grep 'stale DKMS forces reinstallation of existing module' 'dkms install nvidia/580.173.02 -k 6.12.117+deb13-amd64 --force' "$CASE_ROOT/calls"

new_case legacy-build-fails
touch "$CASE_ROOT/build-failure"
run_case legacy-build-fails --repair-kernel
assert_status 'legacy DKMS incompatibility returns distinct exit 3' "$CASE_ROOT/status" 3
assert_grep 'failed build prints log tail' 'build log line 45' "$CASE_ROOT/output"
if grep -Fxq 'build log line 1' "$CASE_ROOT/output"; then not_ok 'failed build prints more than last 40 lines'; else ok 'failed build limits output to last 40 lines'; fi
assert_grep 'fallback names installed working kernel' '6.12.94+deb13-amd64' "$CASE_ROOT/output"
assert_grep 'fallback names actual GRUB entry' 'Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux 6.12.94+deb13-amd64' "$CASE_ROOT/output"
assert_grep 'fallback includes one-shot command' 'sudo grub-reboot' "$CASE_ROOT/output"
assert_not_grep 'legacy failure never upgrades driver' 'cuda-drivers' "$CASE_ROOT/calls"
assert_not_grep 'legacy failure never purges driver' 'purge' "$CASE_ROOT/calls"
assert_not_grep 'unconfirmed recovery never changes boot selection' 'grub-reboot' "$CASE_ROOT/calls"
assert_not_grep 'unconfirmed recovery never holds metapackage' 'apt-mark' "$CASE_ROOT/calls"

new_case legacy-fallback-approved
touch "$CASE_ROOT/build-failure"
run_case legacy-fallback-approved --repair-kernel -y
assert_status 'approved fallback still returns exit 3 until boot' "$CASE_ROOT/status" 3
assert_grep 'approved fallback schedules boot from exact GRUB entry' 'grub-reboot Advanced\ options\ for\ Debian\ GNU/Linux' "$CASE_ROOT/calls"
assert_grep 'approved fallback holds kernel metapackage' 'apt-mark hold linux-image-amd64' "$CASE_ROOT/calls"

new_case modern-build-fails
printf '595.42.02\n' > "$CASE_ROOT/version"
printf 'nvidia/595.42.02, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
touch "$CASE_ROOT/build-failure" "$CASE_ROOT/upgrade-fixes-dkms"
run_case modern-build-fails --repair-kernel -y
assert_status 'modern DKMS failure can recover through consented upgrade' "$CASE_ROOT/status" 0
assert_not_grep 'modern recovery does not reinstall incompatible old DKMS source before upgrade' 'apt-get install --reinstall nvidia-kernel-dkms' "$CASE_ROOT/calls"
assert_grep 'modern path upgrades existing cuda-drivers' 'apt-get install --only-upgrade cuda-drivers' "$CASE_ROOT/calls"
assert_not_grep 'modern path never purges' 'purge' "$CASE_ROOT/calls"

new_case modern-declined
printf '595.42.02\n' > "$CASE_ROOT/version"
printf 'nvidia/595.42.02, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
touch "$CASE_ROOT/build-failure"
run_case modern-declined --repair-kernel
assert_status 'unapproved modern recovery returns code 3' "$CASE_ROOT/status" 3
assert_not_grep 'modern upgrade not attempted without consent' '--reinstall' "$CASE_ROOT/calls"

new_case legacy-470-build-fails
printf '470.256.02\n' > "$CASE_ROOT/version"
printf 'nvidia/470.256.02, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
touch "$CASE_ROOT/build-failure"
run_case legacy-470-build-fails --repair-kernel -y
assert_status '470 legacy failure returns code 3 after offering older kernel' "$CASE_ROOT/status" 3
assert_not_grep '470 legacy branch never attempts a current driver upgrade' '--only-upgrade cuda-drivers' "$CASE_ROOT/calls"
assert_not_grep '470 legacy branch never reinstalls modern source' '--reinstall' "$CASE_ROOT/calls"

new_case no-header-candidate
touch "$CASE_ROOT/missing-candidate.linux-headers-6.12.117+deb13-amd64"
run_case no-header-candidate --repair-kernel
assert_status 'unavailable kernel header candidate yields fallback exit 3' "$CASE_ROOT/status" 3
assert_grep 'unavailable candidate named' 'No APT candidate for linux-headers-6.12.117+deb13-amd64' "$CASE_ROOT/output"
assert_not_grep 'cannot build without headers' 'dkms autoinstall' "$CASE_ROOT/calls"

new_case apt-header-hook-failure
touch "$CASE_ROOT/apt-headers-fail"
run_case apt-header-hook-failure --repair-kernel
assert_status 'APT header-hook failure gives nonrepairable exit 3' "$CASE_ROOT/status" 3
assert_grep 'APT hook failure is reported explicitly' 'APT header installation failed' "$CASE_ROOT/output"
assert_grep 'APT hook failure includes DKMS log tail' 'build log line 45' "$CASE_ROOT/output"
assert_not_grep 'failed APT header install never proceeds to manual DKMS' 'dkms autoinstall' "$CASE_ROOT/calls"

new_case no-grub-config
touch "$CASE_ROOT/build-failure"
rm -f "$CASE_ROOT/grub.cfg"
run_case no-grub-config --repair-kernel -y
assert_status 'non-GRUB fallback returns distinct failure' "$CASE_ROOT/status" 3
assert_grep 'missing GRUB entry gives manual boot advice' 'select this kernel manually' "$CASE_ROOT/output"
assert_not_grep 'missing GRUB entry never writes a one-shot boot' 'grub-reboot' "$CASE_ROOT/calls"

new_case check-missing
rm -f -- "$NVIDIA_CUDA_INSTALLER_LOCK_FILE"
run_case check-missing --check
assert_status 'check correctly fails on incident host' "$CASE_ROOT/status" 1
assert_grep 'check exposes shared probe state' 'module-missing-for-running-kernel (headers-missing)' "$CASE_ROOT/output"
assert_grep 'check prints exact repair invocation' 'sudo ./nvidia-cuda-installer.sh --repair-kernel' "$CASE_ROOT/output"
assert_grep 'check warns about missing tracking metapackage' 'WARN: linux-headers-amd64 is not installed' "$CASE_ROOT/output"
assert_file_absent 'check never creates global lock' "$NVIDIA_CUDA_INSTALLER_LOCK_FILE"

new_case check-followed-by-root
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/uvm.loaded" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers"
(
  CASE_ROOT="$CASE_ROOT"
  mock_host
  installer_is_root() { return 1; }
  main --check
) > "$CASE_ROOT/nonroot-check.out" 2>&1
assert_grep 'non-root check succeeds unlocked' 'running without an execution lock' "$CASE_ROOT/nonroot-check.out"
run_case check-followed-by-root -y
assert_status 'root install after non-root check succeeds' "$CASE_ROOT/status" 0
assert_file_present 'root install now creates safe global lock' "$NVIDIA_CUDA_INSTALLER_LOCK_FILE"
assert_not_grep 'root install after check cannot fail on protected_regular' 'Permission denied' "$CASE_ROOT/output"

new_case foreign-legacy-lock
mkdir -p "$tmp/run"
printf 'other user lock\n' > "$NVIDIA_CUDA_INSTALLER_LEGACY_LOCK_FILE"
(
  CASE_ROOT="$CASE_ROOT"
  mock_host
  stat() {
    if [[ "${*: -1}" == "$NVIDIA_CUDA_INSTALLER_LEGACY_LOCK_FILE" ]]; then
      if [[ "$*" == *'%u'* ]]; then printf '1000\n'; else printf 'someuser\n'; fi
    else
      command stat "$@"
    fi
  }
  acquire_execution_lock
) > "$CASE_ROOT/output" 2>&1
assert_grep 'foreign legacy lock reports simulated owner' 'someuser' "$CASE_ROOT/output"
assert_grep 'foreign legacy lock explains protected_regular' 'fs.protected_regular=2' "$CASE_ROOT/output"
assert_file_present 'foreign legacy lock never removed' "$NVIDIA_CUDA_INSTALLER_LEGACY_LOCK_FILE"

new_case secure-boot-rejects
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/reject-probe" "$CASE_ROOT/reject-load" "$CASE_ROOT/secure-boot"
run_case secure-boot-rejects --repair-kernel
assert_status 'signature rejection prevents false healthy verdict' "$CASE_ROOT/status" 3
assert_grep 'Secure Boot explains local MOK signing' '/var/lib/dkms/mok.key' "$CASE_ROOT/output"
assert_grep 'Secure Boot explains reboot and MokManager' 'MokManager' "$CASE_ROOT/output"
assert_not_grep 'Secure Boot recovery does not enroll keys' 'mokutil --import' "$CASE_ROOT/output"

new_case modern-load-fails-after-upgrade
printf '595.42.02\n' > "$CASE_ROOT/version"
printf 'nvidia/595.42.02, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
touch "$CASE_ROOT/build-failure" "$CASE_ROOT/upgrade-fixes-dkms" "$CASE_ROOT/reject-load"
run_case modern-load-fails-after-upgrade --repair-kernel -y
assert_status 'modern upgrade with load failure returns 3' "$CASE_ROOT/status" 3
if [[ "$(grep -Fc 'grub-reboot ' "$CASE_ROOT/calls" || true)" == 1 ]]; then
  ok 'modern failure schedules fallback only once'
else
  not_ok 'modern failure scheduled fallback more than once'
fi
if [[ "$(grep -Fc 'DKMS failed for' "$CASE_ROOT/output" || true)" == 1 ]]; then
  ok 'modern path reports original DKMS failure only once'
else
  not_ok 'modern path mislabeled a module-load failure as a DKMS error'
fi

new_case healthy-meta-missing
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/uvm.loaded" "$CASE_ROOT/versioned.headers"
run_case healthy-meta-missing --repair-kernel -y
assert_status 'explicit repair installs missing future-header tracking even if driver healthy' "$CASE_ROOT/status" 0
assert_file_present 'explicit repair installed missing metapackage' "$CASE_ROOT/meta.headers"
assert_not_grep 'healthy repair does not rebuild DKMS' 'dkms autoinstall' "$CASE_ROOT/calls"

new_case automatic-tracking-install
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/uvm.loaded" "$CASE_ROOT/versioned.headers"
run_case automatic-tracking-install -y
assert_status 'automatic rerun installs absent metapackage proactively' "$CASE_ROOT/status" 0
assert_file_present 'healthy driver gets header tracking' "$CASE_ROOT/meta.headers"
assert_not_grep 'proactive header tracking avoids redundant DKMS build' 'dkms autoinstall' "$CASE_ROOT/calls"

new_case initramfs-required
touch "$CASE_ROOT/persistenced-failed" "$CASE_ROOT/initramfs-needs-drm"
run_case initramfs-required --repair-kernel -y
assert_status 'optional service and initramfs steps preserve success' "$CASE_ROOT/status" 0
assert_grep 'failed enabled persistence service restarted' 'systemctl restart nvidia-persistenced.service' "$CASE_ROOT/calls"
assert_grep 'nvidia-drm initramfs refreshed for current kernel' 'update-initramfs -u -k 6.12.117+deb13-amd64' "$CASE_ROOT/calls"

# Validation of the actual probe wrappers, without overriding the probe itself.
new_case fresh-install-headers
(
  CASE_ROOT="$CASE_ROOT"
  mock_host
  pinning_package_for_branch() { :; }
  apt-get() { printf '%s\n' "$(printf '%q ' "$@")" > "$CASE_ROOT/preflight.calls"; }
  preflight_install_plan current
  install_headers
) > "$CASE_ROOT/output" 2>&1
assert_grep 'fresh-install preflight simulates running headers and tracking meta' 'linux-headers-6.12.117+deb13-amd64 linux-headers-amd64 cuda-drivers' "$CASE_ROOT/preflight.calls"
assert_grep 'fresh install includes header tracking meta' 'apt-get install linux-headers-6.12.117+deb13-amd64 linux-headers-amd64' "$CASE_ROOT/calls"

new_case direct-modprobe-wrapper
(
  command_exists() { [[ "$1" == modprobe ]]; }
  modprobe() {
    printf '%s\n' "$(printf '%q ' "$@")" > "$CASE_ROOT/probe-call"
    [[ "$1" == --dry-run && "$2" == nvidia ]]
  }
  kernel_modprobe_dry_run
) && ok 'modprobe probe is a dry-run only' || not_ok 'modprobe probe was not dry-run'
assert_grep 'direct modprobe probe invokes correct arguments' '--dry-run nvidia' "$CASE_ROOT/probe-call"

new_case direct-probe
(
  CASE_ROOT="$CASE_ROOT"
  mock_host
  package_installed() { return 1; }
  modinfo() { return 1; }
  kernel_modinfo_running() { command_exists modinfo && modinfo nvidia >/dev/null 2>&1; }
  kernel_nvidia_module_loaded() { return 1; }
  probe_nvidia_kernel_state
  [[ "$KERNEL_PROBE_STATE" == module-missing-for-running-kernel && "$KERNEL_PROBE_HEADERS" == headers-missing ]]
) && ok 'probe reports missing module and missing versioned headers together' || not_ok 'probe combined state incorrect'

new_case root-owned-legacy-lock
printf 'legacy root-owned placeholder\n' > "$NVIDIA_CUDA_INSTALLER_LEGACY_LOCK_FILE"
(
  CASE_ROOT="$CASE_ROOT"
  mock_host
  stat() {
    if [[ "${*: -1}" == "$NVIDIA_CUDA_INSTALLER_LEGACY_LOCK_FILE" ]]; then
      if [[ "$*" == *'%u'* ]]; then printf '0\n'; else printf 'root\n'; fi
    else
      command stat "$@"
    fi
  }
  acquire_execution_lock
) > "$CASE_ROOT/output" 2>&1
assert_file_absent 'unlocked root-owned legacy lock retired safely' "$NVIDIA_CUDA_INSTALLER_LEGACY_LOCK_FILE"

new_case alternate-architecture
(
  dpkg() { [[ "$1" == --print-architecture ]] && printf 'arm64\n'; }
  [[ "$(kernel_headers_meta_package)" == linux-headers-arm64 ]]
) && ok 'arm64 retains architecture-specific tracking header support' || not_ok 'arm64 metapackage selection failed'

new_case nonroot-with-root-lock
# The earlier root process left a file in the test-only root lock directory.
mkdir -p "$(dirname "$NVIDIA_CUDA_INSTALLER_LOCK_FILE")"
: > "$NVIDIA_CUDA_INSTALLER_LOCK_FILE"
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/uvm.loaded" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers"
(
  CASE_ROOT="$CASE_ROOT"
  mock_host
  installer_is_root() { return 1; }
  main --check
) > "$CASE_ROOT/output" 2>&1
assert_grep 'non-root --check tolerates existing root lock' 'Validation checks passed' "$CASE_ROOT/output"


# Audit defect 1: modprobe --dry-run cannot prove an unsigned module will load.
new_case secure-boot-dryrun-succeeds-load-fails
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/secure-boot" "$CASE_ROOT/reject-load"
run_case secure-boot-dryrun-succeeds-load-fails --repair-kernel -y
assert_status 'Secure Boot insertion failure cannot produce successful recovery' "$CASE_ROOT/status" 3
assert_grep 'recovery tests actual insertion when dry-run succeeds' 'modprobe nvidia' "$CASE_ROOT/calls"
assert_grep 'actual Secure Boot rejection produces MOK diagnostic' 'MokManager' "$CASE_ROOT/output"
run_case secure-boot-dryrun-succeeds-load-fails --check
assert_status 'check cannot certify an unloaded untested module' "$CASE_ROOT/status" 1
assert_grep 'read-only check names unverified module load' 'module-present-load-unverified' "$CASE_ROOT/output"

new_case check-observes-module-autoload
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/autoload-on-smi" "$CASE_ROOT/autoload-uvm-on-smi"
run_case check-observes-module-autoload --check
assert_status 'check recognizes module loaded during nvidia-smi validation' "$CASE_ROOT/status" 0
assert_grep 'final check state reflects successful module auto-load' 'Kernel convergence state: healthy' "$CASE_ROOT/output"
assert_not_grep 'successful module auto-load does not report unverified failure' 'not been verified healthy' "$CASE_ROOT/output"

new_case check-autoloads-only-base-module
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/autoload-on-smi"
run_case check-autoloads-only-base-module --check
assert_status 'nvidia-smi loading only the base driver does not prove UVM readiness' "$CASE_ROOT/status" 1
assert_grep 'base-only autoload is correctly classified as unverified CUDA' 'module-present-load-unverified' "$CASE_ROOT/output"
assert_file_absent 'base-only autoload check does not attempt UVM insertion' "$CASE_ROOT/calls"

new_case module-load-unverified-dryrun
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/secure-boot" "$CASE_ROOT/reject-load"
run_case module-load-unverified-dryrun --repair-kernel --dry-run -y
assert_status 'unverified module dry-run is a successful plan without claiming health' "$CASE_ROOT/status" 0
assert_grep 'unverified module dry-run plans real insertion' 'would run modprobe nvidia' "$CASE_ROOT/output"
assert_file_absent 'unverified module dry-run does not call mutators' "$CASE_ROOT/calls"

new_case loaded-module-version-stale
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/loaded-version-differs"
run_case loaded-module-version-stale --repair-kernel -y
assert_status 'loaded module with stale on-disk driver version is not healthy' "$CASE_ROOT/status" 3
assert_grep 'stale loaded module is identified' 'loaded NVIDIA module version' "$CASE_ROOT/output"
assert_not_grep 'stale loaded module requests a reboot, not fallback to an older kernel' 'grub-reboot ' "$CASE_ROOT/calls"
run_case loaded-module-version-stale --check
assert_status 'check fails on a loaded-vs-disk module version mismatch' "$CASE_ROOT/status" 1
assert_not_grep 'check cannot report healthy on stale loaded NVIDIA module' 'Kernel convergence state: healthy' "$CASE_ROOT/output"

new_case loaded-userspace-mismatch
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/version-mismatch"
run_case loaded-userspace-mismatch --repair-kernel -y
assert_status 'loaded module with NVML driver/library mismatch is not healthy' "$CASE_ROOT/status" 3
assert_grep 'NVML mismatch is diagnosed' 'driver/library version mismatch' "$CASE_ROOT/output"
assert_not_grep 'NVML mismatch does not schedule an unrelated older kernel' 'grub-reboot ' "$CASE_ROOT/calls"

# Audit defect 2: a previous older branch must never authorize a current upgrade on Pascal/Kepler.
new_case pascal-old-535-driver
printf '535.183.01\n' > "$CASE_ROOT/version"
printf 'nvidia/535.183.01, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
touch "$CASE_ROOT/gpu-pascal" "$CASE_ROOT/build-failure" "$CASE_ROOT/upgrade-fixes-dkms"
run_case pascal-old-535-driver --repair-kernel -y
assert_status 'Pascal old 535 DKMS failure does not claim modern recovery' "$CASE_ROOT/status" 3
assert_not_grep 'Pascal cannot trigger incompatible current branch upgrade' '--only-upgrade cuda-drivers' "$CASE_ROOT/calls"
assert_not_grep 'Pascal old DKMS source is not reinstalled as modern' '--reinstall nvidia-kernel-dkms' "$CASE_ROOT/calls"

new_case kepler-old-390-driver
printf '390.157\n' > "$CASE_ROOT/version"
printf 'nvidia/390.157, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
touch "$CASE_ROOT/gpu-kepler" "$CASE_ROOT/build-failure" "$CASE_ROOT/upgrade-fixes-dkms"
run_case kepler-old-390-driver --repair-kernel -y
assert_status 'Kepler old 390 DKMS failure does not claim modern recovery' "$CASE_ROOT/status" 3
assert_not_grep 'Kepler cannot trigger incompatible current branch upgrade' '--only-upgrade cuda-drivers' "$CASE_ROOT/calls"

new_case unknown-gpu-no-auto-upgrade
printf '595.42.02\n' > "$CASE_ROOT/version"
printf 'nvidia/595.42.02, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
touch "$CASE_ROOT/gpu-unknown" "$CASE_ROOT/build-failure" "$CASE_ROOT/upgrade-fixes-dkms"
run_case unknown-gpu-no-auto-upgrade --repair-kernel -y
assert_status 'unknown GPU cannot be silently moved to current branch' "$CASE_ROOT/status" 3
assert_not_grep 'unknown GPU suppresses modern upgrade' '--only-upgrade cuda-drivers' "$CASE_ROOT/calls"

# Audit defect 3: DKMS status alone cannot establish a bootable, usable fallback.
new_case stale-fallback-module
touch "$CASE_ROOT/build-failure" "$CASE_ROOT/fallback-module-missing"
run_case stale-fallback-module --repair-kernel -y
assert_status 'stale fallback DKMS record returns non-recoverable status' "$CASE_ROOT/status" 3
assert_file_present 'fallback module lookup is attempted' "$CASE_ROOT/fallback-reads"
assert_not_grep 'fallback lacking an on-disk NVIDIA module is not scheduled' 'grub-reboot ' "$CASE_ROOT/calls"
assert_not_grep 'fallback lacking a module is not advertised as verified' 'One-shot command:' "$CASE_ROOT/output"

new_case stale-fallback-boot-artifacts
touch "$CASE_ROOT/build-failure" "$CASE_ROOT/fallback-boot-artifacts-missing"
run_case stale-fallback-boot-artifacts --repair-kernel -y
assert_status 'fallback with missing kernel boot artifacts exits 3' "$CASE_ROOT/status" 3
assert_not_grep 'fallback with missing boot artifacts is not scheduled' 'grub-reboot ' "$CASE_ROOT/calls"

# Audit defect 4: reinstalling old, incompatible DKMS must not block the available upgrade.
new_case modern-incompatible-reinstall-fails
printf '595.42.02\n' > "$CASE_ROOT/version"
printf 'nvidia/595.42.02, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
touch "$CASE_ROOT/build-failure" "$CASE_ROOT/reinstall-failure" "$CASE_ROOT/upgrade-fixes-dkms"
run_case modern-incompatible-reinstall-fails --repair-kernel -y
assert_status 'modern consented upgrade reaches compatible source despite old reinstall failure' "$CASE_ROOT/status" 0
assert_grep 'modern path performs candidate upgrade without aborting on old DKMS' '--only-upgrade cuda-drivers' "$CASE_ROOT/calls"

new_case modern-candidate-replaces-dkms-source
printf '595.42.02\n' > "$CASE_ROOT/version"
printf 'nvidia/595.42.02, 6.12.94+deb13-amd64, x86_64: installed\n' > "$CASE_ROOT/older-dkms"
touch "$CASE_ROOT/build-failure" "$CASE_ROOT/upgrade-new-source"
run_case modern-candidate-replaces-dkms-source --repair-kernel -y
assert_status 'modern upgrade builds its newly installed DKMS source' "$CASE_ROOT/status" 0
assert_grep 'new DKMS source version was used' 'nvidia/595.99.01' "$CASE_ROOT/output"
assert_grep 'post-upgrade DKMS autoinstall runs against current kernel' 'dkms autoinstall -k 6.12.117+deb13-amd64' "$CASE_ROOT/calls"
assert_not_grep 'modern upgrade does not first reinstall incompatible source' '--reinstall nvidia-kernel-dkms' "$CASE_ROOT/calls"

# Audit defect 5: headless CUDA can be usable when optional NVIDIA DRM fails to load.
new_case headless-optional-drm-failure
touch "$CASE_ROOT/reject-drm"
run_case headless-optional-drm-failure --repair-kernel -y
assert_status 'failed optional DRM module does not invalidate working CUDA core' "$CASE_ROOT/status" 0
assert_file_present 'base module remains loaded despite DRM failure' "$CASE_ROOT/module.loaded"
assert_grep 'optional DRM failure remains visible' 'Optional NVIDIA module nvidia-drm could not be loaded' "$CASE_ROOT/output"
assert_not_grep 'working CUDA does not trigger GRUB fallback' 'grub-reboot ' "$CASE_ROOT/calls"
original_optional_call_count="$(wc -l < "$CASE_ROOT/calls")"
run_case headless-optional-drm-failure --repair-kernel -y
assert_status 'working CUDA with optional DRM failure converges idempotently' "$CASE_ROOT/status" 0
if [[ "$(wc -l < "$CASE_ROOT/calls")" == "$original_optional_call_count" ]]; then
  ok 'optional DRM failure is not retried unnecessarily after healthy convergence'
else
  not_ok 'healthy driver repeated module mutations after an optional DRM failure'
fi

new_case explicitly-required-drm-failure
touch "$CASE_ROOT/reject-drm" "$CASE_ROOT/initramfs-needs-drm"
run_case explicitly-required-drm-failure --repair-kernel -y
assert_status 'explicit initramfs NVIDIA DRM requirement makes failed DRM load fatal' "$CASE_ROOT/status" 3

# Audit defect 6: EPERM with kernel lockdown evidence requires MOK diagnostics.
new_case secure-boot-lockdown-eperm
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/secure-boot" "$CASE_ROOT/reject-eperm" "$CASE_ROOT/lockdown-log"
run_case secure-boot-lockdown-eperm --repair-kernel
assert_status 'Secure Boot lockdown EPERM reports nonrepairable status' "$CASE_ROOT/status" 3
assert_grep 'kernel lockdown evidence produces MOK signing guidance' '/var/lib/dkms/mok.key' "$CASE_ROOT/output"
assert_grep 'lockdown EPERM names MokManager' 'MokManager' "$CASE_ROOT/output"

new_case unrelated-eperm-without-lockdown
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/secure-boot" "$CASE_ROOT/reject-eperm"
run_case unrelated-eperm-without-lockdown --repair-kernel
assert_status 'unrelated EPERM still fails recovery' "$CASE_ROOT/status" 3
assert_not_grep 'unrelated EPERM is not diagnosed as signature failure' 'MokManager' "$CASE_ROOT/output"

# Second-pass defect 1: the CUDA UVM module is required even when the base
# driver and NVIDIA userspace are usable. The check remains nonmutating.
new_case missing-uvm-loaded
 touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/uvm-missing" "$CASE_ROOT/build-failure"
run_case missing-uvm-loaded --check
assert_status 'CUDA validation fails when UVM is absent despite working nvidia-smi' "$CASE_ROOT/status" 1
assert_grep 'missing UVM is named in the convergence diagnosis' 'nvidia-uvm' "$CASE_ROOT/output"
assert_grep 'missing UVM check recommends kernel recovery' 'sudo ./nvidia-cuda-installer.sh --repair-kernel' "$CASE_ROOT/output"
assert_grep 'nvidia-smi success alone is insufficient for CUDA UVM health' 'PASS: nvidia-smi can communicate with the driver' "$CASE_ROOT/output"
assert_file_absent 'missing UVM check does not mutate DKMS' "$CASE_ROOT/calls"
run_case missing-uvm-loaded --repair-kernel -y
assert_status 'missing UVM with failed DKMS rebuild cannot report recovery success' "$CASE_ROOT/status" 3
assert_not_grep 'missing UVM cannot be declared healthy by loaded base driver' 'Kernel recovery complete: healthy' "$CASE_ROOT/output"
assert_grep 'missing UVM triggers an attempted DKMS repair' 'dkms autoinstall -k 6.12.117+deb13-amd64' "$CASE_ROOT/calls"

new_case missing-uvm-repairable
 touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/uvm-missing" "$CASE_ROOT/uvm-restores-on-force"
run_case missing-uvm-repairable --repair-kernel -y
assert_status 'forced reinstall can restore missing required UVM and recover' "$CASE_ROOT/status" 0
assert_file_absent 'DKMS force restores missing UVM module file' "$CASE_ROOT/uvm-missing"
assert_grep 'stale DKMS installed record is force repaired for missing UVM' 'dkms install nvidia/580.173.02 -k 6.12.117+deb13-amd64 --force' "$CASE_ROOT/calls"
assert_grep 'restored CUDA UVM is actually loaded' 'modprobe nvidia-uvm' "$CASE_ROOT/calls"

new_case missing-uvm-dryrun
 touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/uvm-missing"
run_case missing-uvm-dryrun --repair-kernel --dry-run -y
assert_status 'dry-run can plan required UVM repair without changing modules' "$CASE_ROOT/status" 0
assert_grep 'missing UVM dry-run plans DKMS rebuild' 'would run dkms autoinstall -k' "$CASE_ROOT/output"
assert_grep 'missing UVM dry-run includes UVM insertion' 'would run modprobe nvidia-uvm' "$CASE_ROOT/output"
assert_grep 'missing UVM dry-run discloses conditional forced DKMS reinstall' 'dkms install nvidia/580.173.02 -k 6.12.117+deb13-amd64 --force' "$CASE_ROOT/output"
assert_file_absent 'missing UVM dry-run does not call mutators' "$CASE_ROOT/calls"

new_case automatic-missing-uvm-repair
 touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/uvm-missing" "$CASE_ROOT/uvm-restores-on-force"
run_case automatic-missing-uvm-repair -y
assert_status 'plain installer also repairs a missing UVM module' "$CASE_ROOT/status" 0
assert_grep 'plain installer starts recovery despite working base driver' 'Repairing the running-kernel NVIDIA module' "$CASE_ROOT/output"
assert_grep 'automatic recovery forces missing UVM reinstall' 'dkms install nvidia/580.173.02 -k 6.12.117+deb13-amd64 --force' "$CASE_ROOT/calls"

new_case stale-fallback-uvm
 touch "$CASE_ROOT/build-failure" "$CASE_ROOT/fallback-uvm-missing"
run_case stale-fallback-uvm --repair-kernel -y
assert_status 'fallback with only base NVIDIA and no UVM exits 3' "$CASE_ROOT/status" 3
assert_not_grep 'fallback lacking UVM cannot schedule a CUDA recovery boot' 'grub-reboot ' "$CASE_ROOT/calls"
assert_not_grep 'fallback lacking UVM is not advertised as verified' 'One-shot command:' "$CASE_ROOT/output"

# Third-pass defect 1: discovery does not prove an UVM module can be inserted.
# nvidia-smi and the base kernel module work throughout both fault cases.
new_case available-uvm-rejected-by-secure-boot
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers" "$CASE_ROOT/reject-uvm" "$CASE_ROOT/secure-boot"
run_case available-uvm-rejected-by-secure-boot --check
assert_status 'read-only validation rejects discoverable but unloaded UVM' "$CASE_ROOT/status" 1
assert_grep 'check identifies unverified CUDA UVM load' 'module-present-load-unverified' "$CASE_ROOT/output"
assert_grep 'check names UVM as the unverified component' 'nvidia-uvm' "$CASE_ROOT/output"
assert_file_absent 'read-only check never probes UVM by inserting it' "$CASE_ROOT/calls"
run_case available-uvm-rejected-by-secure-boot --repair-kernel -y
assert_status 'explicit recovery cannot succeed if required UVM fails insertion' "$CASE_ROOT/status" 3
assert_grep 'explicit recovery attempts real UVM insertion' 'modprobe nvidia-uvm' "$CASE_ROOT/calls"
assert_grep 'UVM signature rejection retains Secure Boot diagnostic' 'MokManager' "$CASE_ROOT/output"
assert_not_grep 'failed UVM load never reports healthy recovery' 'Kernel recovery complete: healthy' "$CASE_ROOT/output"
run_case available-uvm-rejected-by-secure-boot -y
assert_status 'ordinary installation also detects UVM insertion failure' "$CASE_ROOT/status" 3
assert_grep 'ordinary installation attempts UVM insertion' 'modprobe nvidia-uvm' "$CASE_ROOT/calls"
assert_file_absent 'unloadable UVM never appears loaded' "$CASE_ROOT/uvm.loaded"

new_case available-uvm-loads-successfully
touch "$CASE_ROOT/module.dkms" "$CASE_ROOT/module.loaded" "$CASE_ROOT/meta.headers" "$CASE_ROOT/versioned.headers"
run_case available-uvm-loads-successfully --check
assert_status 'read-only check treats available but unloaded UVM as unverified' "$CASE_ROOT/status" 1
assert_file_absent 'check cannot insert available UVM' "$CASE_ROOT/calls"
run_case available-uvm-loads-successfully --repair-kernel -y
assert_status 'explicit repair loads UVM and verifies CUDA readiness' "$CASE_ROOT/status" 0
assert_file_present 'successful UVM insertion is observed as loaded' "$CASE_ROOT/uvm.loaded"
assert_grep 'repair attempts required UVM insertion' 'modprobe nvidia-uvm' "$CASE_ROOT/calls"
run_case available-uvm-loads-successfully --check
assert_status 'check succeeds after UVM was successfully loaded' "$CASE_ROOT/status" 0
assert_grep 'loaded UVM and base driver converge to healthy' 'Kernel convergence state: healthy' "$CASE_ROOT/output"
call_count="$(wc -l < "$CASE_ROOT/calls")"
run_case available-uvm-loads-successfully --repair-kernel -y
assert_status 'repeat recovery with loaded UVM is idempotent' "$CASE_ROOT/status" 0
if [[ "$(wc -l < "$CASE_ROOT/calls")" == "$call_count" ]]; then
  ok 'healthy UVM recovery does not repeat module mutations'
else
  not_ok 'healthy UVM recovery repeated module mutations'
fi

# Second-pass defect 2: an unpinned R580 source on a Turing GPU may upgrade
# to the current driver. Installed legacy pinning and older GPU families win.
new_case unpinned-turing-580-modern
 touch "$CASE_ROOT/gpu-turing" "$CASE_ROOT/no-pinning" "$CASE_ROOT/build-failure" "$CASE_ROOT/upgrade-fixes-dkms"
run_case unpinned-turing-580-modern --repair-kernel -y
assert_status 'unpinned Turing R580 may recover by consented current upgrade' "$CASE_ROOT/status" 0
assert_grep 'unpinned Turing R580 is classified as modern' 'Recovery family: modern (nvidia/580.173.02)' "$CASE_ROOT/output"
assert_grep 'unpinned Turing R580 reaches current-driver upgrade' 'apt-get install --only-upgrade cuda-drivers' "$CASE_ROOT/calls"
assert_not_grep 'successful modern Turing repair does not schedule old kernel' 'grub-reboot ' "$CASE_ROOT/calls"

new_case pinned-turing-580-legacy
 touch "$CASE_ROOT/gpu-turing" "$CASE_ROOT/build-failure" "$CASE_ROOT/upgrade-fixes-dkms"
run_case pinned-turing-580-legacy --repair-kernel -y
assert_status 'explicit R580 pin blocks current upgrade on Turing' "$CASE_ROOT/status" 3
assert_grep 'explicit R580 pin selects legacy recovery family' 'Recovery family: legacy (nvidia/580.173.02)' "$CASE_ROOT/output"
assert_not_grep 'explicit R580 pin is respected despite Turing capability' 'apt-get install --only-upgrade cuda-drivers' "$CASE_ROOT/calls"

new_case unpinned-pascal-580-legacy
 touch "$CASE_ROOT/gpu-pascal" "$CASE_ROOT/no-pinning" "$CASE_ROOT/build-failure" "$CASE_ROOT/upgrade-fixes-dkms"
run_case unpinned-pascal-580-legacy --repair-kernel -y
assert_status 'Pascal R580 stays legacy without explicit pin' "$CASE_ROOT/status" 3
assert_grep 'unpinned Pascal still selects legacy recovery family' 'Recovery family: legacy (nvidia/580.173.02)' "$CASE_ROOT/output"
assert_not_grep 'unpinned Pascal cannot take incompatible current branch' 'apt-get install --only-upgrade cuda-drivers' "$CASE_ROOT/calls"

if (( failures )); then
  printf '\n%d kernel-upgrade recovery test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf '\nAll kernel-upgrade recovery tests passed.\n'
