#!/usr/bin/env bash
# fix-xorg-gdm-idle.sh
#
# Diagnose and mitigate one specific NVIDIA hybrid-laptop idle-power failure mode:
# a local Xorg server, often GDM's Xorg greeter, auto-adds the NVIDIA DRM card as
# a secondary GPU device and keeps the dGPU runtime-active.
#
# Mitigation written by this script:
#
#   Section "ServerFlags"
#       Option "AutoAddGPU" "off"
#   EndSection
#
# Scope: Xorg only.
# This Xorg ServerFlags option does not control Mutter/Wayland GPU enumeration.
# Mutter/Wayland uses udev/logind/KMS device handling. A Wayland-specific idle
# power blocker must be diagnosed separately. This script can still be relevant
# on systems where GDM falls back to an Xorg greeter, or where local Xorg user
# sessions are used.
#
# This script does not blacklist NVIDIA drivers, unload NVIDIA modules, change
# nvidia-drm.modeset, change CUDA, change nvidia-persistenced, or edit GDM
# Wayland settings.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2026-07-07.5"
SCRIPT_NAME=${0##*/}
CONF="/etc/X11/xorg.conf.d/90-no-nvidia-gpuscreen.conf"
BACKUP_DIR="/var/backups/fix-xorg-gdm-idle"
STATE_FILE="$BACKUP_DIR/state.env"
MARKER="Managed by fix-xorg-gdm-idle.sh"

ACTION="diagnose"
RESTART=0
FORCE=0
WAIT_SECONDS=120
OFFLOAD_CMD=()

NV_CARD=""
NV_BDF=""
NV_VENDOR=""
NV_DRIVER=""
NV_COUNT=0
BOOT_CARD=""
BOOT_BDF=""
BOOT_DRV=""
BOOT_VENDOR=""
BOOT_COUNT=0

info()  { printf '  %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }
warn()  { printf 'WARNING: %s\n' "$*" >&2; }
die()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF_USAGE
$SCRIPT_NAME $VERSION

Usage:
  sudo $SCRIPT_NAME diagnose
  sudo $SCRIPT_NAME apply [--restart] [--force]
  sudo $SCRIPT_NAME verify [--wait SECONDS] [--offload-command COMMAND [ARG ...]]
  sudo $SCRIPT_NAME rollback [--restart] [--force]
  sudo $SCRIPT_NAME --help

Default action is: diagnose

Scope:
  This script targets local Xorg servers only. It writes an Xorg ServerFlags
  snippet with Option "AutoAddGPU" "off". That option does not control
  Mutter/Wayland GPU enumeration. Mutter/Wayland uses udev/logind/KMS device
  handling, so a Wayland-specific idle-power blocker must be diagnosed
  separately.

What apply does:
  Writes this file atomically:
    $CONF

  with this Xorg-only mitigation:
    Section "ServerFlags"
        Option "AutoAddGPU" "off"
    EndSection

Safety defaults:
  * Does not restart GDM unless --restart is supplied.
  * Refuses to restart GDM over active non-GDM graphical sessions unless --force
    is supplied.
  * Refuses to apply unless it positively identifies a safe non-NVIDIA Intel
    primary display GPU, currently Intel vendor 0x8086 with i915 or xe, unless
    --force is supplied.
  * Refuses to apply if NVIDIA-owned display connectors are connected, unless
    --force is supplied.
  * Does not assume /dev/dri/card0, card1, or any fixed DRM card number.

Verify tests only:
  * idle runtime suspend before intentional NVIDIA use,
  * intentional NVIDIA wake via prime-run nvidia-smi, nvidia-smi, or your custom
    --offload-command,
  * return to runtime suspend afterward.

Verify does not fully validate every CUDA, OpenGL, Vulkan, EGL, NVENC, or PRIME
render-offload workflow. To test your own path, pass it as the final option:

  sudo $SCRIPT_NAME verify --offload-command prime-run nvidia-smi
  sudo $SCRIPT_NAME verify --offload-command bash -lc 'prime-run glxinfo -B'

Rollback:
  sudo $SCRIPT_NAME rollback --restart

Options:
  --restart              Restart the detected GDM unit after apply/rollback.
  --no-restart           Explicitly do not restart GDM. This is the default.
  --force                Override guarded safety checks.
  --wait SECONDS         Seconds to wait for runtime suspend in verify.
  --offload-command ...  Command to run during verify instead of default.
  --test-command ...     Alias for --offload-command.
  -h, --help             Show this help.

Exit codes:
  0  Success: action completed (diagnose: dGPU runtime-suspended, no fix
     needed or fix already working).
  1  Error: preconditions failed, refused without --force, or verify failed.
  2  Diagnose only: dGPU is not runtime-suspended; a fix may be applicable.
  4  Apply/rollback with --restart: the config change itself SUCCEEDED, but
     the GDM restart was deferred (active user sessions, or no GDM unit
     positively identified). Restart the display manager to finish.
     Automation must not treat 4 as "nothing changed".
EOF_USAGE
}

parse_args() {
    local action_seen=0
    while (($#)); do
        case "$1" in
            diagnose|apply|verify|rollback)
                if (( action_seen )); then
                    die "only one action may be supplied"
                fi
                ACTION="$1"
                action_seen=1
                shift
                ;;
            --restart)
                RESTART=1
                shift
                ;;
            --no-restart)
                RESTART=0
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --wait)
                shift
                (($#)) || die "--wait requires a value"
                [[ "$1" =~ ^[0-9]+$ ]] || die "--wait must be an integer number of seconds"
                WAIT_SECONDS="$1"
                shift
                ;;
            --offload-command|--test-command)
                shift
                (($#)) || die "--offload-command requires a command"
                OFFLOAD_CMD=("$@")
                set --
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "run as root, for example: sudo ./$SCRIPT_NAME $ACTION"
}

read_first_line() {
    local path=$1
    [[ -r "$path" ]] || return 1
    IFS= read -r line < "$path" || return 1
    printf '%s\n' "$line"
}

is_plain_drm_card() {
    local base=${1##*/}
    [[ "$base" =~ ^card[0-9]+$ ]]
}

discover_gpus() {
    local card base bdf drv vendor boot
    NV_CARD=""; NV_BDF=""; NV_VENDOR=""; NV_DRIVER=""; NV_COUNT=0
    BOOT_CARD=""; BOOT_BDF=""; BOOT_DRV=""; BOOT_VENDOR=""; BOOT_COUNT=0

    for card in /sys/class/drm/card[0-9]*; do
        [[ -e "$card" ]] || continue
        is_plain_drm_card "$card" || continue
        [[ -e "$card/device" ]] || continue
        [[ -e "$card/device/driver" ]] || continue

        base=${card##*/}
        bdf=$(basename "$(readlink -f "$card/device")")
        drv=$(basename "$(readlink -f "$card/device/driver")")
        vendor=$(read_first_line "$card/device/vendor" 2>/dev/null || true)
        boot=$(read_first_line "$card/device/boot_vga" 2>/dev/null || true)

        if [[ "$drv" == "nvidia" ]]; then
            ((NV_COUNT += 1))
            if [[ -z "$NV_CARD" ]]; then
                NV_CARD=$base
                NV_BDF=$bdf
                NV_VENDOR=$vendor
                NV_DRIVER=$drv
            fi
        fi

        if [[ "$boot" == "1" ]]; then
            ((BOOT_COUNT += 1))
            if [[ -z "$BOOT_CARD" ]]; then
                BOOT_CARD=$base
                BOOT_BDF=$bdf
                BOOT_DRV=$drv
                BOOT_VENDOR=$vendor
            fi
        fi
    done
}

pm() {
    local field=$1
    [[ -n "$NV_BDF" ]] || return 1
    read_first_line "/sys/bus/pci/devices/$NV_BDF/power/$field" 2>/dev/null || true
}

connected_nvidia_connectors() {
    local connector status
    [[ -n "$NV_CARD" ]] || return 0
    for connector in /sys/class/drm/"$NV_CARD"-*; do
        [[ -e "$connector/status" ]] || continue
        status=$(read_first_line "$connector/status" 2>/dev/null || true)
        [[ "$status" == "connected" ]] && printf '%s\n' "$(basename "$connector")"
    done
}

is_safe_intel_primary() {
    [[ -n "$BOOT_BDF" ]] || return 1
    [[ -n "$BOOT_DRV" ]] || return 1
    [[ "$BOOT_VENDOR" == "0x8086" ]] || return 1
    case "$BOOT_DRV" in
        i915|xe) return 0 ;;
        *) return 1 ;;
    esac
}

nvidia_holders() {
    local node pid comm
    [[ -n "$NV_CARD" ]] || return 0
    node="/dev/dri/$NV_CARD"
    [[ -e "$node" ]] || return 0

    if ! command -v lsof >/dev/null 2>&1; then
        warn "lsof is unavailable; cannot list /dev/dri/$NV_CARD holders"
        return 0
    fi

    lsof -t -- "$node" 2>/dev/null | sort -u | while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        comm=$(tr -d '\0' < "/proc/$pid/comm" 2>/dev/null || true)
        case "$comm" in
            systemd|systemd-logind) ;;
            *) printf '%s %s\n' "$pid" "${comm:-unknown}" ;;
        esac
    done
}

unit_load_state() {
    local unit=$1
    systemctl show "$unit" -p LoadState --value 2>/dev/null || true
}

gdm_unit() {
    local unit state
    for unit in gdm3.service gdm.service; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            printf '%s\n' "$unit"
            return 0
        fi
    done

    for unit in gdm3.service gdm.service; do
        state=$(unit_load_state "$unit")
        if [[ "$state" == "loaded" ]]; then
            printf '%s\n' "$unit"
            return 0
        fi
    done

    return 1
}

active_graphical_user_sessions() {
    local sid name class type state

    loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' | while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        name=$(loginctl show-session "$sid" -p Name --value 2>/dev/null || true)
        class=$(loginctl show-session "$sid" -p Class --value 2>/dev/null || true)
        type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)
        state=$(loginctl show-session "$sid" -p State --value 2>/dev/null || true)

        case "$name" in
            Debian-gdm|gdm) continue ;;
        esac

        case "$class" in
            greeter|manager|manager-early) continue ;;
        esac

        case "$type" in
            x11|wayland)
                printf '%s user=%s type=%s class=%s state=%s\n' \
                    "$sid" "${name:-unknown}" "${type:-unknown}" "${class:-unknown}" "${state:-unknown}"
                ;;
        esac
    done
}

restart_gdm_if_requested() {
    local sessions unit

    if (( ! RESTART )); then
        info "not restarting GDM; pass --restart when ready to apply the change to the greeter"
        return 0
    fi

    sessions=$(active_graphical_user_sessions || true)
    if [[ -n "$sessions" && "$FORCE" -ne 1 ]]; then
        warn "active non-GDM graphical session(s) detected:"
        printf '%s\n' "$sessions" >&2
        warn "configuration change succeeded, but refusing to restart GDM because that can log users out"
        warn "restart later manually, or re-run the restart action with --force only if intentional"
        warn "exiting with status 4: change staged, GDM restart deferred"
        return 4
    fi

    if ! unit=$(gdm_unit); then
        warn "configuration change succeeded, but could not positively identify an installed or active GDM unit"
        warn "not restarting automatically; restart the correct display-manager unit manually"
        warn "exiting with status 4: change staged, GDM restart deferred"
        return 4
    fi

    info "restarting $unit"
    systemctl restart "$unit"
}

desired_config() {
    cat <<EOF_CONF
# $MARKER
# Xorg-only mitigation for Intel-primary NVIDIA hybrid laptops.
# Prevent local Xorg servers from auto-adding the NVIDIA dGPU as a secondary GPU device.
# This does not control Mutter/Wayland GPU enumeration; Wayland uses udev/logind/KMS.
# Rollback: sudo $SCRIPT_NAME rollback --restart
Section "ServerFlags"
    Option "AutoAddGPU" "off"
EndSection
EOF_CONF
}

file_equals_desired_config() {
    local path=$1
    [[ -f "$path" ]] || return 1
    desired_config | cmp -s - "$path"
}

conf_has_marker() {
    [[ -f "$CONF" ]] || return 1
    grep -Fq "$MARKER" "$CONF"
}

conf_looks_related() {
    [[ -f "$CONF" ]] || return 1
    grep -Eq 'fix-xorg-gdm-idle|fix-gdm-nvidia-idle|AutoAddGPU' "$CONF"
}

timestamp() { date +%Y%m%d-%H%M%S; }

backup_existing_conf() {
    local reason=$1 backup_dir backup
    [[ -e "$CONF" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    backup_dir=$(mktemp -d "$BACKUP_DIR/$reason.$(timestamp).$$.XXXXXX")
    backup="$backup_dir/$(basename "$CONF")"
    cp -a -- "$CONF" "$backup"
    info "backed up existing config to $backup"
}

state_value() {
    local key=$1
    [[ -f "$STATE_FILE" ]] || return 1
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE_FILE"
}

write_initial_state_if_missing() {
    local backup backup_dir
    mkdir -p "$BACKUP_DIR"
    chmod 0755 "$BACKUP_DIR"

    if [[ -f "$STATE_FILE" ]]; then
        return 0
    fi

    if [[ -e "$CONF" ]]; then
        backup_dir=$(mktemp -d "$BACKUP_DIR/preapply.$(timestamp).$$.XXXXXX")
        backup="$backup_dir/$(basename "$CONF")"
        cp -a -- "$CONF" "$backup"
        {
            printf 'HAD_CONF=1\n'
            printf 'RESTORE_BACKUP=%s\n' "$backup"
        } > "$STATE_FILE"
        chmod 0644 "$STATE_FILE"
        info "recorded pre-apply restore state in $STATE_FILE"
        info "original config snapshot: $backup"
    else
        {
            printf 'HAD_CONF=0\n'
            printf 'RESTORE_BACKUP=\n'
        } > "$STATE_FILE"
        chmod 0644 "$STATE_FILE"
        info "recorded pre-apply state: no prior $CONF"
    fi
}

write_desired_config_atomically() {
    local dir tmp
    dir=$(dirname "$CONF")
    mkdir -p "$dir"
    tmp=$(mktemp "$dir/.90-no-nvidia-gpuscreen.conf.tmp.XXXXXX")
    desired_config > "$tmp"
    chown root:root "$tmp"
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$CONF"
}

candidate_xorg_logs() {
    {
        printf '%s\n' \
            /var/lib/gdm3/.local/share/xorg/Xorg.0.log \
            /var/lib/gdm3/.local/share/xorg/Xorg.0.log.old \
            /var/lib/gdm/.local/share/xorg/Xorg.0.log \
            /var/lib/gdm/.local/share/xorg/Xorg.0.log.old \
            /var/log/gdm3/Xorg.0.log \
            /var/log/gdm/Xorg.0.log \
            /var/log/Xorg.0.log
        find /var/lib/gdm3 /var/lib/gdm /run/gdm3 /run/gdm /var/log/gdm3 /var/log/gdm \
            -maxdepth 5 -type f \( -iname '*xorg*.log' -o -iname 'Xorg.*.log' \) \
            -print 2>/dev/null || true
    } | awk '!seen[$0]++' | while IFS= read -r path; do
        [[ -r "$path" ]] && printf '%s\n' "$path"
    done
}

print_xorg_gpu_evidence() {
    local log found=0 line
    if [[ -z "$NV_CARD" ]]; then
        info "no NVIDIA DRM card discovered; cannot check Xorg GPU evidence"
        return 0
    fi

    while IFS= read -r log; do
        [[ -n "$log" ]] || continue
        line=$(grep -E "modeset\(G[0-9]+\): using drv /dev/dri/$NV_CARD|Adding drm device \(/dev/dri/$NV_CARD\)|systemd-logind: got fd for /dev/dri/$NV_CARD" "$log" 2>/dev/null | tail -n 5 || true)
        if [[ -n "$line" ]]; then
            found=1
            info "$log"
            printf '%s\n' "$line" | sed 's/^/    /'
        fi
    done < <(candidate_xorg_logs)

    if (( ! found )); then
        info "no NVIDIA Xorg GPU-screen evidence found in common GDM/GDM3 Xorg log paths"
        info "this evidence probe is best-effort; distributions may log Xorg elsewhere"
    fi
}

print_scope_note() {
    head_ "Scope"
    info "This script targets local Xorg servers only."
    info "The AutoAddGPU snippet does not control Mutter/Wayland GPU enumeration."
    info "Wayland/Mutter idle-power blockers must be diagnosed separately."
}

print_topology() {
    head_ "GPU topology from sysfs"
    if [[ -n "$NV_BDF" ]]; then
        info "NVIDIA dGPU: /dev/dri/$NV_CARD -> $NV_BDF driver=$NV_DRIVER vendor=$NV_VENDOR"
        if (( NV_COUNT > 1 )); then
            warn "multiple DRM cards bound to the nvidia driver were found; using first discovered card"
        fi
    else
        info "No DRM card bound to the nvidia driver was found."
    fi

    if [[ -n "$BOOT_BDF" ]]; then
        info "boot_vga primary: /dev/dri/$BOOT_CARD -> $BOOT_BDF driver=$BOOT_DRV vendor=$BOOT_VENDOR"
        if (( BOOT_COUNT > 1 )); then
            warn "multiple boot_vga devices were found; primary GPU state is ambiguous"
        fi
    else
        warn "no boot_vga primary DRM device was found"
    fi
}

check_apply_preconditions() {
    local connectors

    [[ -n "$NV_BDF" ]] || die "no NVIDIA DRM card found; refusing to write Xorg mitigation"

    if (( NV_COUNT != 1 )) && (( FORCE != 1 )); then
        die "expected exactly one NVIDIA DRM card; found $NV_COUNT. Re-run with --force only if intentional."
    fi

    if (( BOOT_COUNT != 1 )) && (( FORCE != 1 )); then
        die "primary GPU state is missing or ambiguous; refusing to apply unless --force is supplied"
    fi

    if [[ -z "$BOOT_BDF" || -z "$BOOT_DRV" || -z "$BOOT_VENDOR" ]]; then
        if (( FORCE != 1 )); then
            die "could not positively identify a safe non-NVIDIA primary display GPU; refusing unless --force is supplied"
        fi
        warn "--force supplied with incomplete primary-GPU information"
    elif [[ "$BOOT_BDF" == "$NV_BDF" ]]; then
        if (( FORCE != 1 )); then
            die "NVIDIA appears to be boot_vga primary; refusing because this can break local graphics"
        fi
        warn "--force supplied even though NVIDIA appears to be primary"
    elif ! is_safe_intel_primary; then
        if (( FORCE != 1 )); then
            die "primary GPU is not positively identified as Intel i915/xe vendor 0x8086; refusing unless --force is supplied"
        fi
        warn "--force supplied with non-Intel or unknown primary GPU: driver=$BOOT_DRV vendor=$BOOT_VENDOR bdf=$BOOT_BDF"
    fi

    connectors=$(connected_nvidia_connectors || true)
    if [[ -n "$connectors" ]]; then
        if (( FORCE != 1 )); then
            warn "NVIDIA-owned display connector(s) appear connected:"
            printf '%s\n' "$connectors" >&2
            die "refusing because AutoAddGPU off can disable NVIDIA-wired displays in Xorg; re-run with --force only if intentional"
        fi
        warn "--force supplied with NVIDIA-owned connector(s) connected: $connectors"
    fi
}

diagnose() {
    local holders connectors unit control status usage

    print_scope_note
    print_topology

    head_ "GDM unit detection"
    if unit=$(gdm_unit); then
        info "detected GDM unit: $unit"
    else
        warn "could not positively detect gdm3.service or gdm.service"
    fi

    head_ "Display stack"
    if pgrep -x Xorg >/dev/null 2>&1; then
        info "Xorg process(es) detected:"
        ps -o pid,user,comm,args -C Xorg 2>/dev/null || true
    else
        warn "no Xorg process detected"
        warn "if the blocker is Wayland/Mutter, this Xorg AutoAddGPU mitigation may not address it"
    fi

    if pgrep -x gnome-shell >/dev/null 2>&1; then
        info "gnome-shell process(es) detected"
    fi

    if [[ -n "$NV_BDF" ]]; then
        head_ "NVIDIA runtime PM ($NV_BDF)"
        control=$(pm control)
        status=$(pm runtime_status)
        usage=$(pm runtime_usage)
        info "control=${control:-unknown} status=${status:-unknown} usage=${usage:-unknown}"
        [[ "$control" == "auto" ]] || warn "NVIDIA power/control is not auto; this script does not change runtime-PM policy"
    fi

    head_ "NVIDIA display connectors"
    connectors=$(connected_nvidia_connectors || true)
    if [[ -n "$connectors" ]]; then
        warn "connected NVIDIA-owned connector(s):"
        printf '%s\n' "$connectors" >&2
    else
        info "no connected NVIDIA-owned DRM connectors found"
    fi

    head_ "Non-logind holders of NVIDIA DRM card"
    holders=$(nvidia_holders || true)
    if [[ -n "$holders" ]]; then
        printf '%s\n' "$holders" | sed 's/^/  /'
    else
        info "none found"
    fi

    head_ "Xorg GPU evidence"
    print_xorg_gpu_evidence

    head_ "Managed config"
    if [[ -e "$CONF" ]]; then
        if file_equals_desired_config "$CONF"; then
            info "$CONF is present and exactly matches desired config"
        elif conf_has_marker; then
            warn "$CONF contains this script's marker but differs from desired config"
        else
            warn "$CONF exists but does not exactly match this script's desired config"
        fi
    else
        info "$CONF is not present"
    fi

    head_ "Verdict"
    if [[ -n "$NV_BDF" && "$(pm runtime_status)" == "suspended" && "$(pm runtime_usage)" == "0" ]]; then
        info "NVIDIA dGPU is currently runtime-suspended."
        if [[ -e "$CONF" ]]; then
            info "The Xorg mitigation appears active or staged."
        fi
        return 0
    fi

    if pgrep -x Xorg >/dev/null 2>&1 && [[ -n "$NV_BDF" ]]; then
        info "If Xorg is holding /dev/dri/$NV_CARD runtime-active, apply may help."
        info "Run: sudo ./$SCRIPT_NAME apply --restart"
        return 2
    fi

    info "No clear Xorg AutoAddGPU blocker was proven by this diagnostic pass."
    return 2
}

apply() {
    check_apply_preconditions

    write_initial_state_if_missing

    if [[ -e "$CONF" ]] && file_equals_desired_config "$CONF"; then
        info "$CONF already contains the desired config; apply is idempotent"
    else
        if [[ -e "$CONF" ]]; then
            backup_existing_conf "preoverwrite"
            if ! conf_looks_related && (( FORCE != 1 )); then
                die "$CONF exists but does not look related to this script; backed it up but refusing to overwrite without --force"
            fi
        fi
        write_desired_config_atomically
        info "wrote $CONF"
    fi

    restart_gdm_if_requested
}

run_as_invoking_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        sudo -u "$SUDO_USER" -- "$@"
    else
        "$@"
    fi
}

format_command() {
    local arg first=1
    for arg in "$@"; do
        if (( first )); then
            first=0
        else
            printf ' '
        fi
        printf '%q' "$arg"
    done
    printf '\n'
}

wait_for_nvidia_suspend() {
    local deadline now status usage
    deadline=$((SECONDS + WAIT_SECONDS))
    while (( SECONDS <= deadline )); do
        status=$(pm runtime_status)
        usage=$(pm runtime_usage)
        if [[ "$status" == "suspended" && "$usage" == "0" ]]; then
            return 0
        fi
        sleep 5
    done
    now=$(date)
    warn "timed out at $now waiting for NVIDIA runtime suspend; status=$(pm runtime_status) usage=$(pm runtime_usage)"
    return 1
}

verify() {
    local cmd=() holders
    [[ -n "$NV_BDF" ]] || die "no NVIDIA DRM card found"

    print_scope_note

    head_ "Verify: idle suspend before intentional NVIDIA use"
    info "waiting up to ${WAIT_SECONDS}s for $NV_BDF to be runtime-suspended"
    if ! wait_for_nvidia_suspend; then
        holders=$(nvidia_holders || true)
        [[ -n "$holders" ]] && { warn "non-logind holders of /dev/dri/$NV_CARD:"; printf '%s\n' "$holders" >&2; }
        exit 1
    fi
    info "idle suspend PASS: status=$(pm runtime_status) usage=$(pm runtime_usage)"

    head_ "Verify: intentional NVIDIA wake"
    if ((${#OFFLOAD_CMD[@]})); then
        cmd=("${OFFLOAD_CMD[@]}")
        info "running custom test command as ${SUDO_USER:-root}: $(format_command "${cmd[@]}")"
    elif command -v prime-run >/dev/null 2>&1; then
        cmd=(prime-run nvidia-smi)
        info "running default wake command as ${SUDO_USER:-root}: $(format_command "${cmd[@]}")"
    else
        cmd=(nvidia-smi)
        info "running default wake command as ${SUDO_USER:-root}: $(format_command "${cmd[@]}")"
    fi

    if run_as_invoking_user "${cmd[@]}"; then
        info "intentional NVIDIA wake command completed"
    else
        die "intentional NVIDIA wake command failed"
    fi

    head_ "Verify: return to runtime suspend after intentional use"
    info "waiting up to ${WAIT_SECONDS}s for $NV_BDF to return to runtime suspend"
    if wait_for_nvidia_suspend; then
        info "return-to-suspend PASS: status=$(pm runtime_status) usage=$(pm runtime_usage)"
    else
        holders=$(nvidia_holders || true)
        [[ -n "$holders" ]] && { warn "non-logind holders of /dev/dri/$NV_CARD:"; printf '%s\n' "$holders" >&2; }
        exit 1
    fi

    info "verify complete. This tested suspend, wake, and return-to-suspend only; it did not fully validate every graphics or compute offload workflow."
}

rollback() {
    local had restore state_archive

    mkdir -p "$BACKUP_DIR"

    if [[ -e "$CONF" ]]; then
        if file_equals_desired_config "$CONF"; then
            backup_existing_conf "rollback-remove"
        elif conf_has_marker; then
            if (( FORCE != 1 )); then
                warn "$CONF contains this script's marker but differs from the generated desired config"
                warn "it appears manually modified; refusing to remove or replace it without --force"
                return 1
            fi
            backup_existing_conf "rollback-force-remove-modified"
        else
            if (( FORCE != 1 )); then
                warn "$CONF exists but does not contain this script's marker"
                warn "refusing to touch it without --force"
                return 1
            fi
            backup_existing_conf "rollback-force-unmarked"
        fi
    fi

    had=$(state_value HAD_CONF 2>/dev/null || printf '0')
    restore=$(state_value RESTORE_BACKUP 2>/dev/null || true)

    if [[ "$had" == "1" ]]; then
        [[ -n "$restore" && -f "$restore" ]] || die "state says a prior config existed, but restore backup is missing: $restore"
        mkdir -p "$(dirname "$CONF")"
        cp -a -- "$restore" "$CONF"
        info "restored pre-apply config from $restore"
    else
        if [[ -e "$CONF" ]]; then
            rm -f -- "$CONF"
            info "removed $CONF"
        else
            info "$CONF is already absent"
        fi
    fi

    if [[ -f "$STATE_FILE" ]]; then
        state_archive="$BACKUP_DIR/state.env.rolledback.$(timestamp)"
        mv -f -- "$STATE_FILE" "$state_archive"
        info "archived rollback state to $state_archive"
    fi

    restart_gdm_if_requested
}

main() {
    parse_args "$@"
    require_root
    discover_gpus

    case "$ACTION" in
        diagnose) diagnose ;;
        apply) apply ;;
        verify) verify ;;
        rollback) rollback ;;
        *) die "unknown action: $ACTION" ;;
    esac
}

main "$@"

# Artifact build marker: hardened-v4-20260707 connector-filtered handoff file.
