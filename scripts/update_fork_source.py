#!/usr/bin/env python3
"""update_fork_source.py releases.json out.json SOURCE_URL [BASE_BUILD] [--all] -- the fork's AltStore / Feather source.

Every release the IPA workflow (.github/workflows/husk-ipa.yml) publishes is tagged fork-<Husk version>-<run> and carries
Husk.ipa. The source lists them newest first, so Feather, AltStore and SideStore offer the latest and keep the older ones a
tap away. It is written from the Releases API after each upload rather than from the workflow's artifacts, whose links expire.

Two sources are made from the same releases:
- the public one (source.json, the address people are given): builds of main only, from the first one that plays Idling to
  Rule the Gods well (OLDEST_LISTED_RUN), each described by its "What's new" -- the plain lines the release notes start with
  (the workflow collects them from "Changelog:" lines in the commits);
- with --all, the test channel (test-source.json): every build of every branch, with the full release notes.
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
    "Husk runs Android games on iPhone. This version, based on Husk by Leviidev (github.com/Leviidev/Husk), adds what "
    "Idling to Rule the Gods needs: Google Play Games sign-in with your own Google account, so its online save is the same "
    "as on your other devices; fixes for Unity 6 games; and Play without JIT for them, so they start offline.\n\n"
    "Sign in to Husk's Store with the Google account you play with, then download the game from Husk's Store. "
    "Guide and problem reports: github.com/La2o/husk"
)
TEST_DESCRIPTION = (
    "The test channel of github.com/La2o/husk: every build of every branch, each with its branch, its commit and the changes "
    "since the build before. Test builds of other branches say so. For regular use, add "
    "https://github.com/La2o/husk/releases/download/feed/source.json instead."
)
# 3.4.10: the first build that plays Idling to Rule the Gods with and without JIT. The builds before it crashed (Unity 6's
# allocator, Play without JIT) or did not count the time away; they stay on GitHub, but the public source does not offer them.
OLDEST_LISTED_RUN = 10
WHATS_NEW_END = "<!-- end of what's new -->"
REPORT = "Problems? github.com/La2o/husk/issues, with the game's log (its page > Technical Details > Share Log)."
# What's new for builds published before the release notes carried it.
EARLIER_WHATS_NEW = {
    10: ["Unity 6 games, Idling to Rule the Gods among them, now play with Play without JIT too, so they start offline.",
         "With the earlier fixes: Play Games sign-in for online saves, no more crashes at start or after switching apps, "
         "and the time away is counted when you come back."],
}


def whats_new(body: str, run: int) -> str:
    """The public description of a build: its What's new lines, and where to report a problem."""
    lines = []
    if WHATS_NEW_END in body:
        for line in body.split(WHATS_NEW_END, 1)[0].splitlines():
            line = line.strip()
            if line.startswith("- "):
                lines.append(line[2:].strip())
    lines = lines or EARLIER_WHATS_NEW.get(run, []) or ["Fixes and improvements."]
    return "What's new:\n" + "\n".join(f"- {l}" for l in lines) + "\n\n" + REPORT


def generate(releases: list, source_url: str, base_build: str = "", everything: bool = False) -> dict:
    versions, seen = [], set()
    for r in releases:
        m = TAG.fullmatch(r.get("tag_name", ""))
        if not m or r.get("draft"):
            continue
        base, run = m.group(1), int(m.group(2))
        if run in seen:
            continue
        if not everything and (r.get("prerelease") or run < OLDEST_LISTED_RUN):
            continue                                   # a test build of another branch, or one from before ITRTG played well
        assets = [a for a in r.get("assets", [])
                  if a.get("name") == IPA and a.get("size", 0) > 0 and a.get("state", "uploaded") == "uploaded"]
        if len(assets) != 1:
            continue
        seen.add(run)
        date = r.get("published_at") or r.get("created_at") or datetime.now(timezone.utc).isoformat()
        versions.append({
            "version": f"{base}.{run}",
            "buildVersion": f"{base_build}.{run}" if base_build else str(run),
            "run": run,
            "date": date,
            "localizedDescription": ((r.get("body") or "").strip() if everything
                                     else whats_new(r.get("body") or "", run))[:4000],
            "downloadURL": assets[0]["browser_download_url"],
            "size": assets[0]["size"],
            "minOSVersion": "15.5",
        })
    versions.sort(key=lambda v: v["run"], reverse=True)
    for v in versions:
        del v["run"]
    if not versions:
        raise SystemExit("no published fork-<version>-<run> release with Husk.ipa")
    latest = versions[0]
    return {
        "name": "Husk (La2o fork)" + (" - test channel" if everything else ""),
        "identifier": SOURCE_ID + (".test" if everything else ""),
        "sourceURL": source_url,
        "iconURL": ICON,
        "website": f"https://github.com/{REPO}",
        "tintColor": "#5865F2",
        "apps": [{
            "name": "Husk",
            "bundleIdentifier": "com.husk.app",
            "developerName": "Leviidev (Husk), La2o (fork)",
            "subtitle": "Android games on iPhone, signed in to Play Games for online saves.",
            "localizedDescription": TEST_DESCRIPTION if everything else DESCRIPTION,
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
    args = [a for a in sys.argv[1:] if a != "--all"]
    everything = "--all" in sys.argv[1:]
    if len(args) not in (3, 4):
        raise SystemExit(__doc__)
    doc = generate(read_pages(Path(args[0]).read_text()), args[2], args[3] if len(args) == 4 else "", everything)
    Path(args[1]).write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    app = doc["apps"][0]
    print(f"source {args[2]}: latest {app['version']}, {len(app['versions'])} build(s)")


if __name__ == "__main__":
    main()
