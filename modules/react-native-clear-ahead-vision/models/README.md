# Core ML models

The application supports matched detector and depth pairs for every Ultralytics
YOLO26 size (`n`, `s`, `m`, `l`, and `x`). All packages are INT8 quantized.

- `YOLO26n.mlpackage` for COCO object detection
- `YOLO26nDepth.mlpackage` for dense monocular metric depth

Install the pinned exporter in a Python virtual environment, then build and
verify both packages:

```sh
python3 -m pip install -r scripts/model-requirements.txt
npm run models
```

The installer downloads YOLO26 detector and depth weights from the official
Ultralytics `v8.4.0` assets release, verifies GitHub's published SHA-256 digest,
exports fixed 640-pixel INT8 Core ML packages, and rejects unexpected output
shapes. The `Package YOLO26 Core ML models` workflow publishes each verified
package file and a checksum catalog to the `yolo26-coreml-v1` GitHub release.
The app downloads the selected detector/depth pair automatically and keeps it
in Application Support for later launches. A locally generated nano pair can
still be bundled as CocoaPods resources for offline development.

Ultralytics software and model weights are licensed under AGPL-3.0. ClearAhead
is distributed on that basis; deployments that cannot meet AGPL-3.0 must obtain
an Ultralytics Enterprise license before distributing these models.

- https://github.com/ultralytics/ultralytics
- https://www.gnu.org/licenses/agpl-3.0.html
