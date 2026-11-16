# NVIDIA CUDA installer laptop-power hardening bundle, revision v7

This bundle contains a hardened Debian 13 NVIDIA/CUDA installer derived from the current laptop-power v6 bundle. It preserves the existing Debian 12 branch-580 vendoring path and does not add hardware allowlists, new mandatory online checks, or lab-only refusals for ordinary NVIDIA/CUDA package variance.

Files:

- `nvidia-cuda-installer.sh` - patched installer.
- `tests/test_laptop_power_helpers.sh` - pure helper and low-level behavior coverage for laptop detection, Runtime D3 parsing and decisions, BDF sibling derivation, managed-file sentinel handling, dry-run non-mutation, nvidia-persistenced mask ownership, topology decisions, PRIME helper ownership, and nvidia-smi CSV parsing.
- `tests/test_laptop_power_policy_behaviors.sh` - higher-level policy behavior coverage for dry-run non-mutation across the real policy path, explicit unsafe-topology refusal before mutation, ambiguous hybrid explicit-on behavior, preflight collision prevention, global lock behavior, production PATH sanitization, test override gating, managed branch-580 artifact cleanup, conflict diagnostics, fresh-install Runtime D3 unavailable behavior, and check-mode PRIME helper ownership reporting.
- `tests/test_laptop_power_drm_diagnostics.sh` - hermetic coverage for NVIDIA BDF to DRM-node mapping, GDM/Xorg DRM-client blocker classification, display-route cross-checks, fuser fallback, missing-inspection-tool behavior, systemd-logind-only handling, and nonstandard DRM numbering.
- `tests/test_driver_validation.sh` - hermetic coverage for post-reboot driver validation, including cuda-drivers installed, cuda-drivers absent with a demonstrably working driver, cuda-drivers absent with a broken driver, and DKMS status reporting that does not disagree with the detailed context.
- `nvidia-cuda-installer-laptop-power-v7.patch` - unified diff from the prior v6 bundle installer to this revision.
- `SHA256SUMS` - hashes for the bundle contents.

## Hardening through v6

- In the historical v6/v7 implementation, adds a global `flock` execution lock under `/run/lock` or `/tmp`. **Correction (November 15, 2026):** in Debian 13, a stale file in either sticky world-writable directory can prevent subsequent root/non-root runs even after `flock` releases, because `fs.protected_regular=2` and file ownership prevent reopening it. The v8 code moves the root lock to `/run/nvidia-cuda-installer/lock` and makes `--check` / `--dry-run` unlocked and read-only. See [v8 recovery notes](installer-kernel-recovery-v8-notes.md).
- Sanitizes production execution `PATH` to `/usr/sbin:/usr/bin:/sbin:/bin` near the top of the script.
- Gates test-only managed path overrides behind `NVIDIA_CUDA_INSTALLER_TEST_MODE=1`. Production runs refuse polluted override environments instead of honoring `sudo -E` state accidentally.
- Preflights laptop-power managed-file and ownership collisions before changing persistence mode, writing udev or modprobe files, changing systemd mask state, or touching sysfs.
- Preserves the ownership-safe `nvidia-persistenced.service` mask behavior: the script only records a mask marker when it creates the mask, and remove/reset only unmask when that marker proves ownership.
- Adds managed cleanup for the local branch-580 vendor APT source, preferences, keyring, repo directory, and work directory when ownership can be proven. It leaves admin-owned files in place and warns instead of guessing.
- Adds branch-580 vendor rebuild preflight for every exact managed vendor path before mutation. Existing source, preferences, keyring, repo directory, and work directory paths must be absent or script-owned before the script installs vendor prerequisites, writes sentinels, exports keyrings, overwrites preferences, or removes/rebuilds the local repo directory. This is an ownership guard only; it does not change branch-580 matching, package selection, dependency resolution, or fallback policy.
- Adds a conservative `gpg`-missing ownership fallback for an already-managed branch-580 vendor keyring. If `gpg` is unavailable, the script may infer keyring ownership only when multiple surrounding managed branch-580 artifacts prove a prior script-owned vendor installation. This prevents a previous managed keyring from becoming stranded after `gnupg` removal without accepting arbitrary keyrings at the managed path.
- Removes the managed branch-580 keyring before the surrounding source/preferences/repo/work artifacts so that this fallback proof remains available during remove/reset cleanup.
- Adds diagnostic conflict scans for unmanaged NVIDIA modprobe and udev power-policy overrides, including `NVreg_DynamicPowerManagement`, `NVreg_PreserveVideoMemoryAllocations`, and NVIDIA PCI runtime-PM rules that force `power/control` to `on`.
- Keeps conflict scans diagnostic. Ambiguous real-world policy variance gets reported, not treated as a hard installer failure.
- Keeps topology guardrails realistic: automatic laptop power policy still requires confident portable hybrid detection; explicit `--laptop-power=on` refuses high-confidence non-target systems but allows ambiguous hybrid systems with warnings.
- Adds NVIDIA DRM/display-client diagnostics for the class of failure where Runtime D3 policy is correct but a graphical stack keeps the NVIDIA DRM node open.

## Driver validation change in v7

`--check` now treats `cuda-drivers` as an installation provenance signal rather than a required functional proof. If the metapackage is installed, the script reports `PASS: cuda-drivers package is installed`. If it is absent but the NVIDIA driver is demonstrably working through `nvidia-smi`, `modinfo nvidia`, loaded NVIDIA modules, and/or NVIDIA DKMS entries, the script reports a warning and continues required validation. If `cuda-drivers` is absent and the driver is not functional, validation still fails.

This preserves real driver failure detection while avoiding a false failure on hosts where the NVIDIA driver stack is already installed and working through manual, Debian-packaged, or otherwise preexisting NVIDIA driver state. The APT policy summary remains in `--check` output for provenance diagnostics.

The DKMS status check now captures `dkms status` before matching it, avoiding a pipefail/SIGPIPE path where the summary could warn that no NVIDIA DKMS entries exist while the detailed context later lists them.

## Runtime D3 and DRM-client diagnostics

The laptop idle-power check now distinguishes two classes of users:

- `/dev/nvidia*` clients usually indicate CUDA, NVML, NVIDIA API, or persistence-style users.
- `/dev/dri/*` clients indicate DRM/display/render users. A display manager or compositor can hold `/dev/dri/cardN` or `/dev/dri/renderD*` open even when no CUDA process is using `/dev/nvidia*`.

For each NVIDIA PCI BDF, the script maps DRM nodes through sysfs, for example `/sys/bus/pci/devices/<BDF>/drm/cardN` and `/sys/bus/pci/devices/<BDF>/drm/renderD*`, then reports the corresponding `/dev/dri/cardN` and `/dev/dri/renderD*` nodes. It does not assume `card1`, `renderD129`, GDM, Xorg, Intel iGPU, or any fixed DRM numbering.

`--check` reports display-route evidence, including `boot_vga=1`, connected DRM connectors by GPU vendor, NVIDIA connector state, framebuffer owner from `/proc/fb`, and clients holding NVIDIA DRM nodes. It prefers `lsof` for client inspection and falls back to `fuser -v`; if neither tool exists, it says inspection was skipped rather than claiming there are no clients.

`--check-laptop-power-idle` still reads runtime PM counters, waits 60 seconds without invoking `nvidia-smi`, and reads them again. If idle progress does not occur, it now classifies likely blockers. When Runtime D3 is enabled, PCI runtime PM is `auto`, persistence is disabled, no `/dev/nvidia*` clients exist, NVIDIA connectors are disconnected, the companion NVIDIA audio function is suspended or not blocking, and a graphical process such as `Xorg`, `gdm3`, `gnome-shell`, or `mutter` holds the NVIDIA DRM node, it prints a high-confidence diagnostic:

> The NVIDIA dGPU is configured for runtime suspend, but the graphical stack is holding the NVIDIA DRM device open. This commonly prevents Runtime D3 idle suspend even when CUDA clients are absent.

`systemd-logind` is handled carefully. The script reports it when it holds a DRM node, but does not treat `systemd-logind` alone as the root cause unless another graphical process is also present or other evidence points to runtime usage.

If GDM/Xorg appears to be the blocker, the script recommends a proof step only:

```sh
sudo systemctl stop gdm3
sleep 120
cat /sys/bus/pci/devices/<BDF>/power/runtime_status
sudo systemctl start gdm3
```

Stopping GDM interrupts the graphical session. Run that proof step only from SSH or a TTY. The installer does not yet apply desktop-manager policy. A future remediation could configure GDM/Xorg not to auto-open the NVIDIA DRM device on hybrid laptops, preserving Intel-primary display with explicit PRIME/CUDA offload.

## Rollback and ownership model

`--reset` and `--remove-only` remove script-owned laptop-power files and managed branch-580 vendor artifacts when the script can prove ownership through sentinels, exact managed content, key material identifying the script's local signing UID, conservative surrounding managed vendor-state proof when `gpg` is unavailable, or local-repo metadata. They do not delete arbitrary NVIDIA/CUDA APT configuration, admin-created modprobe files, admin-created udev rules, third-party `prime-run` helpers, or admin-owned files that happen to occupy the script's managed vendor paths.

Branch-580 vendor rebuilds use the same ownership discipline before they mutate anything. If an admin-owned file or directory already exists at one of the exact managed vendor paths, the script fails with diagnostics instead of overwriting, claiming, or deleting it.

Disabling `nvidia-persistenced.service` is treated as administrator policy after it happens. Remove/reset does not re-enable the service. If `--laptop-power-aggressive` created a managed mask, remove/reset can unmask it; if the service was already masked by an administrator, the script neither claims nor removes that mask.

## Validation from the extracted bundle directory

```sh
bash -n ./nvidia-cuda-installer.sh
bash -n ./tests/test_laptop_power_helpers.sh
bash -n ./tests/test_laptop_power_policy_behaviors.sh
bash -n ./tests/test_laptop_power_drm_diagnostics.sh
bash -n ./tests/test_driver_validation.sh
./tests/test_laptop_power_helpers.sh
./tests/test_laptop_power_policy_behaviors.sh
./tests/test_laptop_power_drm_diagnostics.sh
./tests/test_driver_validation.sh
sha256sum -c ./SHA256SUMS
```

`shellcheck` was not installed in the generation sandbox, so shellcheck was not executed there.
