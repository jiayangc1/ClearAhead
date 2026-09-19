#!/usr/bin/env python3
"""Download verified YOLO26 weights and export the app's Core ML packages."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tempfile
import urllib.request
from pathlib import Path

import coremltools as ct
import ultralytics
from ultralytics import YOLO


ASSET_RELEASE = "v8.4.0"
ASSET_API = f"https://api.github.com/repos/ultralytics/assets/releases/tags/{ASSET_RELEASE}"
MODELS = (
    ("yolo26n.pt", "YOLO26n.mlpackage", {"nms": False}),
    ("yolo26n-depth.pt", "YOLO26nDepth.mlpackage", {}),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def release_assets() -> dict[str, dict]:
    request = urllib.request.Request(
        ASSET_API,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "ClearAhead-model-export"},
    )
    with urllib.request.urlopen(request) as response:
        payload = json.load(response)
    return {asset["name"]: asset for asset in payload["assets"]}


def download_verified(asset: dict, destination: Path) -> str:
    urllib.request.urlretrieve(asset["browser_download_url"], destination)
    actual = sha256(destination)
    expected = (asset.get("digest") or "").removeprefix("sha256:")
    if not expected:
        raise RuntimeError(f"GitHub did not publish a SHA-256 digest for {asset['name']}")
    if actual != expected:
        raise RuntimeError(f"Checksum mismatch for {asset['name']}: {actual} != {expected}")
    return actual


def output_shapes(package: Path) -> list[list[int]]:
    specification = ct.utils.load_spec(str(package))
    shapes: list[list[int]] = []
    for output in specification.description.output:
        if output.type.HasField("multiArrayType"):
            shapes.append(list(output.type.multiArrayType.shape))
    return shapes


def validate_export(source_name: str, package: Path) -> list[list[int]]:
    shapes = output_shapes(package)
    if not shapes:
        raise RuntimeError(f"{source_name} did not export a multi-array output")
    if source_name == "yolo26n.pt":
        if not any(len(shape) >= 2 and shape[-1] == 6 for shape in shapes):
            raise RuntimeError(f"Unexpected detector output shapes: {shapes}; expected (..., detections, 6)")
    elif not any(len(shape) >= 2 and shape[-1] > 16 and shape[-2] > 16 for shape in shapes):
        raise RuntimeError(f"Unexpected depth output shapes: {shapes}; expected a dense (..., H, W) map")
    return shapes


def export_models(output: Path) -> None:
    if ultralytics.__version__ != "8.4.155":
        raise RuntimeError(f"Use ultralytics 8.4.155, found {ultralytics.__version__}")
    output.mkdir(parents=True, exist_ok=True)
    assets = release_assets()
    manifest = {"assetRelease": ASSET_RELEASE, "ultralytics": ultralytics.__version__, "models": []}

    with tempfile.TemporaryDirectory(prefix="clear-ahead-yolo26-") as temporary:
        workspace = Path(temporary)
        for source_name, package_name, extra in MODELS:
            if source_name not in assets:
                raise RuntimeError(f"{source_name} is missing from Ultralytics assets {ASSET_RELEASE}")
            source = workspace / source_name
            source_digest = download_verified(assets[source_name], source)
            exported = Path(
                YOLO(str(source)).export(
                    format="coreml",
                    imgsz=640,
                    batch=1,
                    quantize=8,
                    **extra,
                )
            )
            shapes = validate_export(source_name, exported)
            destination = output / package_name
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(exported, destination)
            manifest["models"].append(
                {
                    "source": source_name,
                    "sourceSha256": source_digest,
                    "package": package_name,
                    "packageOutputShapes": shapes,
                    "inputSize": 640,
                    "quantization": "int8",
                }
            )

    (output / "model-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"YOLO26 Core ML models installed in {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    export_models(parser.parse_args().output.resolve())
