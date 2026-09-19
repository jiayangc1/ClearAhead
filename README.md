# Clear Ahead

Clear Ahead is an iPhone-first assistive vision prototype. It continuously
turns a small set of nearby, high-priority camera events into directional
haptics, stereo audio cues, and optional short speech.

> Clear Ahead is experimental awareness support. It can miss or misjudge
> hazards and does not replace a cane, guide dog, mobility training, or personal
> judgment.

## What is implemented

- Bare React Native 0.87 and TypeScript interface with Hermes/New Architecture
- VoiceOver-labelled onboarding, assist mode, safe demo, and settings
- Annotated three-sector camera view for left, center, and right events
- Persistent, independent haptic, directional-audio, and speech preferences
- VisionCamera 5 frame output connected to a typed Nitro Swift module
- On-device Core ML object detection and relative-depth integration
- Stable multi-object tracking with smoothed relative motion and projected collision paths
- Time-to-collision warnings for tracked objects plus depth-supported optical looming for walls and unlabeled obstacles
- Collision-aware urgency ranking, hysteresis, and cue cooldowns
- Core Haptics direction patterns, spatially panned AVAudioEngine cues whose
  pitch and pulse rhythm encode distance and urgency, and interruptible
  AVSpeechSynthesizer output
- Low-light, covered-camera, thermal-pressure, and frame-overload reporting
- Responsive and detailed processing modes, with an optional processed-frame-rate display
- No account, backend, analytics, frame storage, or camera upload

## Requirements

- iPhone 12 or newer
- iOS 17 or newer
- Full Xcode installation with iOS 17 SDK
- Node.js 22.11 or newer
- Ruby and Bundler for CocoaPods

This checkout currently has Xcode Command Line Tools only. TypeScript, Node,
Nitro code generation, and Swift syntax checks work, but an iOS build, XCTest,
Instruments profile, camera, haptic, and Bluetooth verification require full
Xcode and a physical iPhone.

## Setup

```sh
npm install
python3 -m pip install -r scripts/model-requirements.txt
npm run models
bundle install
cd ios && bundle exec pod install && cd ..
npm start
```

Open `ios/ClearAhead.xcworkspace` in Xcode and run on a physical iPhone. The
safe demo works without camera input, but native audio and haptics still require
an iOS build.

Install the pinned Python exporter first. `npm run models` then downloads the
official weights, verifies GitHub's published SHA-256 digests, and installs:

- YOLO26 nano INT8 Core ML for selected COCO object classes
- YOLO26 nano depth INT8 Core ML for dense metric depth

Model binaries are ignored by Git and reproduced by
`scripts/download-models.sh`. Their source and license details are documented in
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

## Architecture

```text
VisionCamera preview + 30 FPS frame output
                   |
            Nitro JSI boundary
                   |
    Swift bounded scheduler (frames never enter React state)
        |               |              |               |
  object detector    metric depth  optical flow   quality checks
        \               |              /               /
         stable tracks + relative trajectory prediction
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

YOLO26 depth produces a dense metric estimate. Clear Ahead uses robust regional
samples for generic walls and obstacles and samples inside detected boxes before
falling back to physical-size priors. Distances are still spoken as “about”
values because monocular estimates depend on scene and camera calibration.
Collision timing combines depth change, box expansion, and low-resolution
optical looming. Camera rotation suppresses motion-derived warnings until the
view stabilizes. This is a baseline for calibration and real-world testing, not
validated collision-avoidance accuracy.

Ultralytics software and YOLO26 weights are AGPL-3.0. This repository and any
distributed app containing those models must satisfy the corresponding-source
requirements; use an Ultralytics Enterprise license for incompatible
distribution terms.

The initial physical-device performance target is median urgent-event
camera-to-cue latency below 150 ms with no growing frame backlog. Validate it
with the in-app metrics plus Instruments on the oldest supported device before
any field trial.
