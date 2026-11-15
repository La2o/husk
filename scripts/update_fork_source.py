#!/usr/bin/env python3
"""update_fork_source.py releases.json out.json SOURCE_URL [BASE_BUILD] [--all] -- the fork's AltStore / Feather source.

Every release the IPA workflow (.github/workflows/husk-ipa.yml) publishes is tagged fork-<Husk version>-<run> and carries
Husk.ipa. The source lists them newest first, so Feather, AltStore and SideStore offer the latest and keep the older ones a
tap away. It is written from the Releases API after each upload rather than from the workflow's artifacts, whose links expire.

Two sources are made from the same releases, and both list every build, newest first:
- the public one (source.json, the address people are given). A regular build from FIRST_WORKING_RUN on is described by its
  "What's new" -- the plain lines the release notes start with (the workflow collects them from "Changelog:" lines in the
  commits). An older one says that it does not work, and why. A test build of another branch (a prerelease) says first that
  it is one, and which regular build to go back to;
- with --all, the test channel (test-source.json): the same builds, each with the full release notes.
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
    "Every build is listed: a test build says so in its description, and names the regular build to go back to. "
    "Guide and problem reports: github.com/La2o/husk"
)
TEST_DESCRIPTION = (
    "The test channel of github.com/La2o/husk: every build, each with its branch, its commit and the changes since the build "
    "before. https://github.com/La2o/husk/releases/download/feed/source.json lists the same builds with a short What's new."
)
# 3.4.10: the first build that plays Idling to Rule the Gods with and without JIT. The builds before it are listed too, and
# say what is wrong with them.
FIRST_WORKING_RUN = 10
NOT_WORKING_EARLY = ("Not working: an early build. Idling to Rule the Gods crashes in it, at start or while playing. "
                     "Use the newest build.")
NOT_WORKING = {
    8: "Not working properly: Idling to Rule the Gods plays with JIT, but the time away is not counted after switching apps, "
       "and it crashes with Play without JIT. Use the newest build.",
    9: "Not working with Play without JIT: Idling to Rule the Gods plays with JIT only, and crashes without it. "
       "Use the newest build.",
}
WHATS_NEW_END = "<!-- end of what's new -->"
REPORT = "Problems? github.com/La2o/husk/issues, with the game's log (its page > Technical Details > Share Log)."
# What's new for builds whose release notes do not carry it (3.4.10), or carry what is no longer so (3.4.11 said the source
# lists only builds that work). These win over the release notes.
WHATS_NEW_INSTEAD = {
    11: ["No change to the game (same as 3.4.10)."],
    10: ["Unity 6 games, Idling to Rule the Gods among them, now play with Play without JIT too, so they start offline.",
         "With the earlier fixes: Play Games sign-in for online saves, no more crashes at start or after switching apps, "
         "and the time away is counted when you come back."],
}


def not_working(run: int) -> str:
    """What is wrong with a build from before the first working one; empty for the others."""
    return "" if run >= FIRST_WORKING_RUN else NOT_WORKING.get(run, NOT_WORKING_EARLY)


def test_build_note(name: str, regular: str) -> str:
    """What a test build says first: that it is one, of which branch, and the regular build to go back to."""
    m = re.search(r"\(([^()]+)\)\s*$", name or "")
    branch = f" of the branch {m.group(1)}" if m else ""
    back = f" If something is wrong in it, install {regular}, the newest regular build, again." if regular else ""
    return f"Test build{branch}: new, and not yet tried on a phone.{back}"


def whats_new(body: str, run: int) -> str:
    """The public description of a build: its What's new lines, and where to report a problem."""
    lines = list(WHATS_NEW_INSTEAD.get(run, []))
    if not lines and WHATS_NEW_END in body:
        for line in body.split(WHATS_NEW_END, 1)[0].splitlines():
            line = line.strip()
            if line.startswith("- "):
                lines.append(line[2:].strip())
    lines = lines or ["Fixes and improvements."]
    return "What's new:\n" + "\n".join(f"- {l}" for l in lines) + "\n\n" + REPORT


def generate(releases: list, source_url: str, base_build: str = "", everything: bool = False) -> dict:
    versions, seen = [], set()
    # the newest regular build: what a test build names as the one to go back to
    regular = max(((int(m.group(2)), f"{m.group(1)}.{m.group(2)}") for r in releases
                   if not r.get("draft") and not r.get("prerelease") and (m := TAG.fullmatch(r.get("tag_name", "")))),
                  default=(0, ""))[1]
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
        body, broken = (r.get("body") or "").strip(), not_working(run)
        test = test_build_note(r.get("name") or "", regular) if r.get("prerelease") else ""
        if everything:
            description = "\n\n".join(part for part in (broken, test, body) if part)
        else:
            description = broken or "\n\n".join(part for part in (test, whats_new(body, run)) if part)
        versions.append({
            "version": f"{base}.{run}",
            "buildVersion": f"{base_build}.{run}" if base_build else str(run),
            "run": run,
            "date": date,
            "localizedDescription": description[:4000],
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
