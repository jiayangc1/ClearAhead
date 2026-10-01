# Bug audit dispositions

Reviewed against main `535fa24925ad16748e81ade64a901ce93509c1f0` after a clean
fast-forward on 2026-09-30. The GitHub connector confirmed the repository is
private. All 39 supplied findings are accounted for below.

“Implemented” means the root cause was confirmed in source and a change was
made. Swift/XCTest and physical iPhone behavior have **not** been executed on
this Windows host. Native fixes remain subject to the added macOS CI and device
checks; they are not claims of validated collision avoidance.

| # | Finding | Disposition and evidence |
|---|---|---|
| 1 | Private release downloads | Implemented. All five sizes are selectable. Nano is bundled; other pairs download from the official public Ultralytics `yolo-ios-app` release `v8.3.0`. Cellular/metered downloads require approval. |
| 2 | Invisible detector failures | Implemented. `SessionHealth` counts consecutive failures for both models and derives combined failure/recovery status. One model recovering cannot hide the other's failure. |
| 3 | No frame/inference watchdog | Implemented. A main-queue watchdog uses monotonic frame receipt and inference completion timestamps. After two seconds it clears events/overlays, cancels feedback, and reports degraded status independently of new frames. |
| 4 | Constant-depth lateral crossing | Implemented. Tracking estimates angular corridor-entry time and issues caution for stable, well-observed crossings within three meters and 1.5 seconds of entry. It does not invent physical TTC or imminent impact from angular motion alone. |
| 5 | Class jitter / greedy association | Implemented. Same-kind class compatibility, predicted horizontal/vertical position, IoU, scale and depth feed Hungarian assignment with unmatched columns. At most 32 detections enter matching. Added class-jitter, constrained-assignment, crossing and short-occlusion regressions. Device scene validation remains necessary. |
| 6 | Quality conditions overwrite each other | Implemented. Independent thermal, close-camera, image and transient condition state derives one ordered quality. Thermal recovery and transient expiry work without another image-quality update. Pipeline failures take visual/announcement priority in Assist. |
| 7 | State survives restart | Implemented. `resetSessionState()` resets motion, quality, inference timestamps, path state, health, metrics and event selection for live sessions. Old motion callbacks carry session generations. The intentionally shared pending-preview flag remains occupied until its old conversion finishes; its generation prevents stale delivery. |
| 8 | Audio interruption stops vision/haptics | Implemented. Audio/speech availability is independent of session activity. Interruption cancels queued sound; vision/haptics continue. Audio resumes only with the system's `shouldResume` permission or a new session. |
| 9 | Asynchronous stop / cross-session cues | Implemented. Stop invalidates session/feedback generations first. Main-thread speech cancellation, audio-queue shutdown and haptic-player cancellation form a barrier. Delivery locking prevents a late haptic start. Old audio completions and bridge events cannot affect a new session. Stop does not wait for non-cancellable Core ML inference. |
| 10 | Eager activation / retained ducking | Implemented. Engine construction does not activate playback. Actual tone/speech requests activate audio; shutdown calls `setActive(false, .notifyOthersOnDeactivation)`. Haptics use a haptics-only engine. Route behavior still needs device validation. |
| 11 | VoiceOver flooding / competing speech | Implemented. Event/status live regions were removed. A central announcement gate filters hazard churn and allows risk escalation. Native synthesized speech is suppressed while VoiceOver is running. |
| 12 | Uncalibrated depth path | Deferred calibration work. Confirmed fixed central rectangle. README now states this limitation. Changing geometry without lens/mounting measurements or ground-truth scenes would substitute another unvalidated heuristic. Wide-lens default is addressed separately. |
| 13 | Ultra-wide default | Implemented. Automatic camera selection prefers standard wide. Legacy automatic-widest preferences migrate to standard; explicit camera IDs remain selectable. Missing selected devices fall back to standard wide. |
| 14 | Discontinuous depth surfaces merge | Implemented. Neighbor connections require a bounded absolute/relative depth jump. Added discontinuous checkerboard and existing coherent-wall/floor regressions. |
| 15 | Old depth sampled with new detector box | Implemented. Due depth and detector requests share a pixel buffer. New boxes sample depth only from that same frame; intervening detector observations have no new depth measurement. Tracks retain only their timestamped, bounded-age prior measurements. Paired inference latency needs device profiling. |
| 16 | Unknown-distance fallback cues | Reverted at the user's request. Unknown-distance events retain configured audio, speech and haptics. Speech follows category preferences and VoiceOver coordination. No distance or collision timing is fabricated. |
| 17 | Nontransactional model installation | Implemented. Both official archives are staged, checksum-verified, extracted safely and loaded against the app's model schema before atomic installation and publication. Failed preparations preserve the prior pair. |
| 18 | Whole-asset synchronous downloads | Implemented. URLSession downloads stream to temporary files. SHA-256 verification uses bounded reads; no whole model is loaded into a download buffer. Main remains responsive. |
| 19 | Obsolete model requests continue work | Implemented. Superseding selections, stop, background and unmount cancel pending transfers/prompts. Generation checks reject obsolete load results. Already-running Core ML compilation remains non-cancellable. |
| 20 | Unbounded model cache | Implemented for current runtime. Download cache keeps at most one pinned pair per variant and removes obsolete versions after successful replacement. Compiled cache retains active paths plus at most two inactive compilations. Legacy downloaded files remain; no cache-management UI was added. |
| 21 | Path/mtime compiled identity | Implemented. Cache identity streams model-package content and relative file names through SHA-256. Added a content-change regression independent of modification dates. |
| 22 | Catalog is not independently trusted | Implemented. Official URLs are fixed and archive checksums/sizes are pinned in the signed app's manifest. No mutable remote catalog supplies trust. |
| 23 | No model/app contract | Partially addressed. Bundling or pinned archive hashes bind model/app versions, and loading rejects incompatible 640x640 image input or detector/depth output shapes. Numerical correctness remains #24. |
| 24 | No numerical export validation | Deferred validation gap. Export checks still verify source digests and tensor shapes. No trusted golden scene corpus/tolerances was supplied, and Core ML prediction requires macOS. Numerical parity and scene accuracy are not claimed or replaced by shape checks. |
| 25 | No application CI | Implemented configuration. Added root/module typecheck, ESLint, Node tests, Nitro generation drift, app build and XCTest jobs. Podfile includes/shares the native test spec; the runner discovers its actual generated scheme. CI has not run remotely for these unpushed changes. |
| 26 | Missing lifecycle/concurrency coverage | Partially addressed. Added session-controller cancellation/finally/background tests and native health, quality, generation, model-selection and identity regressions. Direct engine/device/NativeEventEmitter integration coverage is still incomplete. |
| 27 | iPhone 12 claim not enforced | Documentation corrected. README distinguishes the iPhone 12 benchmarking target from actual iOS 17/arm64 installation requirements. Older compatible phones remain installable and unvalidated; no unsupported device whitelist was invented. |
| 28 | Models-ready reported as camera-running | Implemented. Models-ready is starting; running requires received frames. Failure/stall status is degraded, and absent rear camera produces an explicit startup error. Camera callbacks preserve pipeline failures. |
| 29 | Unthrottled debug depth PNGs | Implemented. Preview encoding is limited to one request per second and one pending conversion, with generation checks. No claim about measured energy/GC savings is made. |
| 30 | Onboarding swallows feedback errors | Implemented. Failure is rendered and announced; updates after unmount are suppressed. |
| 31 | Onboarding bypasses lifecycle | Removed onboarding feedback playback. Assist uses `SessionController`; cancellation prevents delayed starts after stop, background, or unmount. |
| 32 | Persistent imminent cue only once | Left unchanged: design choice. Existing README/tests require cues on hazard changes or increasing risk. Repeating an unchanged warning needs user testing and a cadence requirement, not a guessed new behavior. |
| 33 | No display disappearance hysteresis | Left unchanged: design choice. Internal tracks preserve identity for 0.8 seconds, but absent observations are not re-emitted. A confidence-decaying retained display needs an explicit stale-observation presentation policy. |
| 34 | Processing metric differs from camera-to-cue target | Left unchanged: accurately labelled metric, separate validation gap. UI says “Processing”; README explicitly excludes playback. Capture-to-cue percentiles and hardware playback timing require additional instrumentation/device measurement. No measured end-to-end result is claimed. |
| 35 | README binary policy contradiction | Corrected. Nano packages are committed distributable resources, and the build-time script reproduces them. Release workflow/docs no longer describe private assets as automatic runtime downloads. |
| 36 | Unvalidated visionOS platform | Corrected. Removed visionOS from the podspec's supported platforms. |
| 37 | Initial Reduce Motion animation | Implemented. Unknown accessibility state defaults to reduced motion. Active entrance/route animations are stopped when reduced motion is enabled. Actual accessibility behavior still needs device testing. |
| 38 | Maximum Dynamic Type layout | Mitigated, not device-verified. Assist content is scrollable and Stop stays outside the scroll view. The alleged clipping was a possibility, not a reproduced device failure; maximum accessibility font sizes still need physical validation. |
| 39 | Synthetic event timestamps | Removed synthetic event playback and its timestamp helpers. All session events now originate from live inference. |

Additional lifecycle issue fixed during review: camera interruption now preserves
the paused state when native shutdown emits idle, keeping the camera active so
its interruption-ended callback can restart the pipeline. Startup text also
waits for native frame confirmation rather than announcing camera activity from
the camera-start callback alone. Physical interruption recovery remains untested.

Additional check failure found: Nitro 0.37 rejected the old iOS-only configuration
because its schema requires an `android` configuration object. Added required
generator names without an Android implementation; code generation now completes
and the existing generated iOS/shared sources have no semantic drift.

## Verification

- Node domain suite: 24 tests passed; existing module-type warning remains.
- Root and native-module TypeScript typechecks: passed.
- ESLint with `--max-warnings=0`: passed.
- Official download links and pinned hashes were checked against Ultralytics release metadata. Temporary non-Nano developer downloads were removed; only Nano binaries remain in the repository.
- Nitro generation: passed; generated-source diff is empty.
- `scripts/check-ios.py` Python syntax: passed.
- Swift/XCTest, iOS build, VoiceOver, maximum Dynamic Type, audio routes, haptics,
  calibrated scene accuracy, thermal performance and camera-to-cue latency:
  not executable/verified on this Windows host. No iOS validation was run, as requested.
- ZIPFoundation 0.9.20 was added to the podspec. CocoaPods installation and native lockfile regeneration remain unrun.
- Locked dependency installation reported four pre-existing dependency advisories
  (one moderate, three high). Dependency versions/lockfiles were not changed.

The test-spec integration follows the [CocoaPods test-spec guide](https://guides.cocoapods.org/using/test-specs.html)
and [Podfile scheme-sharing reference](https://guides.cocoapods.org/syntax/podfile).
