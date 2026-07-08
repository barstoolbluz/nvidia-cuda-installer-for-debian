# NVIDIA CUDA installer for Debian

Tooling for installing and power-tuning the NVIDIA proprietary CUDA driver
stack on Debian 13 (Trixie), with a focus on hybrid Intel + NVIDIA laptops
where the dGPU should stay in runtime D3 (suspended) except during
intentional CUDA/offload work.

The repo contains two independent scripts that address two halves of the same
problem:

| Script | Role |
|---|---|
| `nvidia-cuda-installer.sh` | Install/validate/remove the NVIDIA CUDA driver stack from NVIDIA's APT repo, and configure laptop idle-power policy (Runtime D3, persistence, udev/modprobe policy). Diagnoses — but does not fix — display-stack blockers. |
| `fix-xorg-gdm-idle.sh` | Fix one specific display-stack blocker the installer can only diagnose: a local Xorg server (typically GDM's greeter) auto-adding the NVIDIA DRM device as a secondary GPU screen, which keeps the dGPU runtime-active forever. |

Both scripts are safe-by-default: they refuse ambiguous situations rather than
guess, prove ownership before removing anything, and print explicit rollback
paths.

## nvidia-cuda-installer.sh

Installs NVIDIA proprietary CUDA driver packages from the NVIDIA APT
repository on Debian 13/Trixie.

Core behavior:

- Detects the GPU generation via `lspci` (device-ID table plus heuristics) and
  picks a driver branch policy: `auto`, `current`, `580`, or `470`
  (Maxwell/Pascal/Volta → 580; Turing and newer → current; Kepler refused
  unless `--allow-legacy-470`).
- Convergent install: a completed install reruns as a no-op. `--reset` is the
  explicit, repeatable purge-and-reinstall action; `--remove-only` purges and
  exits.
- Verifies NVIDIA repo trust via `cuda-keyring` before use; `apt-get update`
  remains the authoritative signature check.
- Includes a managed, break-glass Debian 12 branch-580 vendor fallback for
  hosts whose GPUs need branch 580 when NVIDIA's Debian 13 repo lacks it
  (guarded by explicit acknowledgment flags).
- `--check` runs post-reboot validation; `--dry-run` simulates without
  mutating; `-y` for unattended runs.

Laptop idle-power policy (`--laptop-power=auto|ask|on|off`):

- On confidently-detected hybrid laptops, configures the CUDA-friendly idle
  policy: Runtime D3 (`NVreg_DynamicPowerManagement`), PCI runtime PM
  (`power/control=auto`) via udev, and disabling `nvidia-persistenced`
  (optionally masking it with `--laptop-power-aggressive`).
- `--check-laptop-power-idle` runs validation plus a 60-second read-only idle
  probe of the sysfs runtime-PM counters (deliberately avoiding `nvidia-smi`,
  which would itself wake the GPU), then classifies likely blockers if the
  dGPU fails to suspend.
- One blocker class it can identify with high confidence but does **not**
  remediate: the graphical stack (GDM/Xorg/gnome-shell/mutter) holding the
  NVIDIA DRM node open. That remediation is `fix-xorg-gdm-idle.sh`'s job.

Ownership and rollback model: managed files carry sentinels; `--reset` /
`--remove-only` only delete files the script can prove it created. Admin-owned
modprobe files, udev rules, masks, and APT configuration are reported, never
claimed or deleted. See
[docs/installer-laptop-power-v7-notes.md](docs/installer-laptop-power-v7-notes.md)
for the detailed hardening history and rationale.

Run `./nvidia-cuda-installer.sh --help` for the full option list.

## fix-xorg-gdm-idle.sh

Diagnoses and mitigates one specific, common failure mode on Intel-primary
hybrid laptops running GDM:

> The Runtime D3 policy is entirely correct — persistence off,
> `power/control=auto`, fine-grained D3 enabled, no CUDA clients, no connected
> NVIDIA outputs — yet the dGPU never runtime-suspends while GDM is running.

Root cause: Xorg's `AutoAddGPU` option (default on) makes the X server
auto-add the NVIDIA KMS device (`nvidia-drm` with `modeset=1`) as a secondary
"GPU screen" driven by the generic `modesetting` driver. That driver holds a
runtime-PM reference on the DRM device for the life of the X server, so the
dGPU stays active — even when the GPU screen is doing nothing (on
CUDA-only installs without the NVIDIA X driver, it is a software-rendered
shadow framebuffer serving no purpose at all).

The mitigation is a single Xorg snippet, written atomically to
`/etc/X11/xorg.conf.d/90-no-nvidia-gpuscreen.conf`:

```
Section "ServerFlags"
    Option "AutoAddGPU" "off"
EndSection
```

The boot_vga (Intel) primary device is unaffected; CUDA, Vulkan, EGL, and
NVENC offload do not need an X GPU screen and keep working.

Usage:

```sh
sudo ./fix-xorg-gdm-idle.sh diagnose      # read-only; default action
sudo ./fix-xorg-gdm-idle.sh apply --restart
sudo ./fix-xorg-gdm-idle.sh verify        # suspend -> wake -> re-suspend test
sudo ./fix-xorg-gdm-idle.sh rollback --restart
```

Safety defaults:

- Maps DRM nodes to PCI devices through sysfs; never assumes `card1` or any
  fixed numbering.
- Refuses to apply unless the primary GPU is positively identified as Intel
  (vendor 0x8086, `i915`/`xe`), refuses if NVIDIA is boot_vga, and refuses if
  any NVIDIA-owned connector is currently connected (the mitigation would
  disable NVIDIA-wired displays in Xorg). `--force` overrides, deliberately.
- Never restarts GDM unless `--restart` is passed, and even then refuses over
  active non-GDM graphical sessions without `--force`.
- Backs up any pre-existing config and records pre-apply state under
  `/var/backups/fix-xorg-gdm-idle/`; `rollback` restores that state exactly.
- `verify` confirms idle suspend, wakes the GPU intentionally
  (`prime-run nvidia-smi` by default, or your own `--offload-command`), and
  confirms return to suspend.

Exit codes (stable, for automation): `0` success / nothing needed, `1` error
or refusal, `2` diagnose could not confirm a runtime-suspended dGPU (a
blocker may be present), `4` config change succeeded but the GDM restart was
deferred (finish by restarting the display manager; do **not** treat as
"nothing changed").

Scope: **Xorg only.** `AutoAddGPU` is an Xorg server flag; it does not control
Mutter/Wayland GPU enumeration, so a Wayland-side idle blocker must be
diagnosed separately (under Wayland the holder would be mutter/gnome-shell,
and the analogous controls live in udev, not xorg.conf.d).

## Typical workflow on a hybrid laptop

```sh
# 1. Install the driver stack with laptop power policy
sudo ./nvidia-cuda-installer.sh --laptop-power=on

# 2. After reboot, validate and probe idle behavior
sudo ./nvidia-cuda-installer.sh --check-laptop-power-idle

# 3. If the probe reports the graphical stack holding the NVIDIA DRM node:
sudo ./fix-xorg-gdm-idle.sh diagnose
sudo ./fix-xorg-gdm-idle.sh apply --restart
sudo ./fix-xorg-gdm-idle.sh verify
```

Expected end state with GDM running: `runtime_status=suspended` and
`runtime_usage=0` for the NVIDIA PCI function while idle, `prime-run
nvidia-smi` (or any CUDA/offload workload) wakes the GPU on demand, and the
GPU returns to suspend shortly after the workload exits.

## Tests

Hermetic test suites for the installer live in `tests/`:

```sh
./tests/test_laptop_power_helpers.sh
./tests/test_laptop_power_policy_behaviors.sh
./tests/test_laptop_power_drm_diagnostics.sh
./tests/test_driver_validation.sh
```

They cover laptop/hybrid detection, Runtime D3 decisions, DRM/BDF mapping and
blocker classification, ownership/sentinel handling, dry-run non-mutation,
and post-reboot driver validation, without touching real hardware state.

## Requirements

- Debian 13 (Trixie) for the installer; `fix-xorg-gdm-idle.sh` targets
  Debian-family systems running GDM with an Xorg greeter or Xorg sessions.
- Root (`sudo`): `fix-xorg-gdm-idle.sh` requires root for all actions,
  including the read-only `diagnose` (it inspects GDM's Xorg log and other
  users' open files). The installer's `--check` / `--check-laptop-power-idle`
  modes run without root; everything that mutates state requires it.
- `lsof` recommended for DRM-client inspection (both scripts fall back
  gracefully and say so when it is missing).

## Documentation

- [docs/installer-laptop-power-v7-notes.md](docs/installer-laptop-power-v7-notes.md)
  — detailed changelog and design rationale for the installer's laptop-power
  hardening revisions (lock/PATH/ownership discipline, branch-580 vendor
  fallback, DRM diagnostics, driver validation).
