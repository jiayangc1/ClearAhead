<p align="center">
  <img src="assets/clear-ahead-logo.png" alt="Clear Ahead logo" width="128" />
</p>

<h1 align="center">ClearAhead</h1>
<p align="center"><i>because awareness shouldn't depend on sight alone.</i></p>
<p align="center"><a href="https://clearahead.lekangji.cc"><strong>Explore the website</strong></a> · <a href="https://github.com/lekangji/Clear-Ahead-Website">View the website source</a> · <a href="https://youtu.be/DHR70mPy4-0">Watch the demo</a></p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-17%2B-black" alt="iOS 17 or newer" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License: AGPL-3.0" /></a>
</p>

Clear Ahead is a beta iPhone app that turns the scene in front of you
into spatial sound, short spoken cues, and vibrations. It recognizes nearby
objects and surfaces on the phone completely on-device.

> **Experimental awareness support.** Clear Ahead can miss or misjudge hazards.
> It does not replace a cane, guide dog, mobility training, or personal judgment.

## A scene you can hear

- **Continuous spatial sound.** Up to six nearby objects and surfaces have their
  own tones. Tones get louder as you move closer; people and vehicles use
  distinct registers. Compatible headphones support head tracking.
- **Warnings you can feel.** Vibrations signal caution or imminent collision
  risk. Ordinary scenery does not trigger vibration.
- **Short spoken cues.** Hear warnings and choose whether voice also names
  everything nearby. Voice, sound, and vibration have separate controls.
- **More than object boxes.** Depth contours represent walls and unnamed
  surfaces as well as recognized objects. Optional outlines and a color depth
  view show what the app is seeing.
- **Depth with or without LiDAR.** On-device YOLO26 models estimate depth;
  supported iPhones can also use rear LiDAR for close-range measurements.
- **Made for the phone.** VoiceOver labels, saved preferences, faster or more
  detailed processing, and bundled Nano models. Larger models are optional
  downloads in Settings.

Camera frames are processed on-device and are not saved or uploaded. There is
no analytics service. The bundled models let you start without a model download;
optional larger models require internet access and approval on metered connections.

## Build and run

You'll need **macOS with full Xcode and the iOS 17 SDK**, **Node.js 22.11+**,
and **Ruby with Bundler**. Run the app on a physical arm64 iPhone with iOS 17+.
iPhone 12 or newer is the benchmarking target; older compatible devices are not
blocked, but their performance has not been validated. LiDAR is optional.

```sh
git clone https://github.com/jiayangc1/ClearAhead.git cac
cd cac
npm ci
bundle install
cd ios && bundle exec pod install && cd ..
npm start
```

Open `ios/ClearAhead.xcworkspace` in Xcode, select your signing team and connected
iPhone, then build and run. Keep Metro running in the terminal.

The Nano detector and depth packages are already bundled in the repository.
To reproduce them, install the pinned Python exporter and run:

```sh
python3 -m pip install -r scripts/model-requirements.txt
npm run models
```

See [model setup and provenance](modules/react-native-clear-ahead-vision/models/README.md)
for export details, checksums, optional model downloads, and licensing.

## First run

1. Complete onboarding, choose whether the phone is in your hand or on your
   chest, and allow camera access.
2. In **Settings**, choose Voice, Sounds, and Vibration. Set your warning range
   and sensitivity, and use headphones for directional listening.
3. For calibrated model depth and audio placement, open **Calibration** in
   Settings. Enter measured camera and ear heights above level ground, plus
   the camera's forward and right offsets from the midpoint between your ears.
   Keep the phone in that position during use.
4. Tap **Start** with the rear camera facing ahead. For head tracking, begin
   looking along the upright rear camera. Restart Assist to recenter after
   repositioning the phone or reconnecting headphones.
5. Tap **Stop** to end the session. Assist pauses when the app leaves the
   foreground.

Without measured calibration, model distances remain approximate. Speaker
output cannot reliably convey elevation or front/back direction; speech helps
identify what is nearby.

## Why we made it
Every day, 295 million people worldwide struggle with moderate and severe vision impairment, with 2.2 billion suffering from some sort of vision impairment. In their daily lives, they have trouble navigating spaces: they miss obstacles and hit moving objects, making travelling less independent. Current mobility aids are important, but they are expensive or lack the ability to warn about more complex information, like distant or moving objects. This is why we created ClearAhead: to turn an ordinary smartphone into an accessible device that produces auditory cues without any other hardware.

## Know the limits

Clear Ahead only represents the rear camera's current view. It has no persistent
map of what's behind you. Small or thin obstacles can be missed, touching surfaces
can merge, and model depth can be wrong. Stair and drop-off recognition is not
guaranteed. A clear scene is not proof that walking is safe.

Poor light, a covered camera, stale frames, or unavailable depth can interrupt
scene feedback. Head tracking depends on compatible hardware and motion access;
otherwise audio falls back to camera-relative direction. Thermal pressure can
reduce processing frequency.

Camera accuracy, headphone localization, haptics, and camera-to-cue latency still
need physical-device validation. The 150 ms median urgent-event latency target is
a goal, not a measured result. See the [device acceptance checks](docs/development.md#focused-verification-and-physical-acceptance)
before physical trials.

## Development

The app uses React Native and TypeScript, with VisionCamera feeding a Swift
module through Nitro. Core ML inference, tracking, spatial audio, speech, and
haptics run natively; camera frames never enter React state.

```sh
npm run typecheck
npm run lint
npm test
npm --prefix modules/react-native-clear-ahead-vision run typecheck
```

The JavaScript tests use Node's native test runner. These checks can run without
Xcode. To build iOS and run native XCTest coverage on macOS:

```sh
cd ios && bundle exec pod install && cd ..
python3 scripts/check-ios.py
```

Application checks run on pull requests and pushes to main. For more detail:

- [Architecture, spatial audio, calibration, and device validation](docs/development.md)
- [Native module and interface generation](modules/react-native-clear-ahead-vision/README.md)
- [Audit findings and verification limits](docs/bug-audit.md)

## License

[AGPL-3.0-only](LICENSE). YOLO26 models also use AGPL-3.0; see the
[model licensing notes](modules/react-native-clear-ahead-vision/models/README.md)
for source and distribution requirements.
