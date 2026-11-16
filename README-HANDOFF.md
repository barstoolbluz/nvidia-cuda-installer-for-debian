# Kernel-upgrade recovery: audited remediation handoff

**Date:** November 15, 2026
**Specification:** `docs/kernel-upgrade-recovery-brief.md`
**Baseline:** `5501104`
**Previous delivery:** `16b4c54` on `feature/kernel-upgrade-recovery-v8`
**V9 remediation branch:** `fix/kernel-upgrade-recovery-audit-r1`
**V10 second-pass branch:** `fix/kernel-upgrade-recovery-audit-r2` (continues V9)
**V11 third-pass branch:** `fix/kernel-upgrade-recovery-audit-r3` (continues V10)

## Scope and implementation

Six reproducible defects from the independent audit were corrected in
`nvidia-cuda-installer.sh`, with integration/fault-injection cases in
`tests/test_kernel_upgrade_recovery.sh`:

| Audit finding | Correction | Representative regression |
| --- | --- | --- |
| 1. Unloaded module reported healthy despite actual Secure Boot rejection; stale loaded modules treated as healthy | `module-present-load-unverified` distinguishes kmod discovery from insertion. Live recovery calls `modprobe` and verifies the loaded module. Loaded-versus-file and NVML mismatch evidence prevents healthy results; reboot advised without GRUB fallback. | `secure-boot-dryrun-succeeds-load-fails`, `loaded-module-version-stale`, `loaded-userspace-mismatch` |
| 2. Older 535/390 drivers on legacy GPUs allowed an incompatible current upgrade | Classify GPUs via existing PCI-ID/name heuristics, independently of installed package version. Current upgrade requires affirmative compatibility for every GPU, including under `-y`; unknown hardware fails closed. | `pascal-old-535-driver`, `kepler-old-390-driver`, `unknown-gpu-no-auto-upgrade` |
| 3. Stale DKMS record enabled broken GRUB fallback | In addition to installed image and DKMS record, require a matching `modinfo -k` NVIDIA version and present `/boot` kernel image and initramfs before finding a GRUB entry or scheduling a one-shot boot. Describe it as a candidate, since loadability cannot be proved before boot. | `stale-fallback-module`, `stale-fallback-boot-artifacts`, `legacy-fallback-approved` |
| 4. Old DKMS reinstall failed before a compatible upgrade could run | With modern GPU compatibility and consent established, upgrade `cuda-drivers` first. Rebuild the resulting source; try one `nvidia-kernel-dkms` reinstall only if rebuilding still fails. Avoids triggering the incompatible old package post-install script first. | `modern-incompatible-reinstall-fails`, `modern-candidate-replaces-dkms-source`, `modern-build-fails` |
| 5. Optional DRM load failure broke headless CUDA recovery | Keep base NVIDIA and CUDA UVM failures fatal. A failed DRM or modeset module logs a warning without failing headless recovery, unless the initramfs explicitly requires DRM. | `headless-optional-drm-failure`, `explicitly-required-drm-failure` |
| 6. Secure Boot lockdown reported as EPERM omitted MOK guidance | When Secure Boot is enabled and insertion returns EPERM, read recent `dmesg` for a matching `Lockdown: modprobe` unsigned-module rejection before giving signing/enrollment advice. No automatic signing or enrollment. | `secure-boot-lockdown-eperm`, `unrelated-eperm-without-lockdown` |

**Specification conflict:** Sections 3.3 and 6.4 of the original brief
propose reinstalling the old DKMS source before upgrading the modern driver.
The reported APT post-install failure demonstrates why that ordering can block
a compatible upgrade. Remediation deliberately attempts the approved upgrade
first and reinstalls the resulting DKMS source only when needed. This is a
scoped departure from the literal order to meet the recovery objective.

All fixes preserve `--reset` separation, the lock-directory correction, the
original GPU policy for fresh installs, and the dry-run mutation barrier.
`fix-xorg-gdm-idle.sh` and the four preexisting test scripts are unchanged.

## Independent second-pass return (V10)

The second auditor returned two additional defects. Both were reproduced
against V9 before the production correction and now have hermetic regressions:

| Finding | V10 correction | Regression evidence |
| --- | --- | --- |
| Missing CUDA UVM module allowed false recovery/validation success when the base driver and `nvidia-smi` worked | The shared probe requires UVM module discovery, DKMS rechecks and force-repairs missing UVM, recovery requires its load, and read-only `--check` reports the missing module | `missing-uvm-loaded`, `missing-uvm-repairable`, `automatic-missing-uvm-repair`, `missing-uvm-dryrun` |
| Unpinned Turing R580 was misclassified as legacy | Explicit 470/580 pins and legacy GPUs remain constrained. Unpinned R580 on an affirmatively compatible Turing-or-newer host may enter the consented modern upgrade path | `unpinned-turing-580-modern`, `pinned-turing-580-legacy`, `unpinned-pascal-580-legacy` |

Fallback candidate qualification also requires a matching CUDA UVM module on
the older kernel. `stale-fallback-uvm` reproduces the unsafe V9 selection.
The existing driver-validation test's positive fixture was amended solely to
represent a functional CUDA installation with UVM present.

The V10 test commit (`82a29fa`) reproduced 12 failures against the V9 code.
The production correction is `53f4ec8`. Neither change touches the driver's
reset path or alters the existing consent and ownership protections.

## Independent third-pass return (V11)

The third auditor returned two further defects affecting the V10 CUDA UVM
recovery path. Both were demonstrated by the separate tests-only commit
`de91cd8`: **14 assertions failed against unmodified V10 production code**.
The correction is `6f2ade8`.

| Finding | V11 correction | Regression evidence |
| --- | --- | --- |
| A discoverable but unloadable UVM was classified healthy if the base driver and `nvidia-smi` worked | A read-only probe now requires UVM to be actually loaded (`lsmod` name `nvidia_uvm`). If present but unloaded, it reports `module-present-load-unverified` and nonzero validation; live recovery attempts insertion, retaining Secure Boot diagnostics on failure | `available-uvm-rejected-by-secure-boot`, `available-uvm-loads-successfully`, `check-autoloads-only-base-module` |
| Dry-run hid the forced DKMS reinstall for a missing UVM file despite an installed DKMS record | When either required module file is initially missing, the plan describes the conditional `dkms install nvidia/<version> -k <kernel> --force` that live recovery may perform after autoinstall | `missing-uvm-dryrun` and `missing-uvm-repairable` |

Read-only checks never insert UVM. The module file and base driver alone are
insufficient to certify CUDA readiness. Conversely, repair succeeds once the
required UVM module loads and the shared probe observes it. An installed and
already loaded UVM incurs no additional module mutations on repeat repair.

## Verification

- The extended recovery test suite had 30 failed assertions before the initial
  repairs; all passed after. Three secondary regression assertions caught an
  unsafe stale-module fallback and a configured-DRM failure, which were then
  corrected. A final test also caught a false `--check` failure when
  `nvidia-smi` triggered successful module loading; the probe now runs after
  that validation. Red and green output is in `verification-remediation/`.
- V10 passed 181 kernel-recovery assertions per account. V11 adds the
  third-pass regressions and passes all five suites as root and `nobody`:
  **205 recovery assertions plus 18 + 20 + 62 + 70 retained assertions per
  account, 375 per account and 750 total**.
- `bash -n`, `git diff --check`, Git-object integrity and archive hashes are
  included in delivery verification.
- **ShellCheck criterion 9 remains NOT VERIFIED.** ShellCheck is unavailable
  locally; neither the executable nor a cached package is present.
  Do not represent this criterion as passed.
- No physical Debian 13 NVIDIA host, live APT/DKMS transaction, GRUB reboot,
  or Secure Boot enrollment was used for the tests. Such integration validation
  is separate from the hermetic acceptance tests.

## Reproduce the verification

```bash
bash -n nvidia-cuda-installer.sh fix-xorg-gdm-idle.sh tests/test_*.sh
for suite in tests/test_*.sh; do bash "$suite"; done
git diff --check 5501104..HEAD
git fsck --no-reflogs --full
```

To complete acceptance criterion 9 on a machine with ShellCheck installed:

```bash
shellcheck nvidia-cuda-installer.sh
# Compare against inherited issues from the original baseline.
git show 5501104:nvidia-cuda-installer.sh > /tmp/nvidia-installer-baseline.sh
shellcheck /tmp/nvidia-installer-baseline.sh
```

This V11 branch is self-contained and retains the complete Git history from
the original specification through V10. Continue from its branch tip, not the
original archive, if further audit corrections are requested.
