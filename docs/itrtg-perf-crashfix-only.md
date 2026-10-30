# Husk ITRTG — performance + crash-fix test build (no Google)

This branch is based directly on `perf/unity6-gpu-compositor` and carries **only** the following experimental changes relative to upstream:

- Unity 6 anonymous `mmap` / JIT code-region misclassification workaround in `husk-tl-bionic-io.c`, preserving the working ITRTG startup path.
- First-failed-shader diagnostics and GLES compatibility changes in `husk-tl-egl.c`.
- SIGTRAP crash diagnostics in the Unity translation-layer signal handler and iOS crash report, preserving the JIT guard behavior.
- **ITRTG-only GPU-shared compositor**, avoiding repeated per-frame GPU → CPU → GPU texture copies when working; fallback to CPU readback on a GL error or when `TL_DISABLE_GPU_COMPOSITOR=1`. The Java renderer now supports this shared path.
- Direct GitHub Release IPA and update of the same Feather source previously supplied to the tester.

**Explicitly excluded:** `OfficialPlayGames.swift`, all modified Google Play Games JNI and OAuth implementation, Google sign-in UI, iCloud/Files backup feature. Standard Husk's Play Games behavior stays signed out.

## Verification

The GitHub Actions workflow builds and packages an unsigned/ad-hoc IPA from Husk 3.1 runtime plus the compiled branch's native executable. Feather signs it before installing on a device. iOS device-side startup, rendering behavior and crash fixes remain experimental and need tester validation. Do not claim official Google Play Games cloud saves work.

Feather source (original stable URL):
https://raw.githubusercontent.com/La2o/husk/refs/heads/debug/itrtg-sigtrap/feather-itrtg.json

If this build crashes, collect the next Husk log and Apple SIGTRAP .ips report.
