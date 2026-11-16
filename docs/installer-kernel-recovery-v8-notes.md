# NVIDIA CUDA installer: kernel-upgrade recovery (v8 through v11 corrections, November 15, 2026)

This revision repairs the situation in which APT installed and booted a new
Debian 13 kernel without its matching headers. The previously installed NVIDIA
DKMS module remains available only for older kernels; installed driver packages
alone do not imply a functional module for `uname -r`.

## Entry points and convergence

- `sudo ./nvidia-cuda-installer.sh --repair-kernel` repairs a previously
  installed driver and exits. `--dry-run` shows planned steps without writing
  to the system. `-y` consents to separately guarded recovery fallbacks.
- A normal install invocation probes the running kernel before skipping an
  installed driver. Missing modules trigger the same recovery path. A working
  driver with missing header tracking is repaired before reporting no changes.
- `--check` uses the same single primary-state probe, reports missing
  `linux-headers-<running-kernel>` as a detail, and prints the repair command
  when the running-kernel module is missing. The existing validation and
  `cuda-drivers` provenance reporting are retained.

The probe states are `healthy`, `module-missing-for-running-kernel`,
`module-present-load-unverified`, `module-present-not-loadable`, `build-failed`
(after an attempted DKMS build), and `no-driver`. `headers-missing` is a
separate diagnostic detail. A successful `modprobe --dry-run` shows only that
the module is discoverable; it never establishes loadability or passes the
kernel's Secure Boot signature check. An unloaded module remains unverified
until a real load succeeds. For an already loaded module, the probe detects
affirmative loaded-versus-installed version differences and NVML's explicit
driver/library mismatch. `healthy` also requires that `modinfo nvidia-uvm` find the CUDA UVM
module for the running kernel **and** that `lsmod` show it loaded as
`nvidia_uvm`. The base driver and `nvidia-smi` can work even if UVM insertion
would fail under Secure Boot. A present but unloaded UVM is reported as
`module-present-load-unverified`. `--check` fails rather than certifying this
state as healthy, and never inserts a module; live recovery attempts a real
`modprobe nvidia-uvm` followed by the shared probe.

## Recovery procedure and exits

1. Install the running kernel's versioned headers and the architecture's
   `linux-headers-amd64` or `linux-headers-arm64` metapackage, unless already
   present. Require APT candidates for missing packages. No candidate for a
   locally built or discontinued kernel triggers boot-fallback guidance.
2. Derive the source version from `dkms status`. Run `dkms autoinstall -k`;
   if it succeeds without installing the NVIDIA module, run an explicit
   `dkms install nvidia/<version> -k`. Verify the installed DKMS status.
   If DKMS reports installed but either the base or UVM module is absent,
   force a targeted reinstall and verify both files again.
   The `--dry-run` plan includes this conditional `dkms install ... --force`
   operation when either required module file is initially missing, without
   running DKMS or performing filesystem mutations.
3. Load the NVIDIA base module and present supplementary modules, re-probe,
   restart an enabled/failed `nvidia-persistenced.service`, and regenerate
   the current initramfs only when its module configuration includes
   `nvidia-drm`. An optional DRM failure is diagnostic on headless hosts;
   a missing or failed UVM load or DRM explicitly configured for the initramfs
   is fatal.
   A stale loaded module/userspace mismatch requires reboot into the current
   kernel and does not schedule an older-kernel fallback.
4. On a DKMS build failure, display the final 40 lines of `make.log`. For
   legacy GPUs (including Pascal/Kepler on older 535/390 installations),
   preserve the driver. An R580 version alone does not identify a legacy
   installation: explicit 470/580 pinning packages and GPU families take
   precedence. An unpinned Turing R580 host may use modern recovery. For modern
   GPUs, first verify every detected NVIDIA GPU is current-branch compatible;
   then, only with explicit consent, upgrade
   `cuda-drivers` before trying to reinstall a DKMS source. This avoids an
   incompatible old DKMS post-install script blocking the upgrade. If the
   upgrade/rebuild does not restore the module, try one source reinstall.
5. Intersect installed `linux-image-*` packages with the NVIDIA DKMS records
   marked installed. Then require matching base NVIDIA and CUDA UVM modules
   via `modinfo -k`,
   the kernel image, the initramfs, and the exact entry in generated GRUB
   configuration before offering `grub-reboot`. This establishes disk-level
   eligibility, not proof that Secure Boot/driver initialization will succeed
   after boot. The installer never deletes kernels. Boot selection and
   `apt-mark hold` still require consent.

Exit `0` means the running kernel's module is healthy (or a dry-run plan was
printed). Exit `3` means the kernel could not be repaired, including cases
where a future boot into an older kernel was scheduled. Exit `1` is used for
other errors or invalid requests.

`--repair-kernel` does not purge driver packages, change branch policy, edit
administrator-owned GRUB/APT/udev/modprobe files, or attempt MOK enrollment.
A Secure Boot signature rejection is diagnostic only: it names the Debian DKMS
MOK key location and the required reboot into MokManager. When `modprobe`
returns `Operation not permitted`, a recent kernel `Lockdown: modprobe`
unsigned-module rejection can establish the cause; unrelated EPERM results
do not trigger signing advice.

A modern-branch upgrade after a failed build is an explicit opt-in exception to the normal
no-reinstall rule.

## Lock-file correction

The old `/run/lock/nvidia-cuda-installer.lock` and `/tmp` fallback were in
sticky world-writable directories. Linux `fs.protected_regular=2` can deny a
later `sudo` invocation access to an existing file owned by the non-root
`--check` user, or deny the reverse access. Released `flock` state does not
remove that ownership conflict. The old v7 statement that stale lock files
could never block future runs was incorrect.

Root writes a lock in a root-owned, non-world-writable directory,
`/run/nvidia-cuda-installer/lock` (directory mode `0755`). It warns on a
foreign-owned legacy lock, and removes a root-owned legacy lock only if it
can acquire the old lock first. Read-only `--check` and `--dry-run` take no
lock and write no persistent lock file. The test-only lock override remains
available under `NVIDIA_CUDA_INSTALLER_TEST_MODE=1`.

## Verification

Run the four existing hermetic suites plus
`tests/test_kernel_upgrade_recovery.sh`. The latter mocks the incident's
older-kernel-only NVIDIA DKMS installation, added-state autoinstall, missing
APT candidates, modern/legacy build failures, confirmation gates, exact GRUB
menu discovery, load-versus-dry-run signature rejection, kernel lockdown
EPERM, mismatched loaded/userspace versions, GPU compatibility, stale DKMS
fallback records, failed old DKMS package configuration, optional DRM,
service/initramfs actions, and read-only locking behavior. It uses temp fixtures and shell-function mocks,
without invoking real APT, DKMS, modprobe, or host-system configuration.
