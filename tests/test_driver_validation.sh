#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$test_dir/../nvidia-cuda-installer.sh}"

tmp="$(mktemp -d)"
export NVIDIA_CUDA_INSTALLER_TEST_MODE=1
export NVIDIA_CUDA_INSTALLER_LOCK_FILE="$tmp/run/nvidia-cuda-installer.lock"
export NVIDIA_CUDA_INSTALLER_STATE_DIR="$tmp/state"
export NVIDIA_CUDA_INSTALLER_LAPTOP_POWER_UDEV_RULE_PATH="$tmp/etc/udev/rules.d/80-nvidia-runtime-pm-managed-by-nvidia-cuda-installer.rules"
export NVIDIA_CUDA_INSTALLER_LAPTOP_RUNTIME_PM_MODPROBE_PATH="$tmp/etc/modprobe.d/nvidia-runtime-pm-managed-by-nvidia-cuda-installer.conf"
export NVIDIA_CUDA_INSTALLER_NVIDIA_SUSPEND_MODPROBE_PATH="$tmp/etc/modprobe.d/nvidia-suspend-managed-by-nvidia-cuda-installer.conf"
export NVIDIA_CUDA_INSTALLER_PRIME_RUN_PATH="$tmp/usr/local/bin/prime-run"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_REPO_DIR="$tmp/opt/nvidia-driver-580-local-repo"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_WORK_DIR="$tmp/var/lib/nvidia-driver-580-vendor"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_SOURCE_FILE="$tmp/etc/apt/sources.list.d/nvidia-driver-580-local-vendor.list"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_PREF_FILE="$tmp/etc/apt/preferences.d/nvidia-driver-580-local-vendor.pref"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_KEYRING_PATH="$tmp/usr/share/keyrings/nvidia-driver-580-local-vendor.gpg"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_GNUPG_HOME="$tmp/var/lib/nvidia-driver-580-vendor/gnupg"
export NVIDIA_CUDA_INSTALLER_MODPROBE_DIR="$tmp/etc/modprobe.d"
export NVIDIA_CUDA_INSTALLER_UDEV_RULES_DIR="$tmp/etc/udev/rules.d"

NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1 source "$SCRIPT_UNDER_TEST"
trap - ERR
trap 'rm -rf "$tmp"' EXIT

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
assert_grep() { grep -Fq "$2" "$3" && ok "$1" || not_ok "$1: missing <$2> in $3"; }
assert_not_grep() { ! grep -Fq "$2" "$3" && ok "$1" || not_ok "$1: unexpected <$2> in $3"; }

run_check_case() {
  local name="$1"
  local cuda_installed="$2"
  local smi_exists="$3"
  local smi_works="$4"
  local modinfo_works="$5"
  local modules_loaded="$6"
  local dkms_entries="$7"
  local output="$tmp/${name}.out"
  local status_file="$tmp/${name}.status"

  set +e
  (
    CHECK_LAPTOP_POWER_IDLE=0
    package_installed() {
      [[ "$1" == "$DEFAULT_DRIVER_PACKAGE" && "$cuda_installed" == yes ]]
    }
    command_exists() {
      case "$1" in
        nvidia-smi) [[ "$smi_exists" == yes ]] ;;
        modinfo) [[ "$modinfo_works" == yes ]] ;;
        lsmod) return 0 ;;
        dkms) return 0 ;;
        apt-cache) return 0 ;;
        mokutil) return 1 ;;
        lspci|fuser|lsof|systemctl|udevadm|update-initramfs) return 1 ;;
        *) return 1 ;;
      esac
    }
    nvidia-smi() {
      [[ "$smi_works" == yes ]] || return 1
      printf 'NVIDIA-SMI mock\n'
    }
    modinfo() {
      [[ "$modinfo_works" == yes ]] || return 1
      [[ "$1" == nvidia ]] || return 1
      printf 'filename: /lib/modules/mock/nvidia.ko\n'
    }
    lsmod() {
      if [[ "$modules_loaded" == yes ]]; then
        printf 'nvidia_drm 122880 0\n'
        printf 'nvidia_modeset 1605632 1 nvidia_drm\n'
        printf 'nvidia 99614720 2 nvidia_modeset\n'
      else
        printf 'snd 1 0\n'
      fi
    }
    dkms() {
      [[ "${1:-}" == status ]] || return 1
      if [[ "$dkms_entries" == yes ]]; then
        printf 'nvidia/580.95.05, 6.12.0-amd64, x86_64: installed\n'
      else
        printf 'zfs/2.2.0, 6.12.0-amd64, x86_64: installed\n'
      fi
    }
    apt-cache() {
      [[ "${1:-}" == policy ]] || return 0
      printf 'cuda-drivers:\n'
      if [[ "$cuda_installed" == yes ]]; then
        printf '  Installed: 580.95.05-1\n'
      else
        printf '  Installed: (none)\n'
      fi
      printf '  Candidate: 580.95.05-1\n'
    }
    run_laptop_power_check_section() { return 0; }
    check_secure_boot() { return 0; }
    run_post_reboot_check
  ) >"$output" 2>&1
  local status=$?
  set -e
  printf '%s\n' "$status" > "$status_file"
  printf '%s\n' "$output"
}

# cuda-drivers installed remains a PASS when the driver is functional.
out="$(run_check_case cuda-installed yes yes yes yes yes yes)"
if [[ "$(cat "$tmp/cuda-installed.status")" == 0 ]]; then ok "cuda-drivers installed functional driver passes"; else not_ok "cuda-drivers installed functional driver passes"; fi
assert_grep "cuda-drivers installed reports PASS" "PASS: cuda-drivers package is installed" "$out"
assert_grep "DKMS entries report PASS" "PASS: dkms status has NVIDIA entries" "$out"
assert_grep "DKMS context lists NVIDIA entry" "nvidia/580.95.05" "$out"

# Missing cuda-drivers is WARN, not FAIL, when nvidia-smi and modinfo prove functionality.
out="$(run_check_case cuda-absent-functional no yes yes yes yes yes)"
if [[ "$(cat "$tmp/cuda-absent-functional.status")" == 0 ]]; then ok "cuda-drivers absent functional driver still passes required validation"; else not_ok "cuda-drivers absent functional driver still passes required validation"; fi
assert_grep "cuda-drivers absent functional driver warns" "WARN: cuda-drivers package is not installed, but the NVIDIA driver is functional" "$out"
assert_not_grep "cuda-drivers absent functional driver does not fail metapackage" "FAIL: cuda-drivers package is installed" "$out"
assert_not_grep "cuda-drivers absent functional driver does not fail provenance" "FAIL: cuda-drivers package is not installed" "$out"
assert_grep "DKMS status does not disagree with context" "PASS: dkms status has NVIDIA entries" "$out"
assert_grep "Loaded modules context lists NVIDIA" "nvidia_drm" "$out"

# Missing cuda-drivers plus nonfunctional driver remains a required failure.
out="$(run_check_case cuda-absent-broken no yes no no no no || true)"
if [[ "$(cat "$tmp/cuda-absent-broken.status")" != 0 ]]; then ok "cuda-drivers absent broken driver fails required validation"; else not_ok "cuda-drivers absent broken driver fails required validation"; fi
assert_grep "cuda-drivers absent broken driver reports functional failure" "FAIL: cuda-drivers package is not installed and the NVIDIA driver is not demonstrably functional" "$out"
assert_grep "broken nvidia-smi is still required failure" "FAIL: nvidia-smi can communicate with the driver" "$out"
assert_grep "broken modinfo is still required failure" "FAIL: modinfo can read the nvidia kernel module" "$out"
assert_grep "DKMS absence reports WARN" "WARN: dkms status has no NVIDIA entries" "$out"

# Missing cuda-drivers can still warn/pass with alternate strong evidence: nvidia-smi + DKMS.
out="$(run_check_case cuda-absent-smi-dkms no yes yes no no yes)"
if [[ "$(cat "$tmp/cuda-absent-smi-dkms.status")" != 0 ]]; then
  # modinfo is still a required driver validation failure; the metapackage itself must not add another failure.
  ok "cuda-drivers absent with nvidia-smi/DKMS still keeps metapackage as warning only"
else
  not_ok "cuda-drivers absent with nvidia-smi/DKMS should still fail because modinfo failed"
fi
assert_grep "cuda-drivers absent smi+DKMS warning" "WARN: cuda-drivers package is not installed, but nvidia-smi and DKMS NVIDIA entries show a working NVIDIA driver" "$out"
assert_not_grep "cuda-drivers absent smi+DKMS not provenance failure" "FAIL: cuda-drivers package is not installed" "$out"

if (( failures )); then
  printf '\n%d driver validation test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf '\nAll driver validation tests passed.\n'
