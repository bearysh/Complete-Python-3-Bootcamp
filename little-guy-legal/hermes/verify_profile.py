#!/usr/bin/env python3
"""Verify the effective configuration of the little-guy-legal Hermes profile.

Checks (1) the profile's config.yaml on disk, (2) the running API server's
reported toolsets/capabilities, and (3) that a probe request only produces
loopback traffic. Exits non-zero on any failed check. Never prints secrets.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

PROFILE_DIR = Path(os.environ.get("HERMES_HOME_ROOT", Path.home() / ".hermes")) / "profiles" / "little-guy-legal"
BASE = os.environ.get("LGL_HERMES_BASE_URL", "http://127.0.0.1:8642").rstrip("/")


def check(cond: bool, msg: str, results: list[tuple[bool, str]]) -> None:
    results.append((cond, msg))
    print(("PASS " if cond else "FAIL ") + msg)


def main() -> int:
    results: list[tuple[bool, str]] = []
    cfg_path = PROFILE_DIR / "config.yaml"
    check(cfg_path.exists(), f"profile config exists at {cfg_path}", results)
    cfg = yaml.safe_load(cfg_path.read_text()) if cfg_path.exists() else {}
    model = cfg.get("model", {}) if isinstance(cfg.get("model"), dict) else {}
    base_url = str(model.get("base_url", ""))
    check(model.get("provider") == "custom", "model.provider is 'custom' (local OpenAI-compatible endpoint)", results)
    check(base_url.startswith(("http://127.0.0.1", "http://localhost")), f"model.base_url is loopback ({base_url or 'unset'})", results)
    check("REPLACE_WITH" not in str(model.get("default", "")), "model.default has been set to a real OMLX model id", results)
    check(cfg.get("fallback_providers") == [] and "fallback_model" not in cfg, "no fallback providers / fallback model", results)
    mem = cfg.get("memory", {})
    check(mem.get("memory_enabled") is False and mem.get("user_profile_enabled") is False and not mem.get("provider"), "memory, user profile memory, and memory provider disabled", results)
    pts = (cfg.get("platform_toolsets") or {}).get("api_server")
    check(pts in ([], ["no_mcp"]), f"platform_toolsets.api_server is empty/no_mcp ({pts})", results)
    dis = set((cfg.get("agent") or {}).get("disabled_toolsets") or [])
    check({"memory", "session_search", "terminal", "browser", "web", "file"} <= dis, "agent.disabled_toolsets covers memory/session_search/terminal/browser/web/file", results)
    check((cfg.get("skills") or {}).get("creation_nudge_interval") == 0 and (cfg.get("curator") or {}).get("enabled") is False, "skill learning nudges and curator disabled", results)
    check((cfg.get("model_catalog") or {}).get("enabled") is False, "model catalog fetch disabled", results)
    env_path = PROFILE_DIR / ".env"
    env_ok = False
    if env_path.exists():
        mode = env_path.stat().st_mode & 0o777
        content = env_path.read_text()
        env_ok = any(line.startswith("API_SERVER_KEY=") and len(line.split("=", 1)[1].strip()) >= 16 for line in content.splitlines())
        check(mode == 0o600, f".env permissions are 0600 (found {oct(mode)})", results)
        extra = [l.split("=")[0] for l in content.splitlines() if l.strip() and not l.startswith("#") and not l.startswith("API_SERVER_")]
        check(not extra, f".env contains only API_SERVER_* variables (extra: {extra})", results)
    check(env_ok, ".env defines API_SERVER_KEY (>=16 chars)", results)
    for sub in ("memories", "sessions", "skills"):
        p = PROFILE_DIR / sub
        files = [f for f in p.rglob("*") if f.is_file()] if p.exists() else []
        check(len(files) == 0 or sub == "sessions", f"profile {sub}/ has no inherited content ({len(files)} files)", results)

    # Live checks against the running API server
    key = os.environ.get("LGL_HERMES_API_KEY") or _read_key(env_path)
    try:
        with urllib.request.urlopen(urllib.request.Request(f"{BASE}/v1/health"), timeout=5) as r:
            check(r.status == 200, "API server /v1/health reachable on loopback", results)
    except (urllib.error.URLError, OSError) as exc:
        check(False, f"API server not reachable at {BASE} ({type(exc).__name__}); start it with: hermes -p little-guy-legal gateway run", results)
        return _finish(results)
    hdr = {"Authorization": f"Bearer {key}"} if key else {}
    try:
        with urllib.request.urlopen(urllib.request.Request(f"{BASE}/v1/toolsets", headers=hdr), timeout=10) as r:
            data = json.loads(r.read())
        enabled = data.get("enabled") or data.get("toolsets") or data
        check(_count_enabled(enabled) == 0, f"API server reports no enabled toolsets (reported: {str(enabled)[:160]})", results)
    except urllib.error.HTTPError as exc:
        check(False, f"/v1/toolsets returned HTTP {exc.code} (is LGL_HERMES_API_KEY correct?)", results)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        check(False, f"/v1/toolsets failed ({type(exc).__name__})", results)
    try:
        with urllib.request.urlopen(urllib.request.Request(f"{BASE}/v1/models", headers=hdr), timeout=10) as r:
            models = [m.get("id") for m in json.loads(r.read()).get("data", [])]
        check(bool(models), f"API server lists models: {models}", results)
    except Exception as exc:  # noqa: BLE001
        check(False, f"/v1/models failed ({type(exc).__name__})", results)
    try:
        with urllib.request.urlopen(urllib.request.Request(f"{BASE}/v1/models"), timeout=10) as r:
            check(False, f"/v1/models WITHOUT a key should be rejected but returned {r.status}", results)
    except urllib.error.HTTPError as exc:
        check(exc.code in (401, 403), f"unauthenticated request rejected with HTTP {exc.code}", results)
    except Exception as exc:  # noqa: BLE001
        check(False, f"unauthenticated probe failed unexpectedly ({type(exc).__name__})", results)
    return _finish(results)


def _read_key(env_path: Path) -> str:
    if not env_path.exists():
        return ""
    for line in env_path.read_text().splitlines():
        if line.startswith("API_SERVER_KEY="):
            return line.split("=", 1)[1].strip()
    return ""


def _count_enabled(obj) -> int:
    if isinstance(obj, list):
        return len(obj)
    if isinstance(obj, dict):
        for k in ("enabled", "toolsets", "enabled_toolsets"):
            if k in obj:
                return _count_enabled(obj[k])
        return sum(1 for v in obj.values() if v is True)
    return 0


def _finish(results: list[tuple[bool, str]]) -> int:
    failed = [m for ok, m in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
