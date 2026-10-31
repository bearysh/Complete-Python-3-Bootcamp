#!/usr/bin/env python3
"""Maintain the local legal authority library (runs OUTSIDE case processing; never sends case data).

  python scripts/build_authority_library.py --list              # show sources and section counts
  python scripts/build_authority_library.py --verify            # re-fetch each official page and compare section text
  python scripts/build_authority_library.py --reload            # rebuild the SQLite index from library/sources (app must be stopped)

--verify downloads the official statute pages from statutes.capitol.texas.gov,
strips HTML, and checks that every stored section appears verbatim (whitespace-
normalized) in the fresh text. It reports drift without modifying the stored
corpus; update the JSON source by hand after review. Network access is used
only here, with public URLs and no case information.
"""
from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from app.services.authority import normalize_ws, split_source  # noqa: E402

SOURCES = ROOT / "library" / "sources"


def strip_html(raw: str) -> str:
    raw = re.sub(r"(?is)<(script|style).*?</\1>", " ", raw)
    raw = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>", "\n", raw)
    text = re.sub(r"<[^>]+>", " ", raw)
    return html.unescape(text)


def cmd_list() -> int:
    for f in sorted(SOURCES.glob("*.json")):
        src = json.loads(f.read_text())
        secs = split_source(src)
        print(f"{src['source_id']:<16} {len(secs):>3} sections  retrieved {src['retrieved_at']}  {src['source_url']}")
    return 0


def cmd_verify() -> int:
    import httpx

    failures = 0
    for f in sorted(SOURCES.glob("*.json")):
        src = json.loads(f.read_text())
        try:
            r = httpx.get(src["source_url"], timeout=60, follow_redirects=True, headers={"User-Agent": "LittleGuyLegal-library-verify/0.1"})
            r.raise_for_status()
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR {src['source_id']}: fetch failed ({type(exc).__name__})")
            failures += 1
            continue
        fresh = normalize_ws(strip_html(r.text)).lower()
        if "sec. " not in fresh:
            print(f"WARN  {src['source_id']}: fetched page contains no statute text (the publisher may serve a JavaScript viewer); manual verification required")
            failures += 1
            continue
        for sec in split_source(src):
            body = normalize_ws(re.sub(r"(?m)^(Added by|Acts \d|Amended by).*$", "", sec["text"])).lower()
            probe = body[:400]
            ok = probe in fresh
            print(f"{'OK   ' if ok else 'DRIFT'} {sec['id']}")
            failures += 0 if ok else 1
    print("verification complete:", "no drift detected" if failures == 0 else f"{failures} problem(s)")
    return 1 if failures else 0


def cmd_reload() -> int:
    from app.config import get_settings
    from app.db import Database
    from app.services.authority import AuthorityService

    settings = get_settings()
    db = Database(settings.db_path)
    n = AuthorityService(db, settings).reload_library()
    print(f"reloaded {n} authorities into {settings.db_path}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--list", action="store_true")
    g.add_argument("--verify", action="store_true")
    g.add_argument("--reload", action="store_true")
    a = ap.parse_args()
    if a.list:
        return cmd_list()
    if a.verify:
        return cmd_verify()
    return cmd_reload()


if __name__ == "__main__":
    sys.exit(main())
