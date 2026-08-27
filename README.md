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
- Temporal tracking, urgency ranking, hysteresis, and cue cooldowns
- Core Haptics direction patterns, spatially panned AVAudioEngine tones, and
  interruptible AVSpeechSynthesizer output
- Low-light, covered-camera, thermal-pressure, and frame-overload reporting
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
npm run models
bundle install
cd ios && bundle exec pod install && cd ..
npm start
```

Open `ios/ClearAhead.xcworkspace` in Xcode and run on a physical iPhone. The
safe demo works without camera input, but native audio and haptics still require
an iOS build.

`npm run models` downloads Apple-hosted model assets and verifies fixed SHA-256
checksums before installing them into the local native package:

- YOLOv3 Tiny Int8 LUT for selected COCO object classes
- Depth Anything V2 Small F16 P6 for relative depth

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
    Swift Core ML scheduler (frames never enter React state)
        |               |               |
  object detector   relative depth   quality checks
        \               |               /
          tracking + event prioritizer
                       |
              native feedback engine
              /         |          \
         Core Haptics  stereo tone  speech
                       |
          throttled status/overlay events
                       |
              React Native interface
```

The detector and depth estimator alternate on a bounded frame schedule. New
frames are dropped while the native processor is busy, preventing an unbounded
camera queue. Serious thermal pressure reduces model frequency while retaining
the light quality checks and existing feedback path.

## Distance and safety behavior

Depth Anything produces relative depth. Clear Ahead therefore reports
near/medium/far for generic depth regions. Approximate meters are emitted only
for object classes with simple physical-size priors and are explicitly spoken
as “about” values. This is a baseline for calibration and real-world testing,
not validated collision-avoidance accuracy.

The initial physical-device performance target is median urgent-event
camera-to-cue latency below 150 ms with no growing frame backlog. Validate it
with the in-app metrics plus Instruments on the oldest supported device before
any field trial.
