# Clear Ahead

Clear Ahead is an iPhone-only assistive vision prototype. It continuously
represents visible nearby objects and unnamed surfaces with continuous spatial
tones, visible depth contours, urgency vibrations, and short speech.

> Clear Ahead is experimental awareness support. It can miss or misjudge
> hazards and does not replace a cane, guide dog, mobility training, or personal
> judgment.

## What is implemented

- Bare React Native 0.87 and TypeScript interface with Hermes/New Architecture
- VoiceOver-labelled onboarding, assist mode, and settings
- Depth contours across the visible frame, with approximate distance labels
- Persistent, independent haptic, directional-audio, and speech preferences
- VisionCamera 5 frame output connected to a typed Nitro Swift module
- On-device Core ML object detection and metric-depth estimates
- Stable tracking for named people, vehicles, and furniture
- Depth-connected surfaces throughout the frame, including walls and unnamed geometry
- Up to six simultaneous sources, with stable selection based on visibility, distance, and collision risk
- Urgency-only Core Haptics, continuous AVAudioEnvironmentNode sources, and speech ducking
- Ground fitting with camera intrinsics, gravity, and optional measured camera-height calibration
- Upright or sideways (horizontal) phone mounts, detected from gravity
- Speech enabled by default; saved speech opt-outs remain respected
- Startup progress from loaded model sizes and size-weighted download bytes
- Low-light, covered-camera, and thermal-pressure reporting
- Responsive and detailed processing modes, with an optional processed-frame-rate display
- No account, backend, analytics, frame storage, or camera upload

## Requirements

- iPhone 12 or newer is the physical-device benchmarking target. Installation
  requires iOS 17 on an arm64 iPhone; older compatible iPhones are not hardware-gated
  and their performance has not been validated.
- iOS 17 or newer
- Full Xcode installation with iOS 17 SDK
- Node.js 22.11 or newer
- Ruby and Bundler for CocoaPods

TypeScript, Node tests, and Nitro code generation can run without Xcode.
An iOS build and XCTest require macOS with full Xcode. Instruments profiling,
camera, haptic, audio interruption, and Bluetooth verification require a physical iPhone.

## Setup

```sh
npm install
python3 -m pip install -r scripts/model-requirements.txt
npm run models
bundle install
cd ios && bundle exec pod install && cd ..
npm start
```

Open `ios/ClearAhead.xcworkspace` in Xcode and run on a physical iPhone.

Install the pinned Python exporter first. `npm run models` then downloads the
official weights, verifies GitHub's published SHA-256 digests, and installs:

- YOLO26 nano INT8 Core ML for selected COCO object classes
- YOLO26 nano depth INT8 Core ML for dense metric depth

The Nano model packages are committed distributable app resources and bundled
with the app. `scripts/download-models.sh` reproduces them. Settings lets users
download Small, Medium, Large and Extra Large detector/depth pairs from the
official [Ultralytics Core ML release](https://github.com/ultralytics/yolo-ios-app/releases/tag/v8.3.0).
Cellular or metered downloads require approval. Downloads use checksums pinned
in the app and install only after both models load successfully. Other variants
are stored on the user's device; only Nano binaries belong in this repository.
Source and license details are documented in
`modules/react-native-clear-ahead-vision/models/README.md`.

## Checks

```sh
npm run typecheck
npm run lint
npm test
npm --prefix modules/react-native-clear-ahead-vision run typecheck
```

The JavaScript/domain suite uses the native Node test runner, not Jest. Native
XCTest coverage lives in the ClearAheadVision pod test spec and runs with the
full iOS toolchain.

Application checks run on pull requests and main pushes. The iOS job installs
the pod's `Tests` test spec, builds the app, and selects the generated native
test scheme with `python3 scripts/check-ios.py`. Re-run `bundle exec pod install`
after changing native sources or test specs. See [audit dispositions](docs/bug-audit.md)
for verification limits and remaining physical-device validation.

## Architecture

```text
VisionCamera preview + bounded frame output
                   |
            Nitro JSI boundary
                   |
    Swift bounded scheduler (frames never enter React state)
        |               |                     |
  object detector    metric depth        quality checks
        \               |                    /
       named tracks + visible depth surfaces + ground fit
                          |
             six-source selector + risk/speech priority
                       |
              native feedback engine
              /         |          \
         Core Haptics  spatial tones  speech
                       |
          throttled status/overlay events
                       |
              React Native interface
```

The detector and depth estimator share a bounded frame schedule. New
frames are dropped while the native processor is busy, preventing an unbounded
camera queue. Serious thermal pressure reduces model frequency while retaining
the light quality checks and existing feedback path.

Responsive mode requests smaller frame buffers and checks depth less often to
favor object updates. Detailed mode requests larger buffers and checks depth
more often. The on-screen FPS value counts frames accepted for processing, not
the camera capture rate; object and depth rates are shown separately. The home
screen displays the last live assist-session reading. Device profiling is still
needed to establish the actual rate and detection tradeoffs on an iPhone 12.

## Live scene and audio

The matched detector/depth frame supplies visible geometry. A coarse 32 × 48
connected depth grid makes continuous surfaces, rather than a collection of
warning boxes. Semantic detections annotate depth-supported regions; they never
create hidden geometry. Foreground overlap and insufficient depth support suppress
occluded labels. Contours retain holes and match the camera's aspect-fill crop.
They are depth estimates, not instance segmentation masks. Thin or small objects
can be missed; ambiguous touching surfaces can merge. An extended connected wall
uses one source. The camera covers only its current rear-camera field of view.
There is no persistent map or remembered geometry behind the user.

Up to six sources are selected by distance, visibility, confidence, and collision
risk. Existing visible identities receive selection hysteresis. Missing candidates
leave selection immediately and their tones fade. New urgent sources can displace
ordinary scenery. Depth failures, stale frames, covered cameras, and incoherent
near geometry report **scene unavailable**, separately from **scene clear**. Clear
means no selected nearby geometry in this camera view, not proof that walking is safe.

Six mono AVAudioPlayerNode loops feed AVAudioEnvironmentNode with automatic route
rendering. Most surfaces share a soft harmonic tone; people and vehicles use
distinct registers. Source slots have slightly different pitches to separate
simultaneous tones. Distance changes loudness, not repetition rate or urgency
rhythm. Slow modulation softens sustained tones. Gain and positions interpolate
at 50 Hz; appearance/disappearance fade. The sum of source gains is at most 0.21
before the 0.8 mixer volume. This bounds source levels, not physical
headphone SPL. Speech volume is 0.75 and ducks tones to 20%; VoiceOver also receives quieter tones.
The existing continuous-audio opt-out now disables scene tones. Speech and
urgency haptics remain independently selectable.

Apple's [AVAudioEnvironmentNode documentation](https://developer.apple.com/documentation/avfaudio/avaudioenvironmentnode)
specifies mono inputs for 3D spatialization. This uses Apple's binaural rendering,
not ordinary stereo panning presented as full 3D. Compatible headphones can carry
direction, elevation, and front/back of **currently observed** geometry relative
to a turning head. Generic HRTFs can still cause perceptual front/back ambiguity.
Speaker/receiver output cannot reliably convey height or front/back; use speech
for identification/direction. Geometry/motion missing means a camera-relative
horizontal fallback, explicitly shown as limited in the interface.

[CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager)
is available from iOS 14, requires NSMotionUsageDescription, and must be checked
for availability. The app manually combines phone and headphone attitudes, converts
headphone axes to the audio coordinate system, and aligns arbitrary yaw origins.
Start looking along the rear camera, upright or on its side. Restart Assist after
repositioning the phone or to recenter. Motion denial, unavailable motion, stale updates, and
unsupported headphones disable head tracking. Automatic
[isListenerHeadTrackingEnabled](https://developer.apple.com/documentation/avfaudio/avaudioenvironmentnode/islistenerheadtrackingenabled)
requires Apple's Head Pose entitlement; this app does not enable that entitlement
or automatic API. Personalized spatial-audio profile access is also not configured.
Manual motion tracking does not depend on those capabilities. Reconnecting an
output restarts motion and requires the same forward-facing calibration.

## Phone mounting

The phone can be mounted upright or sideways (horizontally), with its top edge to
either side. Gravity decides which: the first reading of a session is taken at
once, and a later change must hold past 60 degrees of roll for 0.6 seconds, so
arm swing does not flip it. Camera frames, LiDAR depth, intrinsics, gravity, and
attitude are turned into the upright picture before any reading, so obstacles,
ground fitting, path cues, and spatial audio behave the same either way. When the
mount changes mid-session, tracked hazards and ground calibration start over and
spatial audio realigns to the camera. The interface stays upright on the phone;
the depth preview and outlines are turned to match the camera preview.

## Distance normalization and urgency

The existing YOLO26 monocular model produces metric-trained depth **estimates**.
Its metric training is a prior, not an independent measurement of absolute scale.
[CaneEye's Devpost](https://devpost.com/software/cane-t7v4oi) describes ground fitting
to address frame rescaling, but does not supply a calibrated algorithm. This app
uses robust lower-frame plane fitting with delivered camera intrinsics and fresh
gravity. A plane alone never establishes meters. With no measured camera height,
plane fitting only checks geometric consistency and excludes supported ground;
model distance remains explicitly approximate.

In Settings / Phone position, measure camera height and the midpoint-of-ears
height above level ground. Measure camera forward/right offsets from that midpoint.
Zero heights mean uncalibrated; zero offsets mean vertically aligned camera/ears.
Keep the phone position steady, especially in handheld mode. Camera height is the
independent metric reference: its ratio to fitted plane height corrects depth scale.
Ear height and horizontal offsets shift source positions to the center of hearing.
Absolute camera-to-ear pose cannot be inferred from IMU data alone. Incorrect
measurements, repositioning, model depth error, or camera calibration error affect
both distance and height. Camera intrinsics delivery is enabled and video
stabilization disabled; if intrinsics are unavailable, no ground normalization or
confident 3D geometry is substituted from a guessed field of view.

Fits need broad lower-frame support, at least 65% inliers, plausible camera height,
three consistent observations, and a normal within 12 degrees of gravity-up.
Only near-level fits within 5 degrees may adjust scale; corrections are limited
to 0.01 per depth frame and a 0.65–1.5 calibration ratio. Slopes do not rescale the
scene. Missing ground, stairs, poor support, rapid phone movement, or mismatch
invalidate the current plane. The last scale is held and labeled as such rather
than abruptly rescaling. Never replace a failed fit with confident ground distances.
Stair and drop-off recognition are not guaranteed by this normalization.

CollisionTracker and the existing path/ground hazard checks still determine risk.
Scene presence alone does not vibrate. Caution uses a spaced triple vibration at
most once per 1.5 seconds; imminent risk uses four sharper vibrations at most once
per 0.45 seconds. Escalation preempts the cooldown. Camera rotation still suppresses
motion-derived collision predictions. Collision corridor checks remain an image
corridor, not a calibrated physical walking trajectory.

## Focused verification and physical acceptance

JS tests cover preference migration, calibration bounds/native forwarding, and
aspect-fill projection. TypeScript and ESLint cover the bridge and UI integration.
Native XCTest fixtures in SpatialSceneTests and AudioCueTests cover simultaneous
wall/person/low-chair sources, hidden-chair suppression, occlusion holes, wall
consolidation, stable selection, urgent displacement, camera/head/ear transforms,
plane versus metric calibration, missing ground/slopes/stairs/tilt, waveform/gain
bounds, and urgency-only haptics. Existing risk/session/model tests remain included.
Run the native suite on macOS after regenerating Pods for the new source files:

```sh
cd ios && bundle exec pod install && cd ..
python3 scripts/check-ios.py
```

Windows cannot build AVFoundation/CoreMotion or run these XCTest checks. Native
compilation and tests remain required before physical trials. Simulator checks
cannot validate camera depth accuracy, headphone motion, route rendering, or haptics.

Physical iPhone/AirPods acceptance:

1. Place a right wall, ahead-left person, and low chair in view. Confirm three
   sustained, distinguishable sources; chair lower than person. Walk closer and
   confirm loudness rises without faster repetition or scenery vibrations.
2. Put the chair behind a table. Confirm only the visible table remains represented;
   move to reveal the chair and confirm smooth appearance. Check extended walls,
   partially occluded objects, crowds over six sources, and small/thin obstacles.
3. Calibrate camera/ear pose. Turn head left/right, pitch and roll while the phone
   stays fixed, then turn both together. Check axes and front/back against actual
   object locations. Test reconnects, unavailable/denied motion, wired headphones,
   speaker output, VoiceOver, and speech intelligibility. Generic HRTF localization
   and manual attitude drift need listener testing; do not claim this passed from
   mathematical transform tests.
4. Compare distance to tape measurements on level ground, slopes, stairs, floor
   absence, camera tilt, lens changes, and deliberate bad calibration. Check slow
   bounded correction and explicit degraded states without fictitious meters.
5. Approach an obstacle under controlled supervision. Verify caution/imminent
   haptic escalation and immediate stop/background/interruption silence. Measure
   camera-to-audio latency and thermal/FPS performance on the oldest target iPhone.
6. Test cold/warm startup, cached models, download progress, cancellation, offline
   failure and recovery. Bar advancement must follow actual loads/received bytes;
   100% appears only after validation. No model download is needed to use bundled Nano.

Ultralytics software and YOLO26 weights are AGPL-3.0. This repository and any
distributed app containing those models must satisfy the corresponding-source
requirements; use an Ultralytics Enterprise license for incompatible
distribution terms.

The initial physical-device performance target is median urgent-event
camera-to-cue latency below 150 ms with no growing frame backlog. The in-app
processing metric starts when native frame processing begins and stops before
feedback playback. Measure camera-to-cue latency separately on the oldest
supported iPhone before any field trial.
