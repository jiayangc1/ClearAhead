# ClearAheadVision

Private iOS native package for the Clear Ahead app. It connects VisionCamera 5
frames to Swift through a generated Nitro JSI interface; image buffers never
enter React state or serialize across the bridge.

The Swift implementation owns Core ML inference, image-quality checks, motion
monitoring, event prioritization, haptics, directional audio, speech, and
low-frequency status events.

## Regenerate the interface

After changing `src/specs/clear-ahead-vision.nitro.ts`:

```sh
npm install
npm run codegen
```

The generated `nitrogen/` sources are committed so CocoaPods can build the
local package deterministically.

## Models

Model binaries are installed from the repository root with `npm run models`.
See `models/README.md` for provenance and licenses.
