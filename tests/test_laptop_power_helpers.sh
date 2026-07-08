#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SCRIPT_UNDER_TEST:-}" ]]; then
  if [[ -r "$test_dir/../nvidia-cuda-installer.sh" ]]; then
    SCRIPT_UNDER_TEST="$test_dir/../nvidia-cuda-installer.sh"
  else
    SCRIPT_UNDER_TEST="$test_dir/../nvidia-cuda-installer-laptop-power.sh"
  fi
fi

tmp="$(mktemp -d)"
export NVIDIA_CUDA_INSTALLER_TEST_MODE=1
export NVIDIA_CUDA_INSTALLER_LAPTOP_POWER_UDEV_RULE_PATH="$tmp/etc/udev/rules.d/80-nvidia-runtime-pm-managed-by-nvidia-cuda-installer.rules"
export NVIDIA_CUDA_INSTALLER_LAPTOP_RUNTIME_PM_MODPROBE_PATH="$tmp/etc/modprobe.d/nvidia-runtime-pm-managed-by-nvidia-cuda-installer.conf"
export NVIDIA_CUDA_INSTALLER_NVIDIA_SUSPEND_MODPROBE_PATH="$tmp/etc/modprobe.d/nvidia-suspend-managed-by-nvidia-cuda-installer.conf"
export NVIDIA_CUDA_INSTALLER_PRIME_RUN_PATH="$tmp/usr/local/bin/prime-run"
export NVIDIA_CUDA_INSTALLER_STATE_DIR="$tmp/var/lib/nvidia-cuda-installer"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_REPO_DIR="$tmp/opt/nvidia-driver-580-local-repo"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_WORK_DIR="$tmp/var/lib/nvidia-driver-580-vendor"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_SOURCE_FILE="$tmp/etc/apt/sources.list.d/nvidia-driver-580-local-vendor.list"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_PREF_FILE="$tmp/etc/apt/preferences.d/nvidia-driver-580-local-vendor.pref"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_KEYRING_PATH="$tmp/usr/share/keyrings/nvidia-driver-580-local-vendor.gpg"
export NVIDIA_CUDA_INSTALLER_VENDOR_580_GNUPG_HOME="$tmp/var/lib/nvidia-driver-580-vendor/gnupg"
export NVIDIA_CUDA_INSTALLER_MODPROBE_DIR="$tmp/etc/modprobe.d"
export NVIDIA_CUDA_INSTALLER_UDEV_RULES_DIR="$tmp/etc/udev/rules.d"
export NVIDIA_CUDA_INSTALLER_LOCK_FILE="$tmp/run/nvidia-cuda-installer.lock"

NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1 source "$SCRIPT_UNDER_TEST"
trap - ERR
trap 'rm -rf "$tmp"' EXIT

failures=0

aok() {
  local name="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

anok() {
  local name="$1"
  shift
  if "$@"; then
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  else
    printf 'ok - %s\n' "$name"
  fi
}

aeq() {
  local name="$1"
  local want="$2"
  local got="$3"
  if [[ "$got" == "$want" ]]; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s: wanted <%s>, got <%s>\n' "$name" "$want" "$got" >&2
    failures=$((failures + 1))
  fi
}

afile_absent() {
  local name="$1"
  local path="$2"
  if [[ ! -e "$path" ]]; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s: unexpected path exists: %s\n' "$name" "$path" >&2
    failures=$((failures + 1))
  fi
}

mock_systemctl_case() {
  SYSTEMCTL_STATE_FILE="$tmp/systemd-state"
  SYSTEMCTL_CALLS_FILE="$tmp/systemctl.calls"

  command_exists() {
    case "$1" in
      systemctl) return 0 ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }

  systemctl() {
    printf '%s
' "$*" >> "$SYSTEMCTL_CALLS_FILE"
    case "$1" in
      is-enabled)
        cat "$SYSTEMCTL_STATE_FILE" 2>/dev/null || printf 'disabled
'
        [[ "$(cat "$SYSTEMCTL_STATE_FILE" 2>/dev/null || printf disabled)" != "missing" ]]
        ;;
      mask)
        printf 'masked
' > "$SYSTEMCTL_STATE_FILE"
        ;;
      unmask)
        printf 'disabled
' > "$SYSTEMCTL_STATE_FILE"
        ;;
      list-unit-files)
        printf 'nvidia-persistenced.service enabled
'
        ;;
      cat)
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  }

  "$@"
}

reset_managed_paths() {
  rm -rf "$tmp/etc" "$tmp/usr" "$tmp/var" "$tmp/systemctl.calls" "$tmp/systemd-state"
}

# chassis-type parsing
reset_managed_paths
mkdir -p "$tmp"
aok "chassis 9 is portable" is_portable_chassis_type 9
aok "chassis 11 is portable" is_portable_chassis_type 11
aok "chassis 31 is portable" is_portable_chassis_type 31
aok "chassis 3 is known nonportable" is_known_nonportable_chassis_type 3
anok "chassis 3 is non-portable" is_portable_chassis_type 3
printf '10\n' > "$tmp/chassis_type"
aok "portable chassis file detected" portable_chassis_detected "$tmp/chassis_type"

# battery detection is a signal, but not sufficient by itself.
mkdir -p "$tmp/power/BAT0"
printf 'Battery\n' > "$tmp/power/BAT0/type"
aok "BAT0 battery detected" battery_detected "$tmp/power"
anok "battery alone is not confident" laptop_power_confidence_from_signals no yes no no

# mocked lspci hybrid detection, BDF discovery, and family loading.
hybrid_lspci=$'0000:00:02.0 VGA compatible controller [0300]: Intel Corporation UHD Graphics [8086:9a49]\n0000:01:00.0 3D controller [0302]: NVIDIA Corporation GA104M [GeForce RTX 3080 Mobile] [10de:24dc]\n0000:01:00.1 Audio device [0403]: NVIDIA Corporation GA104 High Definition Audio Controller [10de:228b]'
aok "mocked Intel + NVIDIA lspci is hybrid" hybrid_gpu_detected_from_lspci_text "$hybrid_lspci"
aeq "NVIDIA display/3D BDF discovery uses full domain" "0000:01:00.0" "$(nvidia_bdfs_from_lspci_text "$hybrid_lspci")"
load_gpu_inventory_from_lspci_text "$hybrid_lspci"
aeq "laptop policy can classify NVIDIA family from supplied lspci text" "ampere" "${GPU_FAMILIES[0]}"

desktop_lspci=$'0000:01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD102 [GeForce RTX 4090] [10de:2684]'
anok "NVIDIA-only mocked workstation is not hybrid" hybrid_gpu_detected_from_lspci_text "$desktop_lspci"

# NVIDIA sibling PCI functions.
mkdir -p "$tmp/sys/0000:01:00.0" "$tmp/sys/0000:01:00.1" "$tmp/sys/0000:02:00.0"
aeq "NVIDIA sibling derivation returns same slot functions" $'0000:01:00.0\n0000:01:00.1' "$(nvidia_sibling_bdfs_for_bdf 0000:01:00.0 "$tmp/sys")"

# Runtime D3 procfs parsing and policy decisions.
aeq "Runtime D3 fine-grained parse" "enabled-fine-grained" "$(runtime_d3_status_from_text 'Runtime D3 status:          Enabled (fine-grained)')"
aeq "Runtime D3 disabled parse" "disabled" "$(runtime_d3_status_from_text 'Runtime D3 status: Disabled')"
aeq "Runtime D3 unsupported parse" "unsupported" "$(runtime_d3_status_from_text 'Runtime D3 status: Not supported')"
mkdir -p "$tmp/proc/0000:01:00.0"
printf 'Runtime D3 status:          Enabled (fine-grained)\n' > "$tmp/proc/0000:01:00.0/power"
aeq "Runtime D3 procfs BDF parse" "enabled-fine-grained" "$(runtime_d3_status_for_bdf 0000:01:00.0 "$tmp/proc")"
aeq "Ampere fine-grained Runtime D3 relies on driver default" "skip-driver-default" "$(runtime_d3_modprobe_decision_for_statuses yes yes enabled-fine-grained)"
aeq "fresh install unavailable Runtime D3 writes for supported family" "write-unavailable" "$(runtime_d3_modprobe_decision_for_statuses yes yes unavailable)"
aeq "disabled Runtime D3 writes for supported family" "write-disabled" "$(runtime_d3_modprobe_decision_for_statuses yes yes disabled)"
aeq "unsupported Runtime D3 does not get a blind module option" "skip-unsupported" "$(runtime_d3_modprobe_decision_for_statuses yes yes unsupported)"
aeq "unknown or legacy family does not get Runtime D3 module option" "skip-unsupported-family" "$(runtime_d3_modprobe_decision_for_statuses no no unavailable)"

# sysfs runtime PM reads.
mkdir -p "$tmp/sys/0000:01:00.0/power"
printf 'auto\n' > "$tmp/sys/0000:01:00.0/power/control"
printf 'suspended\n' > "$tmp/sys/0000:01:00.0/power/runtime_status"
aeq "PCI power/control read" "auto" "$(pci_power_read 0000:01:00.0 control "$tmp/sys")"
aeq "PCI runtime_status read" "suspended" "$(pci_power_read 0000:01:00.0 runtime_status "$tmp/sys")"

# Managed-file sentinel behavior, idempotence, and dry-run non-mutation.
printf '%s\nbody\n' "$LAPTOP_POWER_UDEV_SENTINEL" > "$tmp/managed-rule"
printf 'admin-owned\n' > "$tmp/unmanaged-rule"
aok "managed sentinel recognized" managed_file_has_sentinel "$tmp/managed-rule" "$LAPTOP_POWER_UDEV_SENTINEL"
anok "unmanaged file rejected by sentinel check" managed_file_has_sentinel "$tmp/unmanaged-rule" "$LAPTOP_POWER_UDEV_SENTINEL"
printf -v managed_content '%s\nkey=value\n' "$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL"
write_managed_file "$tmp/managed.conf" "$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL" 0644 "$managed_content"
first_hash="$(sha256sum "$tmp/managed.conf" | awk '{ print $1 }')"
write_managed_file "$tmp/managed.conf" "$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL" 0644 "$managed_content"
second_hash="$(sha256sum "$tmp/managed.conf" | awk '{ print $1 }')"
aeq "managed file write is idempotent" "$first_hash" "$second_hash"
remove_managed_file_if_sentinel "$tmp/managed.conf" "$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL"
afile_absent "managed file removal removes only sentinel-owned file" "$tmp/managed.conf"
printf 'admin-owned\n' > "$tmp/unmanaged.conf"
anok "write_managed_file refuses unmanaged target" bash -c "NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1 source '$SCRIPT_UNDER_TEST'; write_managed_file '$tmp/unmanaged.conf' '$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL' 0644 '$managed_content' >/dev/null 2>&1"

# Decision matrix.
aeq "ask + confident + -y applies" "apply" "$(laptop_power_decision_for_mode ask 1 yes)"
aeq "ask + ambiguous + -y skips" "skip" "$(laptop_power_decision_for_mode ask 1 no)"
aeq "auto + confident applies" "apply" "$(laptop_power_decision_for_mode auto 1 yes)"
aeq "auto + ambiguous skips" "skip" "$(laptop_power_decision_for_mode auto 1 no)"
aeq "explicit on enters apply path before topology guard" "apply" "$(laptop_power_decision_for_mode on 0 no)"
aeq "off always skips" "skip" "$(laptop_power_decision_for_mode off 1 yes)"
aeq "explicit on allows hybrid ambiguous portable topology" "allowed" "$(laptop_power_on_topology_status no yes yes)"
aeq "explicit on rejects known nonportable chassis" "known-nonportable" "$(laptop_power_on_topology_status yes yes yes)"
aeq "explicit on rejects NVIDIA-only topology" "non-hybrid" "$(laptop_power_on_topology_status no no yes)"
aeq "explicit on rejects missing NVIDIA topology" "no-nvidia" "$(laptop_power_on_topology_status no no no)"

# Explicit --laptop-power=on must fail a known nonportable topology through the real policy gate.
if (
  LAPTOP_POWER_MODE=on
  ASSUME_YES=0
  DRY_RUN=1
  command_exists() { [[ "$1" == lspci ]] && return 0; return 1; }
  lspci() { printf '%s\n' "$desktop_lspci"; }
  portable_chassis_detected() { return 1; }
  known_nonportable_chassis_detected() { return 0; }
  portable_chassis_reasons_from_file() { printf 'non-portable chassis_type=3 (desktop)\n'; }
  battery_detected() { return 0; }
  internal_panel_detected() { return 1; }
  maybe_configure_laptop_power_policy >/"$tmp/on-unsafe.out" 2>&1
); then
  printf 'not ok - explicit on refused known nonportable topology\n' >&2
  failures=$((failures + 1))
else
  if grep -Fq 'refuses a known non-portable chassis' "$tmp/on-unsafe.out"; then
    printf 'ok - explicit on refused known nonportable topology\n'
  else
    printf 'not ok - explicit on failure did not explain known nonportable refusal\n' >&2
    failures=$((failures + 1))
  fi
fi

# Managed mask ownership behavior.
reset_managed_paths
mkdir -p "$SCRIPT_STATE_DIR"
printf 'disabled\n' > "$tmp/systemd-state"
(
  LAPTOP_POWER_AGGRESSIVE=1
  mock_systemctl_case create_managed_nvidia_persistenced_mask_if_unowned
)
aok "aggressive mask records ownership when it creates the mask" nvidia_persistenced_mask_marker_is_owned
aok "aggressive mask calls systemctl mask when unmasked" grep -Fxq 'mask' "$tmp/systemctl.calls"

rm -f "$NVIDIA_PERSISTENCED_MASK_MARKER" "$tmp/systemctl.calls"
printf 'masked\n' > "$tmp/systemd-state"
(
  LAPTOP_POWER_AGGRESSIVE=1
  mock_systemctl_case create_managed_nvidia_persistenced_mask_if_unowned
)
afile_absent "preexisting admin mask does not get script marker" "$NVIDIA_PERSISTENCED_MASK_MARKER"
anok "preexisting admin mask is not masked again" grep -Fxq 'mask' "$tmp/systemctl.calls"

printf '%s nvidia-persistenced-mask\n' "$MANAGED_SENTINEL" > "$NVIDIA_PERSISTENCED_MASK_MARKER"
printf 'masked\n' > "$tmp/systemd-state"
rm -f "$tmp/systemctl.calls"
(
  mock_systemctl_case remove_managed_nvidia_persistenced_mask
)
afile_absent "owned mask marker removed after unmask" "$NVIDIA_PERSISTENCED_MASK_MARKER"
aok "owned mask removal calls systemctl unmask" grep -Fxq 'unmask' "$tmp/systemctl.calls"

# Fresh-install Runtime D3 unavailable writes managed modprobe for supported family, but dry-run does not mutate.
reset_managed_paths
(
  DRY_RUN=0
  GPU_FAMILIES=(ampere)
  command_exists() { return 1; }
  write_runtime_d3_modprobe_if_needed 0000:01:00.0 >/"$tmp/runtime-d3-write.out" 2>&1
)
aok "fresh-install unavailable Runtime D3 writes managed modprobe file" managed_file_has_sentinel "$LAPTOP_RUNTIME_PM_MODPROBE_PATH" "$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL"
aok "Runtime D3 modprobe contains DynamicPowerManagement option" grep -Fq 'NVreg_DynamicPowerManagement=0x02' "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"

reset_managed_paths
(
  DRY_RUN=1
  KEEP_NVIDIA_PERSISTENCED=0
  LAPTOP_POWER_AGGRESSIVE=1
  GPU_FAMILIES=(ampere)
  command_exists() { return 1; }
  apply_laptop_power_policy 0000:01:00.0 >/"$tmp/dry-run-policy.out" 2>&1
)
afile_absent "dry-run policy does not write udev rule" "$LAPTOP_POWER_UDEV_RULE_PATH"
afile_absent "dry-run policy does not write Runtime D3 modprobe" "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"
afile_absent "dry-run policy does not create prime-run" "$PRIME_RUN_PATH"
afile_absent "dry-run policy does not create persistenced marker" "$NVIDIA_PERSISTENCED_MASK_MARKER"

# PRIME helper ownership now has a sentinel while still recognizing previous exact helper content as script-owned.
reset_managed_paths
write_prime_run_helper_if_absent
if grep -Fqx "$PRIME_RUN_SENTINEL" "$PRIME_RUN_PATH"; then
  printf 'ok - prime-run helper includes managed sentinel\n'
else
  printf 'not ok - prime-run helper includes managed sentinel\n' >&2
  failures=$((failures + 1))
fi
aok "sentinel prime-run helper is recognized as managed" prime_run_helper_is_managed
remove_prime_run_helper_if_managed
afile_absent "managed prime-run helper removal removes sentinel helper" "$PRIME_RUN_PATH"
mkdir -p "$(dirname "$PRIME_RUN_PATH")"
legacy_prime_run_helper_content > "$PRIME_RUN_PATH"
aok "legacy exact prime-run helper is still recognized as managed" prime_run_helper_is_managed

# nvidia-smi CSV parsing catches enabled in the final field.
aok "nvidia-smi report detects enabled persistence in final CSV field" nvidia_smi_report_has_active_display_or_persistence '00000000:01:00.0, Disabled, Enabled'
aok "nvidia-smi report detects active display in middle CSV field" nvidia_smi_report_has_active_display_or_persistence '00000000:01:00.0, Enabled, Disabled'
anok "nvidia-smi report ignores fully disabled display and persistence" nvidia_smi_report_has_active_display_or_persistence '00000000:01:00.0, Disabled, Disabled'

# Confident laptop/hybrid detection requires multiple signals.
aok "portable chassis + hybrid is confident" laptop_power_confidence_from_signals yes no no yes
aok "battery + internal panel + hybrid is confident" laptop_power_confidence_from_signals no yes yes yes
anok "portable signals without NVIDIA hybrid are not confident" laptop_power_confidence_from_signals no yes yes no

if (( failures )); then
  printf '\n%d helper test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf '\nAll laptop power helper tests passed.\n'
