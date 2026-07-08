#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$test_dir/../nvidia-cuda-installer.sh}"

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
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
assert_file_absent() { [[ ! -e "$2" ]] && ok "$1" || not_ok "$1: unexpected path exists: $2"; }
assert_file_present() { [[ -e "$2" ]] && ok "$1" || not_ok "$1: missing path: $2"; }
assert_grep() { grep -Fq "$2" "$3" && ok "$1" || not_ok "$1: missing <$2> in $3"; }
assert_not_grep() { ! grep -Fq "$2" "$3" && ok "$1" || not_ok "$1: unexpected <$2> in $3"; }
reset_paths() { rm -rf "$tmp/etc" "$tmp/usr" "$tmp/var" "$tmp/run" "$tmp/calls" "$tmp/state"; mkdir -p "$tmp"; }

hybrid_lspci=$'0000:00:02.0 VGA compatible controller [0300]: Intel Corporation UHD Graphics [8086:9a49]\n0000:01:00.0 3D controller [0302]: NVIDIA Corporation GA104M [GeForce RTX 3080 Mobile] [10de:24dc]\n0000:01:00.1 Audio device [0403]: NVIDIA Corporation GA104 High Definition Audio Controller [10de:228b]'
desktop_lspci=$'0000:01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD102 [GeForce RTX 4090] [10de:2684]'

# High-level dry-run policy application: confident hybrid laptop path must report every planned action and mutate nothing.
reset_paths
(
  LAPTOP_POWER_MODE=auto
  ASSUME_YES=1
  DRY_RUN=1
  KEEP_NVIDIA_PERSISTENCED=0
  LAPTOP_POWER_AGGRESSIVE=1
  command_exists() {
    case "$1" in
      lspci|systemctl|udevadm|update-initramfs|nvidia-smi) return 0 ;;
      *) return 1 ;;
    esac
  }
  nvidia-smi() { printf '%s
' '00000000:01:00.0, Disabled, Disabled'; }
  lspci() { printf '%s\n' "$hybrid_lspci"; }
  portable_chassis_detected() { return 0; }
  known_nonportable_chassis_detected() { return 1; }
  portable_chassis_reasons_from_file() { printf 'portable chassis_type=10 (notebook)\n'; }
  battery_detected() { return 0; }
  internal_panel_detected() { return 0; }
  systemd_unit_exists() { [[ "$1" == nvidia-persistenced.service ]]; }
  systemd_unit_is_masked() { return 1; }
  systemctl() { printf '%s\n' "$*" >> "$tmp/calls"; return 0; }
  udevadm() { printf 'udevadm %s\n' "$*" >> "$tmp/calls"; return 0; }
  update-initramfs() { printf 'update-initramfs %s\n' "$*" >> "$tmp/calls"; return 0; }
  maybe_configure_laptop_power_policy >"$tmp/dryrun.out" 2>&1
)
assert_grep "dry-run plans persistence-mode disable" "Dry run: would run nvidia-smi -pm 0" "$tmp/dryrun.out"
assert_grep "dry-run plans service disable" "Dry run: would disable and stop nvidia-persistenced.service" "$tmp/dryrun.out"
assert_grep "dry-run plans managed mask only from unmasked state" "would mask nvidia-persistenced.service and create" "$tmp/dryrun.out"
assert_grep "dry-run plans udev rule write" "Dry run: would write managed file: $LAPTOP_POWER_UDEV_RULE_PATH" "$tmp/dryrun.out"
assert_grep "dry-run plans Runtime D3 modprobe write" "Dry run: would write managed file: $LAPTOP_RUNTIME_PM_MODPROBE_PATH" "$tmp/dryrun.out"
assert_grep "dry-run plans initramfs update" "Dry run: would run update-initramfs -u" "$tmp/dryrun.out"
assert_grep "dry-run plans prime-run creation" "Dry run: would create managed PRIME offload helper: $PRIME_RUN_PATH" "$tmp/dryrun.out"
assert_file_absent "dry-run leaves udev rule absent" "$LAPTOP_POWER_UDEV_RULE_PATH"
assert_file_absent "dry-run leaves Runtime D3 modprobe absent" "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"
assert_file_absent "dry-run leaves prime-run absent" "$PRIME_RUN_PATH"
assert_file_absent "dry-run leaves mask marker absent" "$NVIDIA_PERSISTENCED_MASK_MARKER"

# Explicit on must refuse known non-target topologies before any managed artifact can be created.
reset_paths
if (
  LAPTOP_POWER_MODE=on
  ASSUME_YES=0
  DRY_RUN=0
  command_exists() { [[ "$1" == lspci ]]; }
  lspci() { printf '%s\n' "$desktop_lspci"; }
  portable_chassis_detected() { return 1; }
  known_nonportable_chassis_detected() { return 0; }
  portable_chassis_reasons_from_file() { printf 'non-portable chassis_type=3 (desktop)\n'; }
  battery_detected() { return 0; }
  internal_panel_detected() { return 1; }
  maybe_configure_laptop_power_policy >"$tmp/on-desktop.out" 2>&1
); then
  not_ok "explicit --laptop-power=on refuses known desktop topology"
else
  assert_grep "explicit --laptop-power=on refuses known desktop topology" "refuses a known non-portable chassis" "$tmp/on-desktop.out"
fi
assert_file_absent "failed explicit-on desktop path writes no udev rule" "$LAPTOP_POWER_UDEV_RULE_PATH"
assert_file_absent "failed explicit-on desktop path writes no Runtime D3 modprobe" "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"
assert_file_absent "failed explicit-on desktop path creates no prime-run" "$PRIME_RUN_PATH"

# Runtime D3 fresh-install/unavailable path is an actual write only for supported modern families.
reset_paths
(
  DRY_RUN=0
  GPU_FAMILIES=(turing)
  command_exists() { return 1; }
  write_runtime_d3_modprobe_if_needed 0000:01:00.0 >"$tmp/d3-turing.out" 2>&1
)
assert_file_present "fresh-install unavailable Runtime D3 writes modprobe for Turing" "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"
assert_grep "Runtime D3 modprobe contains DynamicPowerManagement" "NVreg_DynamicPowerManagement=0x02" "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"
assert_grep "Runtime D3 unavailable warning is explicit" "diagnostics are unavailable" "$tmp/d3-turing.out"

reset_paths
(
  DRY_RUN=0
  GPU_FAMILIES=(pascal)
  command_exists() { return 1; }
  write_runtime_d3_modprobe_if_needed 0000:01:00.0 >"$tmp/d3-pascal.out" 2>&1
)
assert_file_absent "fresh-install unavailable Runtime D3 skips unsupported legacy family" "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"
assert_grep "unsupported family warning is explicit" "family is unknown or not in the supported modern runtime-D3 policy set" "$tmp/d3-pascal.out"

# Reset/remove must remove only script-owned artifacts and never claim an existing admin mask.
reset_paths
mkdir -p "$(dirname "$LAPTOP_POWER_UDEV_RULE_PATH")" "$(dirname "$LAPTOP_RUNTIME_PM_MODPROBE_PATH")" "$(dirname "$NVIDIA_SUSPEND_MODPROBE_PATH")" "$(dirname "$PRIME_RUN_PATH")" "$SCRIPT_STATE_DIR"
printf '%s\nbody\n' "$LAPTOP_POWER_UDEV_SENTINEL" > "$LAPTOP_POWER_UDEV_RULE_PATH"
printf '%s\nbody\n' "$LAPTOP_RUNTIME_PM_MODPROBE_SENTINEL" > "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"
printf 'admin-owned\n' > "$NVIDIA_SUSPEND_MODPROBE_PATH"
prime_run_helper_content > "$PRIME_RUN_PATH"
printf '%s nvidia-persistenced-mask\n' "$MANAGED_SENTINEL" > "$NVIDIA_PERSISTENCED_MASK_MARKER"
(
  command_exists() { [[ "$1" == systemctl ]]; }
  systemd_unit_is_masked() { return 0; }
  systemctl() { printf '%s\n' "$*" >> "$tmp/calls"; return 0; }
  remove_laptop_power_managed_artifacts >"$tmp/remove.out" 2>&1
)
assert_file_absent "remove deletes managed udev rule" "$LAPTOP_POWER_UDEV_RULE_PATH"
assert_file_absent "remove deletes managed Runtime D3 modprobe" "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"
assert_file_present "remove leaves unmanaged suspend modprobe" "$NVIDIA_SUSPEND_MODPROBE_PATH"
assert_file_absent "remove deletes managed prime-run" "$PRIME_RUN_PATH"
assert_file_absent "remove deletes owned persistenced marker" "$NVIDIA_PERSISTENCED_MASK_MARKER"
assert_grep "remove unmasked only because marker existed" "unmask" "$tmp/calls"
assert_grep "remove warns about unmanaged file" "Leaving unmanaged file in place" "$tmp/remove.out"

# Check-mode ownership reporting must use the shared prime-run predicate, not stale exact-content matching.
reset_paths
mkdir -p "$(dirname "$PRIME_RUN_PATH")"
{
  printf '#!/bin/sh\n'
  printf '%s\n' "$PRIME_RUN_SENTINEL"
  printf 'exec env \\\n'
  printf '  __NV_PRIME_RENDER_OFFLOAD=1 \\\n'
  printf '  __GLX_VENDOR_LIBRARY_NAME=nvidia \\\n'
  printf '  __VK_LAYER_NV_optimus=NVIDIA_only \\\n'
  printf '  "$@"\n'
} > "$PRIME_RUN_PATH"
report_managed_laptop_power_files > "$tmp/check-files.out"
assert_grep "check reports sentinel prime-run as script-owned" "script-owned prime-run helper present" "$tmp/check-files.out"
assert_not_grep "check does not misclassify sentinel prime-run" "existing non-script prime-run helper present" "$tmp/check-files.out"


# Production PATH is sanitized, while explicit test mode preserves PATH for mocks.
path_out="$(env -i PATH="$tmp/mockbin:/usr/local/bin:/bin" NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1 bash -c 'source "$1"; printf "%s" "$PATH"' _ "$SCRIPT_UNDER_TEST")"
if [[ "$path_out" == "/usr/sbin:/usr/bin:/sbin:/bin" ]]; then
  ok "production source path is sanitized"
else
  not_ok "production source path is sanitized: got <$path_out>"
fi
mkdir -p "$tmp/mockbin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/mockbin/mock-tool"
chmod 0755 "$tmp/mockbin/mock-tool"
if env PATH="$tmp/mockbin:$PATH" NVIDIA_CUDA_INSTALLER_TEST_MODE=1 NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1 bash -c 'source "$1"; command_exists mock-tool' _ "$SCRIPT_UNDER_TEST"; then
  ok "test mode preserves PATH for mocked commands"
else
  not_ok "test mode preserves PATH for mocked commands"
fi

# Production refuses test-only managed-path overrides instead of honoring polluted sudo -E state.
if env -i PATH="$PATH" NVIDIA_CUDA_INSTALLER_LAPTOP_POWER_UDEV_RULE_PATH="$tmp/unsafe.rules" bash "$SCRIPT_UNDER_TEST" --help >"$tmp/override-gate.out" 2>&1; then
  not_ok "production run rejects test path override"
else
  assert_grep "production run rejects test path override" "test-only path override" "$tmp/override-gate.out"
fi

# Global lock rejects a second concurrent installer instance and does not block after the first exits.
reset_paths
mkdir -p "$tmp/run"
(
  env NVIDIA_CUDA_INSTALLER_TEST_MODE=1 \
  NVIDIA_CUDA_INSTALLER_LOCK_FILE="$tmp/run/global.lock" \
  NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1 \
  bash -c 'source "$1"; acquire_execution_lock; sleep 1' _ "$SCRIPT_UNDER_TEST"
) >"$tmp/lock-holder.out" 2>&1 &
lock_holder=$!
sleep 0.2
if env NVIDIA_CUDA_INSTALLER_TEST_MODE=1 NVIDIA_CUDA_INSTALLER_LOCK_FILE="$tmp/run/global.lock" NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1 \
  bash -c 'source "$1"; acquire_execution_lock' _ "$SCRIPT_UNDER_TEST" >"$tmp/lock-second.out" 2>&1; then
  not_ok "global lock rejects concurrent invocation"
else
  assert_grep "global lock rejects concurrent invocation" "already running" "$tmp/lock-second.out"
fi
wait "$lock_holder"
if env NVIDIA_CUDA_INSTALLER_TEST_MODE=1 NVIDIA_CUDA_INSTALLER_LOCK_FILE="$tmp/run/global.lock" NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1 \
  bash -c 'source "$1"; acquire_execution_lock' _ "$SCRIPT_UNDER_TEST" >"$tmp/lock-after.out" 2>&1; then
  ok "global lock releases after holder exits"
else
  not_ok "global lock releases after holder exits"
fi

# Laptop policy preflight detects a later managed-file collision before service/sysfs mutation.
reset_paths
mkdir -p "$(dirname "$LAPTOP_RUNTIME_PM_MODPROBE_PATH")"
printf 'administrator-owned runtime policy\n' > "$LAPTOP_RUNTIME_PM_MODPROBE_PATH"
if (
  LAPTOP_POWER_MODE=auto
  ASSUME_YES=1
  DRY_RUN=0
  KEEP_NVIDIA_PERSISTENCED=0
  LAPTOP_POWER_AGGRESSIVE=1
  command_exists() {
    case "$1" in
      lspci|systemctl|nvidia-smi) return 0 ;;
      *) return 1 ;;
    esac
  }
  lspci() { printf '%s\n' "$hybrid_lspci"; }
  nvidia-smi() { printf 'nvidia-smi called\n' >> "$tmp/preflight.calls"; return 0; }
  systemd_unit_exists() { [[ "$1" == nvidia-persistenced.service ]]; }
  systemctl() { printf '%s\n' "$*" >> "$tmp/preflight.calls"; return 0; }
  portable_chassis_detected() { return 0; }
  known_nonportable_chassis_detected() { return 1; }
  portable_chassis_reasons_from_file() { printf 'portable chassis_type=10 (notebook)\n'; }
  battery_detected() { return 0; }
  internal_panel_detected() { return 0; }
  maybe_configure_laptop_power_policy >"$tmp/preflight.out" 2>&1
); then
  not_ok "preflight refuses unmanaged later collision"
else
  assert_grep "preflight refuses unmanaged later collision" "Refusing to overwrite unmanaged file" "$tmp/preflight.out"
fi
assert_file_absent "preflight collision writes no udev rule" "$LAPTOP_POWER_UDEV_RULE_PATH"
if [[ ! -e "$tmp/preflight.calls" ]]; then
  ok "preflight collision performs no service or nvidia-smi calls"
else
  not_ok "preflight collision performs no service or nvidia-smi calls"
fi

# Explicit on should allow ambiguous but plausible hybrid topology when not high-confidence unsafe.
reset_paths
if (
  LAPTOP_POWER_MODE=on
  ASSUME_YES=0
  DRY_RUN=1
  KEEP_NVIDIA_PERSISTENCED=1
  LAPTOP_POWER_AGGRESSIVE=0
  command_exists() {
    case "$1" in
      lspci|update-initramfs) return 0 ;;
      *) return 1 ;;
    esac
  }
  lspci() { printf '%s\n' "$hybrid_lspci"; }
  portable_chassis_detected() { return 1; }
  known_nonportable_chassis_detected() { return 1; }
  portable_chassis_reasons_from_file() { return 0; }
  battery_detected() { return 1; }
  internal_panel_detected() { return 1; }
  update-initramfs() { return 0; }
  maybe_configure_laptop_power_policy >"$tmp/on-ambiguous.out" 2>&1
); then
  assert_grep "explicit on allows ambiguous hybrid topology" "Proceeding because the topology is not known desktop/server or NVIDIA-only" "$tmp/on-ambiguous.out"
else
  not_ok "explicit on allows ambiguous hybrid topology"
fi

# remove/reset cleanup removes managed branch-580 local vendor artifacts only with ownership proof.
reset_paths
mkdir -p "$(dirname "$VENDOR_580_SOURCE_FILE")" "$(dirname "$VENDOR_580_PREF_FILE")" "$(dirname "$VENDOR_580_KEYRING_PATH")" "$VENDOR_580_REPO_DIR" "$VENDOR_580_WORK_DIR"
cat > "$VENDOR_580_SOURCE_FILE" <<EOF
# Added by test
$VENDOR_580_MANAGED_SENTINEL
# Local signed vendor repo containing NVIDIA Debian 12 branch-580 driver packages for Debian 13 compatibility.
deb [arch=amd64 signed-by=$VENDOR_580_KEYRING_PATH] file:$VENDOR_580_REPO_DIR ./
EOF
cat > "$VENDOR_580_PREF_FILE" <<EOF
# Added by test
$VENDOR_580_MANAGED_SENTINEL
Pin: release o=$VENDOR_580_REPO_ORIGIN
EOF
cat > "$VENDOR_580_REPO_DIR/Release" <<EOF
Origin: $VENDOR_580_REPO_ORIGIN
Label: $VENDOR_580_REPO_LABEL
EOF
printf '%s\n' "$VENDOR_580_MANAGED_SENTINEL" > "$VENDOR_580_WORK_DIR/managed-by-nvidia-cuda-installer"
printf 'fake local repo keyring\n' > "$VENDOR_580_KEYRING_PATH"
(
  command_exists() { [[ "$1" == gpg ]]; }
  gpg() {
    case "$*" in
      *"--show-keys"*) printf '%s
' "$VENDOR_580_SIGNING_UID" ;;
      *) return 1 ;;
    esac
  }
  remove_managed_apt_vendor_artifacts >"$tmp/vendor-remove.out" 2>&1
)
assert_file_absent "remove deletes managed branch-580 source" "$VENDOR_580_SOURCE_FILE"
assert_file_absent "remove deletes managed branch-580 preferences" "$VENDOR_580_PREF_FILE"
assert_file_absent "remove deletes managed branch-580 keyring" "$VENDOR_580_KEYRING_PATH"
assert_file_absent "remove deletes managed branch-580 repo dir" "$VENDOR_580_REPO_DIR"
assert_file_absent "remove deletes managed branch-580 work dir" "$VENDOR_580_WORK_DIR"

reset_paths
mkdir -p "$(dirname "$VENDOR_580_SOURCE_FILE")"
printf 'admin source\n' > "$VENDOR_580_SOURCE_FILE"
remove_managed_apt_vendor_artifacts >"$tmp/vendor-unmanaged.out" 2>&1
assert_file_present "remove leaves unmanaged branch-580 source" "$VENDOR_580_SOURCE_FILE"
assert_grep "remove warns about unmanaged branch-580 source" "Leaving unmanaged branch-580 vendor APT source" "$tmp/vendor-unmanaged.out"

run_vendor_rebuild_collision_case() {
  local name="$1"
  local output="$tmp/vendor-preflight-${name}.out"
  local prereq_marker="$tmp/vendor-preflight-${name}.prereq-called"
  reset_paths

  case "$name" in
    source)
      mkdir -p "$(dirname "$VENDOR_580_SOURCE_FILE")"
      printf 'admin source
' > "$VENDOR_580_SOURCE_FILE"
      ;;
    preferences)
      mkdir -p "$(dirname "$VENDOR_580_PREF_FILE")"
      printf 'admin preferences
' > "$VENDOR_580_PREF_FILE"
      ;;
    keyring)
      mkdir -p "$(dirname "$VENDOR_580_KEYRING_PATH")"
      printf 'admin keyring
' > "$VENDOR_580_KEYRING_PATH"
      ;;
    repo)
      mkdir -p "$VENDOR_580_REPO_DIR"
      printf 'admin repo
' > "$VENDOR_580_REPO_DIR/admin-owned"
      ;;
    work)
      mkdir -p "$VENDOR_580_WORK_DIR"
      printf 'admin work
' > "$VENDOR_580_WORK_DIR/admin-owned"
      ;;
    *)
      not_ok "unknown vendor collision case: $name"
      return 0
      ;;
  esac

  if (
    DRY_RUN=0
    dpkg() { [[ "${1:-}" == "--print-architecture" ]] && printf 'amd64
'; }
    install_vendor_580_prereqs() { printf 'called
' > "$prereq_marker"; }
    bootstrap_local_debian12_580_vendor_repo >"$output" 2>&1
  ); then
    not_ok "branch-580 rebuild preflight rejects unmanaged $name path"
  else
    assert_grep "branch-580 rebuild preflight rejects unmanaged $name path" "Refusing to rebuild the branch-580 local vendor repo" "$output"
  fi

  assert_file_absent "branch-580 unmanaged $name path fails before prerequisite mutation" "$prereq_marker"
  case "$name" in
    source) assert_grep "branch-580 unmanaged source content preserved" "admin source" "$VENDOR_580_SOURCE_FILE" ;;
    preferences) assert_grep "branch-580 unmanaged preferences content preserved" "admin preferences" "$VENDOR_580_PREF_FILE" ;;
    keyring) assert_grep "branch-580 unmanaged keyring content preserved" "admin keyring" "$VENDOR_580_KEYRING_PATH" ;;
    repo) assert_grep "branch-580 unmanaged repo directory not deleted" "admin repo" "$VENDOR_580_REPO_DIR/admin-owned" ;;
    work)
      assert_grep "branch-580 unmanaged work directory not claimed" "admin work" "$VENDOR_580_WORK_DIR/admin-owned"
      assert_file_absent "branch-580 unmanaged work directory gets no sentinel" "$VENDOR_580_MANAGED_SENTINEL_FILE"
      ;;
  esac
}

run_vendor_rebuild_collision_case source
run_vendor_rebuild_collision_case preferences
run_vendor_rebuild_collision_case keyring
run_vendor_rebuild_collision_case repo
run_vendor_rebuild_collision_case work

# A prior managed branch-580 keyring must not become stranded merely because gpg was removed.
# Without gpg, ownership is inferred only from multiple surrounding managed vendor artifacts.
reset_paths
mkdir -p "$(dirname "$VENDOR_580_SOURCE_FILE")" "$(dirname "$VENDOR_580_PREF_FILE")" "$(dirname "$VENDOR_580_KEYRING_PATH")" "$VENDOR_580_REPO_DIR" "$VENDOR_580_WORK_DIR"
cat > "$VENDOR_580_SOURCE_FILE" <<EOF
# Added by test
$VENDOR_580_MANAGED_SENTINEL
# Local signed vendor repo containing NVIDIA Debian 12 branch-580 driver packages for Debian 13 compatibility.
deb [arch=amd64 signed-by=$VENDOR_580_KEYRING_PATH] file:$VENDOR_580_REPO_DIR ./
EOF
cat > "$VENDOR_580_PREF_FILE" <<EOF
# Added by test
$VENDOR_580_MANAGED_SENTINEL
Pin: release o=$VENDOR_580_REPO_ORIGIN
EOF
cat > "$VENDOR_580_REPO_DIR/Release" <<EOF
Origin: $VENDOR_580_REPO_ORIGIN
Label: $VENDOR_580_REPO_LABEL
EOF
printf '%s\n' "$VENDOR_580_MANAGED_SENTINEL" > "$VENDOR_580_MANAGED_SENTINEL_FILE"
printf 'opaque previous managed keyring bytes\n' > "$VENDOR_580_KEYRING_PATH"
if (
  command_exists() { return 1; }
  preflight_vendor_580_rebuild_ownership >"$tmp/vendor-keyring-no-gpg-preflight.out" 2>&1
); then
  ok "managed branch-580 keyring ownership can be inferred when gpg is unavailable"
else
  not_ok "managed branch-580 keyring ownership can be inferred when gpg is unavailable"
fi
(
  command_exists() { return 1; }
  remove_managed_apt_vendor_artifacts >"$tmp/vendor-keyring-no-gpg-remove.out" 2>&1
)
assert_file_absent "remove deletes managed branch-580 keyring when gpg is unavailable" "$VENDOR_580_KEYRING_PATH"
assert_file_absent "remove deletes managed branch-580 source when gpg is unavailable" "$VENDOR_580_SOURCE_FILE"
assert_file_absent "remove deletes managed branch-580 preferences when gpg is unavailable" "$VENDOR_580_PREF_FILE"
assert_file_absent "remove deletes managed branch-580 repo when gpg is unavailable" "$VENDOR_580_REPO_DIR"
assert_file_absent "remove deletes managed branch-580 work dir when gpg is unavailable" "$VENDOR_580_WORK_DIR"

# Conflict scan reports likely unmanaged policy conflicts without failing.
reset_paths
mkdir -p "$MODPROBE_POLICY_DIR" "$UDEV_RULES_DIR"
printf 'options nvidia NVreg_DynamicPowerManagement=0x00\n' > "$MODPROBE_POLICY_DIR/admin.conf"
printf 'ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{power/control}="on"\n' > "$UDEV_RULES_DIR/99-admin.rules"
report_laptop_power_policy_conflicts >"$tmp/conflicts.out"
assert_grep "conflict scan reports DynamicPowerManagement override" "NVreg_DynamicPowerManagement" "$tmp/conflicts.out"
assert_grep "conflict scan reports udev power/control on" "power/control" "$tmp/conflicts.out"
assert_grep "conflict scan is diagnostic" "diagnostic only" "$tmp/conflicts.out"

if (( failures )); then
  printf '\n%d laptop-power policy behavior test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf '\nAll laptop power policy behavior tests passed.\n'
