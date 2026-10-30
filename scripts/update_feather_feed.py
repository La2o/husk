#!/usr/bin/env python3
"""Generate an AltStore/Feather source from published Husk ITRTG GitHub releases.

The input comes from the authenticated GitHub Releases API after IPA upload,
not from an Actions artifact URL (which expires). This keeps a single stable
Feather source usable across every experimental development branch.

Usage:
  python3 scripts/update_feather_feed.py releases.json output.json SOURCE_URL
"""
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

SOURCE_ID = "com.la2o.husk.itrtg.test"
ICON = ("https://raw.githubusercontent.com/La2o/husk/refs/heads/main/"
        "src/app/Husk/Assets.xcassets/AppIcon.appiconset/Icon-Default.png")
IPA_NAME = "Husk-Unity6-test.ipa"


def generate(releases: list, source_url: str) -> dict:
    versions = []
    seen = set()
    for release in releases:
        match = re.fullmatch(r"itrtg-test-(\d+)", release.get("tag_name", ""))
        if not match or release.get("draft"):
            continue
        number = int(match.group(1))
        if number in seen:
            continue
        assets = [a for a in release.get("assets", [])
                  if a.get("name") == IPA_NAME and a.get("size", 0) > 0
                  and a.get("state", "uploaded") == "uploaded"
                  and a.get("browser_download_url", "").startswith(
                      "https://github.com/La2o/husk/releases/download/")]
        if len(assets) != 1:
            continue
        seen.add(number)
        asset = assets[0]
        date = (release.get("published_at") or release.get("created_at")
                or datetime.now(timezone.utc).isoformat())[:10]
        note = (release.get("body") or "Husk ITRTG experimental test build").strip()
        versions.append({
            "version": f"3.1.{number}",
            "buildVersion": f"130.{number}",
            "date": date,
            "localizedDescription": note[:600],
            "downloadURL": asset["browser_download_url"],
            "size": asset["size"],
        })
    versions.sort(key=lambda v: int(v["version"].split(".")[-1]), reverse=True)
    if not versions:
        raise RuntimeError("No published, nonempty test IPA releases were found")
    latest = versions[0]
    return {
        "name": "Husk ITRTG Test Builds",
        "identifier": SOURCE_ID,
        "sourceURL": source_url,
        "iconURL": ICON,
        "apps": [{
            "name": "Husk ITRTG Test",
            "bundleIdentifier": "com.husk.app",
            "developerName": "Husk open-source community fork",
            "subtitle": "Unity 6 + Google Play Games experiments",
            "localizedDescription": (
                "Experimental Husk builds for Idling to Rule the Gods. "
                "The latest entries may contain diagnostic code. "
                "Google Play Games online sync is NOT yet verified working. "
                "Sign the IPA with your own certificate in Feather."
            ),
            "iconURL": ICON,
            "tintColor": "5966D6",
            "category": "utilities",
            "version": latest["version"],
            "buildVersion": latest["buildVersion"],
            "versionDate": latest["date"],
            "downloadURL": latest["downloadURL"],
            "size": latest["size"],
            "versions": versions,
            "appPermissions": {},
        }],
    }


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    releases = json.loads(Path(sys.argv[1]).read_text())
    document = generate(releases, sys.argv[3])
    target = Path(sys.argv[2])
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
    print(f"Feather source: {sys.argv[3]}")
    print("Latest build:", document["apps"][0]["version"])
    print("Available builds:", len(document["apps"][0]["versions"]))


if __name__ == "__main__":
    main()
