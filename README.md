# Clear Ahead

Clear Ahead is an iPhone-only assistive vision prototype. It continuously
turns a small set of nearby, high-priority camera events into directional
haptics, stereo audio cues, and optional short speech.

> Clear Ahead is experimental awareness support. It can miss or misjudge
> hazards and does not replace a cane, guide dog, mobility training, or personal
> judgment.

## What is implemented

- Bare React Native 0.87 and TypeScript interface with Hermes/New Architecture
- VoiceOver-labelled onboarding, assist mode, and settings
- Annotated three-sector camera view for left, center, and right events
- Persistent, independent haptic, directional-audio, and speech preferences
- VisionCamera 5 frame output connected to a typed Nitro Swift module
- On-device Core ML object detection and metric-depth estimates
- Stable tracking for named people, vehicles, and furniture
- Depth-based path obstacle cues for walls and unlabeled hazards
- Collision timing from successive timestamped depth readings; cues repeat when risk increases
- Core Haptics direction patterns, spatially panned AVAudioEngine cues whose
  pitch and pulse rhythm encode distance and urgency, and interruptible
  AVSpeechSynthesizer output
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
         named tracks + coherent path obstacles
                          |
                  event prioritizer
                       |
              native feedback engine
              /         |          \
         Core Haptics  spatial cue  speech
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

## Distance and safety behavior

YOLO26 depth produces a dense metric estimate. Clear Ahead checks for coherent
near surfaces in the walking path and samples depth inside named detection
boxes only when detector and depth observations share a frame. If depth fails,
named objects retain configured audio, speech and haptic cues with unknown
distance. Speech respects category preferences and VoiceOver coordination.
Collision timing stays off until valid depth measurements return.
Distances are spoken as “about” values because monocular estimates depend on
scene and camera calibration. Closing speed uses new depth timestamps; camera
rotation suppresses motion-derived warnings until the view stabilizes. Physical
device calibration is still required before treating collision timing as reliable.
The depth region is a fixed central image region, not a calibrated ground-plane
walking corridor. The standard wide rear camera is the default. Other lens,
device, and mounting profiles require physical validation.

Ultralytics software and YOLO26 weights are AGPL-3.0. This repository and any
distributed app containing those models must satisfy the corresponding-source
requirements; use an Ultralytics Enterprise license for incompatible
distribution terms.

The initial physical-device performance target is median urgent-event
camera-to-cue latency below 150 ms with no growing frame backlog. The in-app
processing metric starts when native frame processing begins and stops before
feedback playback. Measure camera-to-cue latency separately on the oldest
supported iPhone before any field trial.
