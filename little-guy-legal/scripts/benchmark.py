#!/usr/bin/env python3
"""Benchmark the configured local inference path.

Sends N short structured-output probes through the configured provider
(Hermes by default; use LGL_INFERENCE_PROVIDER=omlx for the direct path) and
records latency, tokens/sec, and peak memory of this process. Also reports
system memory if psutil is available. No case data is used.

Usage: python scripts/benchmark.py [--n 3] [--out docs/benchmarks/latest.json]
"""
from __future__ import annotations

import argparse
import json
import platform
import resource
import secrets
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.config import Settings  # noqa: E402
from app.inference.base import CancelToken, InferenceRequest  # noqa: E402
from app.inference.factory import build_provider  # noqa: E402

PROBE_SYSTEM = "You are a JSON-only assistant. Output exactly one JSON object and nothing else."
PROBE_USER = ("Return a JSON object with keys: summary (one sentence about why written notice clauses matter in commercial leases), "
              "items (an array of exactly three short strings), and confidence (one of low, moderate, high).")


def peak_rss_mb() -> float:
    ru = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return ru / (1024 * 1024) if platform.system() == "Darwin" else ru / 1024


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=3)
    ap.add_argument("--out", default=str(ROOT / "docs/benchmarks/latest.json"))
    a = ap.parse_args()
    settings = Settings()
    provider = build_provider(settings)
    print(f"Provider: {provider.info.label} @ {provider.info.endpoint} model={provider.info.model}")
    health = provider.health()
    print("Health:", json.dumps(health)[:300])
    samples = []
    for i in range(a.n):
        req = InferenceRequest(PROBE_SYSTEM, PROBE_USER, session_id=f"lgl-bench-{secrets.token_hex(8)}", stage="benchmark", max_tokens=400,
                               timeout_seconds=settings.request_timeout_seconds)
        t0 = time.monotonic()
        resp = provider.complete(req, CancelToken())
        dt = time.monotonic() - t0
        tps = (resp.completion_tokens / dt) if resp.completion_tokens else None
        samples.append({"latency_s": round(dt, 2), "prompt_tokens": resp.prompt_tokens, "completion_tokens": resp.completion_tokens, "tokens_per_s": round(tps, 1) if tps else None,
                        "valid_json": _is_json(resp.text)})
        print(f"  probe {i + 1}: {dt:.1f}s, {resp.completion_tokens} tokens, {tps and round(tps, 1)} tok/s, json={samples[-1]['valid_json']}")
        provider.cleanup_session(req.session_id)
    sysmem = None
    try:
        import psutil  # type: ignore

        vm = psutil.virtual_memory()
        sysmem = {"total_gb": round(vm.total / 1e9, 1), "available_gb": round(vm.available / 1e9, 1)}
    except Exception:
        pass
    result = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"), "platform": platform.platform(), "provider": provider.info.name, "endpoint": provider.info.endpoint,
        "model": provider.info.model, "is_real_inference": provider.info.is_real_inference, "health": health, "samples": samples,
        "median_latency_s": statistics.median(s["latency_s"] for s in samples) if samples else None,
        "process_peak_rss_mb": round(peak_rss_mb(), 1), "system_memory": sysmem,
        "note": "Peak memory of the inference server itself must be read from OMLX/Activity Monitor; this records the application process only.",
    }
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(result, indent=1))
    print(json.dumps({k: v for k, v in result.items() if k not in ("samples", "health")}, indent=1))
    return 0


def _is_json(text: str) -> bool:
    from app.inference.json_utils import extract_json_object

    try:
        extract_json_object(text)
        return True
    except Exception:
        return False


if __name__ == "__main__":
    sys.exit(main())
