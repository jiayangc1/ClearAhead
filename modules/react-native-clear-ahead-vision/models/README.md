# Core ML models

Run `npm run models` from the repository root to download and verify:

- Apple YOLOv3 Tiny Int8 LUT for COCO object localization (MIT model card)
- Apple Depth Anything V2 Small F16 P6 for relative depth (Apache-2.0)

The binary model assets are intentionally ignored by Git. The download script
uses fixed Apple URLs and SHA-256 checksums, and CocoaPods packages the resulting
`.mlmodel` and `.mlpackage` resources into the iOS app.

Source and license information:

- https://huggingface.co/apple/coreml-YOLOv3
- https://huggingface.co/apple/coreml-depth-anything-v2-small
