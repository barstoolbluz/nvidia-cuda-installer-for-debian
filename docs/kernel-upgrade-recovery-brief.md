# Brief: kernel-upgrade recovery and convergence hardening for `nvidia-cuda-installer.sh`

Audience: an implementing engineer or reasoning model working in this repo.
Status: specification. Nothing in this brief has been implemented yet.
Written: 2026-11-15, from a live incident on a Debian 13 desktop with a GTX 1080 Ti.

---

## 1. The incident that motivates this work

A Debian 13 (Trixie) host running the branch-580 driver installed by this script
through its managed Debian 12 vendor-repo fallback lost its NVIDIA driver after
an ordinary `apt` upgrade. Timeline, reconstructed from `/var/log/apt/history.log`
and `dkms status`:

| Time (local) | Event |
|---|---|
| 13:11 | `linux-image-amd64` metapackage pulled in `linux-image-6.12.117+deb13-amd64` as an automatic dependency. No matching headers were installed because `linux-headers-amd64` was not present. The `/etc/kernel/postinst.d/dkms` hook ran but had nothing to build against. |
| 14:13 | Reboot into 6.12.117. No `nvidia` module exists for this kernel. `nvidia-persistenced.service` fails at boot. `nvidia-smi` reports "couldn't communicate with the NVIDIA driver". |
| 17:24 | A non-root `./nvidia-cuda-installer.sh --check` run creates `/run/lock/nvidia-cuda-installer.lock` owned by the invoking user. |
| 17:26 | `sudo ./nvidia-cuda-installer.sh --dry-run -y` fails: `line 389: /run/lock/nvidia-cuda-installer.lock: Permission denied`. Root cannot open a file owned by another user in a sticky world-writable directory when `fs.protected_regular=2`, which is the Debian 13 default. |
| 17:27 | After the stale lock was deleted, `sudo ./nvidia-cuda-installer.sh -y` ran to completion and changed nothing. It saw installed driver packages, printed "Existing NVIDIA driver state was detected. Skipping driver install/reset", evaluated laptop-power policy (not applicable on a desktop), and exited 0. |
| 17:27 | Manual fix: `apt-get install linux-headers-6.12.117+deb13-amd64 linux-headers-amd64`. The `/etc/kernel/header_postinst.d/dkms` hook built `nvidia/580.173.02` for 6.12.117 during that install. `modprobe nvidia && nvidia-smi` then worked without a reboot. |

State of the host before the fix, for reference:

- GPU: `01:00.0 NVIDIA GP102 [GeForce GTX 1080 Ti] [10de:1b06]` (Pascal, so branch 580 by this script's policy).
- Running kernel: `6.12.117+deb13-amd64`. Installed kernels: 6.12.94, 6.12.101, 6.12.117. All three remain bootable.
- `dkms status`: `nvidia/580.173.02, 6.12.94+deb13-amd64, x86_64: installed` and nothing else.
- Headers installed: 6.12.94 only. `linux-headers-amd64`: not installed.
- Driver packages: full 580.173.02 set plus `nvidia-driver-pinning-580 580-5`, all from the local vendor repo at `/opt/nvidia-driver-580-local-repo` (sourced via `/etc/apt/sources.list.d/nvidia-driver-580-local-vendor.list`, a `file:` URI, so no network is needed to reinstall from it).
- Secure Boot: disabled. So module signing was not a factor here, but it must be a factor in the design (see 4.4).

## 2. Defects to fix

### 2.1 The convergence check is too shallow

`main()` (around line 4922) decides the install is complete if
`has_installed_driver_packages || nonpackaged_nvidia_runtime_present`. It never
asks whether a kernel module exists for the running kernel. The exact failure
in section 1, which is the single most common way a working NVIDIA install breaks
on Debian, is invisible to the script's install path. The script's own `--check`
mode did detect the failure (modinfo fails, nvidia-smi fails), but the install
path does not consult the same evidence.

### 2.2 Headers are pinned to one kernel

`HEADER_PACKAGE="linux-headers-$(uname -r)"` (line 27) and `install_headers()`
(line 2724) install only the versioned header package for the kernel running at
install time. The script never installs the `linux-headers-amd64` metapackage,
so when `linux-image-amd64` pulls a new kernel, no headers follow, and DKMS has
nothing to build against. Every kernel point release re-creates section 1.

### 2.3 The execution lock lives in a sticky world-writable directory

`installer_lock_file()` (line 356) chooses `/run/lock` when writable, else
`/tmp`. Both are sticky and world-writable. `acquire_execution_lock()` (line
373) does `exec 9>"$lock_file"`, which creates the file owned by whoever runs
first. `require_root()` (line 298) exempts `--check` and `--dry-run` from
needing root, so an unprivileged `--check` is a supported and documented
workflow. The combination means:

- A non-root `--check` leaves a user-owned lock file.
- Every later `sudo` invocation fails at the `exec 9>` with "Permission denied"
  under `fs.protected_regular=2`.
- The reverse also holds: after any `sudo` run the lock is root-owned (mode
  0644), so the documented non-root `--check` fails the same way. This was
  observed on the incident host immediately after the fix.

`docs/installer-laptop-power-v7-notes.md` currently claims "a stale file does
not block future runs". That claim is false on Debian 13 and the doc must be
corrected.

## 3. New capability: kernel-upgrade recovery ("I installed a new kernel and my driver is gone")

Add a first-class recovery mode that repairs an existing, previously working
install after a kernel change, without purging or reinstalling driver packages
and without network access when it can be avoided. It must work for both of the
script's driver families:

- **Modern** (`current` branch, Turing and newer, packages from NVIDIA's Debian
  13 repo).
- **Legacy** (`580` branch for Maxwell/Pascal/Volta, usually from the managed
  Debian 12 vendor repo; and `470` for Kepler when `--allow-legacy-470` was
  used).

The two families differ in one critical way for recovery: a modern branch can
always be rebuilt or upgraded from the online repo, whereas a legacy branch may
have a DKMS source tree that no longer compiles against a newer kernel and has
no newer release to upgrade to. The recovery path must handle "the module will
never build for this kernel" as an expected outcome, not an error to crash on.

### 3.1 Invocation

Provide an explicit entry point and an automatic one:

- `--repair-kernel` (name negotiable; `--fix-kernel` or `--rebuild` are
  acceptable). Runs recovery and exits. Requires root. Honours `--dry-run`
  and `-y`.
- When the plain install path (`main()` with no `--reset`) finds installed
  driver packages, it must run the convergence probe in 3.2 instead of exiting.
  If the probe says "module missing for the running kernel", it runs the same
  recovery path automatically and says so. The existing "Existing NVIDIA driver
  state was detected. No changes made." message must only be printed when the
  probe passes.

### 3.2 Convergence probe (what "installed and working" means)

Define one function, used by both the install path and `--check`, that
classifies the host into exactly one state. Suggested states:

| State | Evidence |
|---|---|
| `healthy` | `modinfo nvidia` succeeds for `$(uname -r)` AND either the module is loaded or `modprobe --dry-run nvidia` succeeds. `nvidia-smi` working is confirmatory, not required (it fails harmlessly when no process has opened the device yet on some setups). |
| `module-missing-for-running-kernel` | Driver packages installed, `dkms status` lists `nvidia/<ver>` for some kernel but not for `$(uname -r)`, or lists it as `added`/`built` but not `installed`. This is the section 1 state. |
| `headers-missing` | Sub-state of the above: `linux-headers-$(uname -r)` not installed. Recovery must fix this first. |
| `module-present-not-loadable` | Module file exists for the running kernel but `modprobe` fails. Distinguish Secure Boot signature rejection (`dmesg`/`modprobe` error mentions key or signature; `mokutil --sb-state` enabled) from nouveau holding the device from a version mismatch between userspace libraries and the module (nvidia-smi says "Driver/library version mismatch"). |
| `build-failed` | DKMS attempted a build for the running kernel and failed. Capture `/var/lib/dkms/nvidia/<ver>/build/make.log`. |
| `no-driver` | No driver packages and no runtime traces. Existing fresh-install path applies. |

The probe must be hermetic-testable: every external command it uses
(`dkms status`, `modinfo`, `modprobe --dry-run`, `uname -r`, `dpkg-query`,
`mokutil`) must go through an overridable function, following the existing
pattern in `tests/test_driver_validation.sh` where `package_installed`,
`command_exists`, `dkms_status_output`, etc. are redefined inside a subshell.

### 3.3 Recovery procedure

In order. Each step is skipped when its precondition is already met, logged
when run, and simulated under `--dry-run`.

1. **Install headers for the running kernel** plus the `linux-headers-amd64`
   metapackage (or the architecture-appropriate equivalent; the script already
   refuses non-amd64 at line 611). `require_candidate` both. If the versioned
   header package has no candidate (the running kernel is not from a configured
   repo, e.g. a locally built or removed kernel), say so and go to step 5.
2. **Rebuild the module.** Prefer `dkms autoinstall -k "$(uname -r)"`, falling
   back to `dkms install nvidia/<ver> -k "$(uname -r)"` when `autoinstall` is
   a no-op because the module is in `added` state. Determine `<ver>` from
   `dkms status`, not from a package version string. Do not assume the apt
   header hook already did it; verify with `dkms status` afterwards.
3. **Load and verify.** `modprobe nvidia`, then `modprobe nvidia-uvm`,
   `nvidia-modeset`, `nvidia-drm` as present. Rerun the probe. Restart
   `nvidia-persistenced.service` if it is enabled and failed. Regenerate the
   initramfs for the running kernel if `nvidia-drm` is in the initramfs
   configuration, otherwise skip. Report whether a reboot is needed; after a
   successful in-place rebuild it normally is not.
4. **On build failure, diagnose rather than retry.** Show the last 40 lines of
   `make.log`. Then branch on family:
   - **Modern branch:** offer `apt-get install --reinstall nvidia-kernel-dkms`
     followed by an upgrade of `cuda-drivers` from the online repo, because a
     newer driver that supports the kernel may exist. Only with `-y` or explicit
     confirmation.
   - **Legacy branch (580 vendor, 470):** state plainly that no newer driver
     exists for this GPU family. Do not purge. Do not fall back to `current`
     branch; `validate_branch_for_inventory` already refuses that. Go to
     step 5.
5. **Fallback: boot a kernel that still has a module.** Enumerate installed
   `linux-image-*` packages and intersect with kernels listed in `dkms status`
   as `installed` for the nvidia module. On the incident host that set is
   `{6.12.94}`. Print the exact GRUB menu entry and a one-shot
   `grub-reboot` command for it, and explain how to pin it with
   `apt-mark hold` on the kernel metapackage. Never run `grub-reboot` or
   `apt-mark hold` without `-y` or confirmation. Never remove a kernel.
6. **Prevent recurrence.** After any successful recovery, ensure
   `linux-headers-amd64` is installed (step 1 did this) and tell the user that
   the DKMS header hook will now rebuild on future kernel upgrades. If
   `unattended-upgrades` is present, mention that kernel upgrades via it will
   now also rebuild.

### 3.4 Secure Boot

The script already warns at `check_secure_boot()` (line 2669). Recovery must
go further: if `mokutil --sb-state` reports enabled and the probe is
`module-present-not-loadable` with a signature error, say that the rebuilt
module needs signing with the DKMS MOK (`/var/lib/dkms/mok.key` on Debian 13
when `dkms` was configured for signing) and that enrollment requires a reboot
into MokManager. Do not attempt enrollment. This path is diagnostic-only in
this revision.

## 4. Fixes to the existing defects

### 4.1 Lock placement

Move the default lock to a root-owned, non-sticky directory:
`/run/nvidia-cuda-installer/lock` (create with `install -d -m 0755`, root
only). Rules:

- When running as root: use that path. Remove any legacy
  `/run/lock/nvidia-cuda-installer.lock` owned by root; warn and skip if it is
  owned by someone else.
- When not root (`--check`, `--dry-run` without sudo): do not take the global
  lock at all if the directory is not writable. Log that the run is unlocked
  and read-only. `--check` never mutates, so the lock is not needed for
  correctness there. If `--dry-run` without root reaches a code path that
  would need the lock, it is already simulated.
- Keep `NVIDIA_CUDA_INSTALLER_LOCK_FILE` as the test-mode override. Existing
  tests in `tests/test_laptop_power_policy_behaviors.sh` (around line 195 to
  212) exercise concurrent rejection and release; they must keep passing.
- The `exec 9>` failure must produce a specific diagnostic naming the owner of
  the existing file and `fs.protected_regular`, so the next person does not
  have to rediscover this.

### 4.2 Headers

`install_headers()` installs both `linux-headers-$(uname -r)` and
`linux-headers-amd64`. `preflight_install_plan()` (line 2770) must simulate
both. The `--check` context output should report whether the metapackage is
installed, as a WARN when absent, because its absence is the leading
indicator of the next section-1 incident.

### 4.3 Convergence in `main()`

Replace the `has_installed_driver_packages || nonpackaged_nvidia_runtime_present`
early-exit with a call to the 3.2 probe. The laptop-power policy-only branch
must still run when requested, but after recovery, not instead of it.

### 4.4 `--check` must use the same probe

`run_post_reboot_check()` (line 4826) should report the probe's state by name
in its summary, and when the state is `module-missing-for-running-kernel` it
must print the one-line remedy: `sudo ./nvidia-cuda-installer.sh --repair-kernel`.
The existing PASS/WARN/FAIL lines and the `cuda-drivers` provenance handling
from v7 stay as they are.

## 5. Constraints that must hold

These come from the repo's existing safety model (README, v7 notes). Do not
weaken them.

- No purge or reinstall of driver packages during recovery. `--reset` stays
  the only destructive path and is never implied.
- Ownership discipline: recovery only creates files in its own directories
  (`/run/nvidia-cuda-installer/`, DKMS build trees) and never claims or
  deletes admin-owned modprobe, udev, APT, or GRUB files.
- `--dry-run` never mutates. Every `apt-get`, `dkms`, `modprobe`, `systemctl`,
  `update-initramfs`, and `grub-reboot` call in the new code goes through a
  wrapper that logs and returns under dry-run. Follow `run_apt_get()` (line
  402) as the model.
- Production PATH sanitization and the `NVIDIA_CUDA_INSTALLER_TEST_MODE`
  override gate are unchanged.
- The branch policy is unchanged. Recovery must not change which branch is
  installed. It operates on whatever `dkms status` says is present.
- Hermetic tests only. No test may touch real `/run`, `/etc`, `/var/lib/dkms`,
  or call real `apt-get`, `dkms`, or `modprobe`.

## 6. Acceptance criteria

The work is done when all of the following hold.

1. Reproducing the section-1 host state in a hermetic test (driver packages
   installed, `dkms status` listing only an older kernel, headers absent for
   the running kernel) and running `main` without `--reset` results in: headers
   installed (mocked), `dkms` rebuild invoked for the running kernel (mocked),
   `modprobe` invoked, probe reports `healthy`, exit 0. The message "No changes
   made" is not printed.
2. The same state with `--repair-kernel --dry-run` prints every step it would
   take and mutates nothing. A recorded-calls assertion proves no mock mutator
   was invoked.
3. Legacy family with a mocked DKMS build failure: no `apt-get` upgrade or
   purge is attempted, `make.log` tail is printed, the list of bootable kernels
   with an installed module is printed with the exact `grub-reboot` command,
   exit code is non-zero and distinct from a generic error (suggest 3).
4. Modern family with a mocked DKMS build failure: the reinstall/upgrade path
   is offered and, under `-y`, invoked (mocked).
5. Lock: a non-root `--check` followed by a root install in the same test
   harness both succeed. A test that pre-creates a foreign-owned legacy lock
   file (simulated via a mock `stat`) produces the diagnostic naming the owner
   and `fs.protected_regular`.
6. `--check` on the section-1 state prints the state name and the
   `--repair-kernel` remedy line.
7. All four existing test scripts in `tests/` pass unchanged except where this
   brief explicitly changes behaviour (the "stale lock does not block" claim
   and the headers simulation list).
8. `docs/installer-laptop-power-v7-notes.md` is amended, or a v8 notes file is
   added, describing the probe, recovery mode, lock relocation, and the
   corrected lock-file claim. README gains a "My driver broke after a kernel
   upgrade" section with the one-line command.
9. `shellcheck` reports no new findings on the script.

## 7. Non-goals

- Signing modules or enrolling MOK keys.
- Installing or managing the CUDA toolkit.
- Changing laptop-power behaviour or `fix-xorg-gdm-idle.sh`.
- Supporting kernels not installed from a configured APT repo beyond the
  "no header candidate" diagnostic.
- Migrating the branch-580 vendor repo mechanism. It already works offline via
  a `file:` source, which is exactly what recovery needs.

## 8. Reference: relevant symbols in the current script

| Symbol | Line | Note |
|---|---|---|
| `HEADER_PACKAGE` | 27 | Versioned only; see 2.2 |
| `require_root()` | 298 | Exempts `--check` and `--dry-run` |
| `installer_lock_file()` | 356 | Chooses `/run/lock` or `/tmp`; see 2.3 |
| `acquire_execution_lock()` | 373 | `exec 9>` at 389 is where it fails |
| `run_apt_get()` | 402 | Dry-run-aware wrapper to copy for `dkms`/`modprobe` |
| `require_candidate()` | 1148 | Fails if apt has no candidate |
| `preflight_dpkg_state()` | 1153 | |
| `package_installed()`, `has_installed_driver_packages()`, `nonpackaged_nvidia_runtime_present()` | 2457, 2461, 2465 | Current convergence inputs |
| `reset_nvidia_driver_state()` | 2649 | Destructive; recovery must not call it |
| `check_secure_boot()` | 2669 | Warn-only today |
| `install_headers()` | 2724 | |
| `install_driver()` | 2759 | |
| `preflight_install_plan()` | 2770 | Simulates `HEADER_PACKAGE`; must add metapackage |
| `loaded_nvidia_modules()`, `dkms_status_output()`, `dkms_has_nvidia_entries()` | 4729, 4734, 4739 | Reuse in the probe |
| `run_post_reboot_check()` | 4826 | `--check` entry |
| `main()` | 4898 | Convergence early-exit at ~4922 |

Test harness conventions: `tests/test_driver_validation.sh` shows how the
script is sourced with `NVIDIA_CUDA_INSTALLER_SOURCE_ONLY=1`, how
`NVIDIA_CUDA_INSTALLER_TEST_MODE=1` plus per-path override variables redirect
every managed path into a temp dir, and how external commands are stubbed by
redefining functions inside a subshell. New tests go in a new file,
`tests/test_kernel_upgrade_recovery.sh`, following the same `ok`/`not_ok`/
`assert_grep` style and exit-code accounting.
