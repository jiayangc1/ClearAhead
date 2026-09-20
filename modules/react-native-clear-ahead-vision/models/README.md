# Core ML models

The application uses two Ultralytics YOLO26 nano models:

- `YOLO26n.mlpackage` for COCO object detection
- `YOLO26nDepth.mlpackage` for dense monocular metric depth

Install the pinned exporter in a Python virtual environment, then build and
verify both packages:

```sh
python3 -m pip install -r scripts/model-requirements.txt
npm run models
```

The installer downloads `yolo26n.pt` and `yolo26n-depth.pt` from the official
Ultralytics `v8.4.0` assets release, verifies GitHub's published SHA-256 digest,
exports fixed 640-pixel INT8 Core ML packages, and rejects unexpected output
shapes. Generated packages and their manifest are committed as CocoaPods
resources so a clean checkout cannot silently build without inference. The
`Package YOLO26 Core ML models` workflow performs the same pinned export on
x86 Linux and records source digests and output shapes in the manifest.

Ultralytics software and model weights are licensed under AGPL-3.0. ClearAhead
is distributed on that basis; deployments that cannot meet AGPL-3.0 must obtain
an Ultralytics Enterprise license before distributing these models.

- https://github.com/ultralytics/ultralytics
- https://www.gnu.org/licenses/agpl-3.0.html
