#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$test_dir/../nvidia-cuda-installer.sh}"

tmp="$(mktemp -d)"
export NVIDIA_CUDA_INSTALLER_TEST_MODE=1
export NVIDIA_CUDA_INSTALLER_LOCK_FILE="$tmp/run/nvidia-cuda-installer.lock"
NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1 source "$SCRIPT_UNDER_TEST"
trap - ERR
trap 'rm -rf "$tmp"' EXIT

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
assert_grep() { grep -Fq "$2" "$3" && ok "$1" || not_ok "$1: missing <$2> in $3"; }
assert_not_grep() { ! grep -Fq "$2" "$3" && ok "$1" || not_ok "$1: unexpected <$2> in $3"; }
assert_eq() {
  local name="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then ok "$name"; else not_ok "$name: wanted <$want>, got <$got>"; fi
}

setup_hybrid_sysfs() {
  local nvidia_connector_status="${1:-disconnected}"
  rm -rf "$tmp/sys" "$tmp/drm" "$tmp/dev" "$tmp/proc-fb"
  mkdir -p \
    "$tmp/sys/0000:00:02.0/drm/card0" \
    "$tmp/sys/0000:01:00.0/drm/card1" \
    "$tmp/sys/0000:01:00.0/drm/renderD129" \
    "$tmp/sys/0000:01:00.0/power" \
    "$tmp/sys/0000:01:00.1/power" \
    "$tmp/drm/card0-eDP-1" \
    "$tmp/drm/card1-HDMI-A-1" \
    "$tmp/dev/dri"
  printf '0x8086\n' > "$tmp/sys/0000:00:02.0/vendor"
  printf '0x10de\n' > "$tmp/sys/0000:01:00.0/vendor"
  printf '0x10de\n' > "$tmp/sys/0000:01:00.1/vendor"
  printf '0x030000\n' > "$tmp/sys/0000:01:00.0/class"
  printf '0x040300\n' > "$tmp/sys/0000:01:00.1/class"
  printf '1\n' > "$tmp/sys/0000:00:02.0/boot_vga"
  printf '0\n' > "$tmp/sys/0000:01:00.0/boot_vga"
  printf 'connected\n' > "$tmp/drm/card0-eDP-1/status"
  printf '%s\n' "$nvidia_connector_status" > "$tmp/drm/card1-HDMI-A-1/status"
  printf 'auto\n' > "$tmp/sys/0000:01:00.0/power/control"
  printf 'active\n' > "$tmp/sys/0000:01:00.0/power/runtime_status"
  printf 'auto\n' > "$tmp/sys/0000:01:00.1/power/control"
  printf 'suspended\n' > "$tmp/sys/0000:01:00.1/power/runtime_status"
  : > "$tmp/dev/dri/card1"
  : > "$tmp/dev/dri/renderD129"
  printf '0 i915drmfb\n' > "$tmp/proc-fb"
}

mock_common_power_state() {
  runtime_d3_status_for_bdf() { printf 'enabled-fine-grained\n'; }
  systemd_unit_exists() { [[ "$1" == nvidia-persistenced.service ]]; }
  systemctl() {
    case "$1" in
      is-active) printf 'inactive\n' ;;
      is-enabled) printf 'disabled\n' ;;
      *) return 0 ;;
    esac
  }
}

# NVIDIA BDF maps to its sysfs-discovered DRM nodes without hardcoded card/render numbers.
setup_hybrid_sysfs disconnected
assert_eq "NVIDIA BDF maps to non-hardcoded DRM nodes" \
  $'/tmp/dev/dri/card1\n/tmp/dev/dri/renderD129' \
  "$(drm_dev_nodes_for_bdf 0000:01:00.0 "$tmp/sys" /tmp/dev/dri)"
expected_nodes=$(printf '%s\n%s' "$tmp/dev/dri/card1" "$tmp/dev/dri/renderD129")
assert_eq "NVIDIA DRM nodes use supplied dev root" \
  "$expected_nodes" \
  "$(drm_dev_nodes_for_bdf 0000:01:00.0 "$tmp/sys" "$tmp/dev/dri")"

# High-confidence idle blocker: no /dev/nvidia clients, configured Runtime D3, Intel display route, Xorg holds NVIDIA card node.
setup_hybrid_sysfs disconnected
(
  mock_common_power_state
  command_exists() { case "$1" in lsof|systemctl) return 0 ;; *) return 1 ;; esac; }
  lsof() { printf 'COMMAND PID USER FD TYPE NAME\nXorg 123 Debian-gdm mem CHR %s\n' "$tmp/dev/dri/card1"; }
  classify_laptop_power_idle_blockers "$tmp/sys" "$tmp/drm" "$tmp/dev/dri" 0000:01:00.0 >"$tmp/xorg-blocker.out" 2>&1
)
assert_grep "Xorg DRM client is reported" "Xorg" "$tmp/xorg-blocker.out"
assert_grep "graphical-stack blocker is classified" "graphical stack is holding the NVIDIA DRM device open" "$tmp/xorg-blocker.out"
assert_grep "future remediation is diagnostic-only" "This installer does not apply that desktop-manager policy yet" "$tmp/xorg-blocker.out"
assert_grep "GDM stop proof command is shown" "sudo systemctl stop gdm3" "$tmp/xorg-blocker.out"
assert_grep "NVIDIA audio suspended is not blamed" "NVIDIA audio companion function blocking: no" "$tmp/xorg-blocker.out"

report_display_path_cross_checks "$tmp/sys" "$tmp/drm" "$tmp/proc-fb" 0000:01:00.0 >"$tmp/display-crosscheck.out"
assert_grep "Intel boot_vga is reported" "boot_vga=1: 0000:00:02.0 (Intel)" "$tmp/display-crosscheck.out"
assert_grep "Intel eDP connected is reported" "card0-eDP-1 connected" "$tmp/display-crosscheck.out"
assert_grep "NVIDIA disconnected connector is reported" "card1-HDMI-A-1 disconnected" "$tmp/display-crosscheck.out"
assert_grep "display routing not requiring NVIDIA is recognized" "Active display routing does not appear to require the NVIDIA dGPU" "$tmp/display-crosscheck.out"

# NVIDIA connector connected: report possible display wiring blocker rather than userspace-only certainty.
setup_hybrid_sysfs connected
(
  mock_common_power_state
  command_exists() { case "$1" in lsof|systemctl) return 0 ;; *) return 1 ;; esac; }
  lsof() { printf 'COMMAND PID USER FD TYPE NAME\nXorg 123 Debian-gdm mem CHR %s\n' "$tmp/dev/dri/card1"; }
  classify_laptop_power_idle_blockers "$tmp/sys" "$tmp/drm" "$tmp/dev/dri" 0000:01:00.0 >"$tmp/nvidia-connected.out" 2>&1
)
assert_grep "NVIDIA connected connector is possible display blocker" "NVIDIA display wiring: at least one NVIDIA connector is connected" "$tmp/nvidia-connected.out"
assert_not_grep "connected NVIDIA display avoids userspace-only root cause" "graphical stack is holding the NVIDIA DRM device open" "$tmp/nvidia-connected.out"

# lsof absent, fuser present: still reports DRM client process.
setup_hybrid_sysfs disconnected
(
  mock_common_power_state
  command_exists() { case "$1" in fuser|systemctl) return 0 ;; *) return 1 ;; esac; }
  fuser() {
    if [[ "${1:-}" == "-v" ]]; then
      printf '                     USER        PID ACCESS COMMAND\n%s: Debian-gdm 123 F.... Xorg\n' "$tmp/dev/dri/card1"
      return 0
    fi
    return 0
  }
  classify_laptop_power_idle_blockers "$tmp/sys" "$tmp/drm" "$tmp/dev/dri" 0000:01:00.0 >"$tmp/fuser-blocker.out" 2>&1
)
assert_grep "fuser fallback reports Xorg" "Xorg" "$tmp/fuser-blocker.out"
assert_grep "fuser fallback classifies graphical-stack blocker" "graphical stack is holding the NVIDIA DRM device open" "$tmp/fuser-blocker.out"

# Neither lsof nor fuser: inspection skipped, not a false no-client result.
setup_hybrid_sysfs disconnected
(
  mock_common_power_state
  command_exists() { case "$1" in systemctl) return 0 ;; *) return 1 ;; esac; }
  classify_laptop_power_idle_blockers "$tmp/sys" "$tmp/drm" "$tmp/dev/dri" 0000:01:00.0 >"$tmp/no-tools.out" 2>&1
)
assert_grep "missing inspection tools are reported" "inspection skipped" "$tmp/no-tools.out"
assert_not_grep "missing inspection tools are not reported as no clients" "No NVIDIA DRM clients were reported" "$tmp/no-tools.out"

# systemd-logind alone is reported but not overstated as the sole root cause.
setup_hybrid_sysfs disconnected
(
  mock_common_power_state
  command_exists() { case "$1" in lsof|systemctl) return 0 ;; *) return 1 ;; esac; }
  lsof() { printf 'COMMAND PID USER FD TYPE NAME\nsystemd-logind 88 root mem CHR %s\n' "$tmp/dev/dri/card1"; }
  classify_laptop_power_idle_blockers "$tmp/sys" "$tmp/drm" "$tmp/dev/dri" 0000:01:00.0 >"$tmp/logind-only.out" 2>&1
)
assert_grep "logind-only holder is reported carefully" "supporting evidence, not the sole root cause" "$tmp/logind-only.out"
assert_not_grep "logind-only holder does not get graphical-stack root cause" "graphical stack is holding the NVIDIA DRM device open" "$tmp/logind-only.out"

# Nonstandard DRM numbering: card7/renderD145 also maps and diagnoses without card1/renderD129 assumptions.
rm -rf "$tmp/sys" "$tmp/drm" "$tmp/dev"
mkdir -p "$tmp/sys/0000:01:00.0/drm/card7" "$tmp/sys/0000:01:00.0/drm/renderD145" "$tmp/dev/dri"
printf '0x10de\n' > "$tmp/sys/0000:01:00.0/vendor"
: > "$tmp/dev/dri/card7"
: > "$tmp/dev/dri/renderD145"
expected_nodes=$(printf '%s\n%s' "$tmp/dev/dri/card7" "$tmp/dev/dri/renderD145")
assert_eq "nonstandard DRM numbering maps from sysfs" \
  "$expected_nodes" \
  "$(drm_dev_nodes_for_bdf 0000:01:00.0 "$tmp/sys" "$tmp/dev/dri")"

if (( failures )); then
  printf '\n%d DRM diagnostic test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf '\nAll laptop power DRM diagnostic tests passed.\n'
