# Core ML models

The application bundles the Nano matched detector and depth pair. The exporter
can produce every YOLO26 size (`n`, `s`, `m`, `l`, and `x`). Settings downloads
other sizes on demand from the official Ultralytics Core ML release. Only Nano
binaries are committed and bundled. All packages are INT8 quantized.

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
Those private release assets are development artifacts; the app does not download
them. Runtime downloads use
[`ultralytics/yolo-ios-app` release `v8.3.0`](https://github.com/ultralytics/yolo-ios-app/releases/tag/v8.3.0),
with SHA-256 hashes and archive sizes pinned in `official-models.json` inside the
signed app. Users must approve cellular or metered downloads. Transfers stream
to disk, verify checksums, reject unsafe archive paths, and stage complete pairs
before installation. Cancellation stops downloads when superseded or backgrounded.
The device cache stores at most one pinned pair per variant. No other model
binaries or archives belong in this repository.
Compiled caches use streamed content hashes and retain the active pair plus up
to two inactive models. Runtime loading checks 640x640 image inputs and the expected
detector/depth output shapes. These schema checks do not prove numerical accuracy.

Ultralytics software and model weights are licensed under AGPL-3.0. ClearAhead
is distributed on that basis; deployments that cannot meet AGPL-3.0 must obtain
an Ultralytics Enterprise license before distributing these models.

- https://github.com/ultralytics/ultralytics
- https://www.gnu.org/licenses/agpl-3.0.html
