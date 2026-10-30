#!/bin/bash
#
# Copyright (C) 2019-2022 crDroid Android Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# $1=TARGET_DEVICE, $2=PRODUCT_OUT, $3=FILE_NAME
python3 - "$@" <<'PYTHON'
import hashlib
import json
import sys
from pathlib import Path

if len(sys.argv) != 4:
    sys.exit("Expected device, output directory and OTA ZIP filename")
device, output_dir, filename = sys.argv[1:]
product = Path(output_dir)
ota = product / filename
if not ota.is_file() or not filename.startswith("lineage-"):
    sys.exit("Expected an existing Lineage OTA ZIP")

# Keep unsupported devices from advertising a fabricated build.
if not (Path("vendor/LineageOTA") / (device + ".json")).is_file():
    (product / (device + ".json")).write_text("[]\n")
    print("No OTA configuration for " + device)
    sys.exit(0)

props = {}
for name in ["system/build.prop", "system/product/etc/build.prop"]:
    for line in (product / name).read_text().splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            props[key] = value

checksum = hashlib.sha256()
with ota.open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        checksum.update(chunk)
file = {
    "filename": filename,
    "sha256": checksum.hexdigest(),
    "size": ota.stat().st_size,
    "url": f"https://ota.html6405.com/{device}/LOS23/{filename}",
    "os_sdk_level": int(props["ro.system.build.version.sdk"]),
}
patch = props.get("ro.system.build.version.security_patch")
if patch:
    file["os_patch_level"] = patch
updates = [{
    "datetime": int(props["ro.system.build.date.utc"]),
    "type": props.get("ro.lineage.releasetype", "HTML6405"),
    "version": filename.split("-", 2)[1],
    "files": [file],
}]
output = product / (device + ".json")
output.write_text(json.dumps(updates, indent=2) + "\n")
print("JSON file data for OTA support:")
print(output.read_text())
PYTHON
