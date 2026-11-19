# Development and device validation

Detailed implementation notes and physical acceptance checks for Clear Ahead.
For installation and everyday use, see the [project README](../README.md).

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
Start looking along the upright rear camera. Restart Assist after repositioning
the phone or to recenter. Motion denial, unavailable motion, stale updates, and
unsupported headphones disable head tracking. Automatic
[isListenerHeadTrackingEnabled](https://developer.apple.com/documentation/avfaudio/avaudioenvironmentnode/islistenerheadtrackingenabled)
requires Apple's Head Pose entitlement; this app does not enable that entitlement
or automatic API. Personalized spatial-audio profile access is also not configured.
Manual motion tracking does not depend on those capabilities. Reconnecting an
output restarts motion and requires the same forward-facing calibration.

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
