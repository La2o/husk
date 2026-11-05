#!/usr/bin/env python3
"""update_fork_source.py releases.json out.json SOURCE_URL -- the fork's AltStore / Feather source, from its GitHub releases.

Every release the IPA workflow (.github/workflows/husk-ipa.yml) publishes is tagged fork-<Husk version>-<run> and carries
Husk.ipa. The source lists them newest first, so Feather, AltStore and SideStore offer the latest and keep the older ones a
tap away. It is written from the Releases API after each upload rather than from the workflow's artifacts, whose links expire.
"""
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = "La2o/husk"
SOURCE_ID = "com.la2o.husk"
ICON = f"https://raw.githubusercontent.com/{REPO}/refs/heads/main/src/app/Husk/Assets.xcassets/AppIcon.appiconset/Icon-Default.png"
IPA = "Husk.ipa"
TAG = re.compile(r"fork-(\d+(?:\.\d+)*)-(\d+)")
DESCRIPTION = (
    "Husk (github.com/Leviidev/Husk) with this fork's changes on top: Google Play Games sign-in with your own Google "
    "account, so games that save online under their Play Games player (Idling to Rule the Gods) find the same saves as "
    "on Android; every game's saves copied to an iCloud Drive folder each time you leave Husk; and Unity 6 start-up and "
    "frame fixes. Sign the IPA with your own certificate in Feather, AltStore or SideStore."
)


def generate(releases: list, source_url: str) -> dict:
    versions, seen = [], set()
    for r in releases:
        m = TAG.fullmatch(r.get("tag_name", ""))
        if not m or r.get("draft"):
            continue
        base, run = m.group(1), int(m.group(2))
        if run in seen:
            continue
        assets = [a for a in r.get("assets", [])
                  if a.get("name") == IPA and a.get("size", 0) > 0 and a.get("state", "uploaded") == "uploaded"]
        if len(assets) != 1:
            continue
        seen.add(run)
        date = r.get("published_at") or r.get("created_at") or datetime.now(timezone.utc).isoformat()
        versions.append({
            "version": f"{base}.{run}",
            "buildVersion": str(run),
            "date": date,
            "localizedDescription": (r.get("body") or "").strip()[:4000],
            "downloadURL": assets[0]["browser_download_url"],
            "size": assets[0]["size"],
            "minOSVersion": "15.5",
        })
    versions.sort(key=lambda v: int(v["buildVersion"]), reverse=True)
    if not versions:
        raise SystemExit("no published fork-<version>-<run> release with Husk.ipa")
    latest = versions[0]
    return {
        "name": "Husk (La2o fork)",
        "identifier": SOURCE_ID,
        "sourceURL": source_url,
        "iconURL": ICON,
        "website": f"https://github.com/{REPO}",
        "tintColor": "#5865F2",
        "apps": [{
            "name": "Husk",
            "bundleIdentifier": "com.husk.app",
            "developerName": "Leviidev (Husk), La2o (fork)",
            "subtitle": "Android games on iPhone, with Play Games and iCloud saves.",
            "localizedDescription": DESCRIPTION,
            "iconURL": ICON,
            "tintColor": "#5865F2",
            "category": "utilities",
            "version": latest["version"],
            "buildVersion": latest["buildVersion"],
            "versionDate": latest["date"],
            "downloadURL": latest["downloadURL"],
            "size": latest["size"],
            "versions": versions,
            "appPermissions": {},
        }],
        "news": [],
    }


def read_pages(text: str) -> list:
    """`gh api --paginate` writes one JSON array per page, one after another: all of them, as one list."""
    out, dec, i = [], json.JSONDecoder(), 0
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return out
        page, i = dec.raw_decode(text, i)
        out += page if isinstance(page, list) else [page]


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    doc = generate(read_pages(Path(sys.argv[1]).read_text()), sys.argv[3])
    Path(sys.argv[2]).write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    app = doc["apps"][0]
    print(f"source {sys.argv[3]}: latest {app['version']}, {len(app['versions'])} build(s)")


if __name__ == "__main__":
    main()
