"""Build the app and run the CocoaPods native test scheme on macOS."""

import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET


def main():
    payload = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True
    ))
    devices = [device for runtime, group in payload["devices"].items()
               if "iOS" in runtime for device in group
               if device.get("isAvailable") and "iPhone" in device["name"]]
    if not devices:
        raise RuntimeError("No available iPhone simulator; install an iOS simulator runtime.")
    destination = f"platform=iOS Simulator,id={devices[0]['udid']}"
    common = ["-workspace", "ios/ClearAhead.xcworkspace", "-destination", destination,
              "-derivedDataPath", "build/ios-checks", "CODE_SIGNING_ALLOWED=NO"]
    subprocess.run(["xcodebuild", "build", "-scheme", "ClearAhead", *common], check=True)

    # Scheme names differ between CocoaPods versions; select by its test bundle.
    schemes = []
    for path in Path("ios/Pods").rglob("*.xcscheme"):
        root = ET.parse(path).getroot()
        bundles = root.findall("./TestAction/Testables/TestableReference/BuildableReference")
        if any("ClearAheadVision" in item.get("BuildableName", "")
               and item.get("BuildableName", "").endswith(".xctest") for item in bundles):
            schemes.append(path.stem)
    if not schemes:
        raise RuntimeError("ClearAheadVision test scheme missing; install the Tests pod test spec.")
    subprocess.run(["xcodebuild", "test", "-scheme", sorted(schemes)[0], *common], check=True)


if __name__ == "__main__":
    main()
