"""Local legal authority library: load verified sources, full-text search, quote verification."""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

from ..config import Settings
from ..db import Database

SECTION_SPLIT_RE = re.compile(r"(?m)^(?=Sec\. \d+\.\d+\.)")
SECTION_HEAD_RE = re.compile(r"^Sec\. (?P<num>\d+\.\d+)\.\s+(?P<title>[^.]+(?:\.[^.]+)*?)\.\s{2}", re.S)

CODE_SLUG = {"Tex. Prop. Code §": "tx-prop", "Tex. Civ. Prac. & Rem. Code §": "tx-cprc", "Tex. Bus. & Com. Code §": "tx-bcc", "Tex. Gov't Code §": "tx-gov"}


def normalize_ws(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


class AuthorityService:
    def __init__(self, db: Database, settings: Settings):
        self.db = db
        self.settings = settings

    # ---- loading --------------------------------------------------------
    def load_library_if_empty(self) -> int:
        count = self.db.query_one("SELECT COUNT(*) AS n FROM authorities")["n"]
        if count:
            return 0
        return self.reload_library()

    def reload_library(self) -> int:
        sources_dir = self.settings.library_dir / "sources"
        inserted = 0
        with self.db.tx() as conn:
            conn.execute("DELETE FROM authorities")
            conn.execute("DELETE FROM authorities_fts")
            for path in sorted(sources_dir.glob("*.json")):
                src = json.loads(path.read_text())
                for auth in split_source(src):
                    conn.execute(
                        "INSERT INTO authorities(id,citation,title,jurisdiction,authority_type,binding_scope,source_url,retrieved_at,sha256,text,metadata_json)"
                        " VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                        (auth["id"], auth["citation"], auth["title"], auth["jurisdiction"], auth["authority_type"], auth["binding_scope"],
                         auth["source_url"], auth["retrieved_at"], auth["sha256"], auth["text"], json.dumps(auth["metadata"])),
                    )
                    conn.execute("INSERT INTO authorities_fts(citation,title,text,authority_id) VALUES(?,?,?,?)",
                                 (auth["citation"], auth["title"], auth["text"], auth["id"]))
                    inserted += 1
        return inserted

    # ---- queries --------------------------------------------------------
    def get(self, authority_id: str) -> dict[str, Any] | None:
        row = self.db.query_one("SELECT * FROM authorities WHERE id=?", (authority_id,))
        if row is None:
            return None
        d = dict(row)
        d["metadata"] = json.loads(d.pop("metadata_json"))
        return d

    def exists(self, authority_id: str) -> bool:
        return self.db.query_one("SELECT 1 FROM authorities WHERE id=?", (authority_id,)) is not None

    def list(self) -> list[dict[str, Any]]:
        rows = self.db.query("SELECT id,citation,title,jurisdiction,authority_type,binding_scope,source_url,retrieved_at,sha256 FROM authorities ORDER BY id")
        return [dict(r) for r in rows]

    def search(self, query: str, limit: int = 10) -> list[dict[str, Any]]:
        terms = re.findall(r"[A-Za-z0-9][A-Za-z0-9'\.\-]{1,40}", query)
        if not terms:
            return []
        q = " OR ".join(f'"{t}"' for t in terms[:16])
        rows = self.db.query(
            "SELECT a.id, a.citation, a.title, snippet(authorities_fts, 2, '[', ']', '…', 30) AS snippet, bm25(authorities_fts) AS score"
            " FROM authorities_fts f JOIN authorities a ON a.id = f.authority_id WHERE authorities_fts MATCH ? ORDER BY score LIMIT ?",
            (q, limit),
        )
        return [dict(r) for r in rows]

    def verify_quote(self, authority_id: str, quote: str) -> tuple[bool, str]:
        auth = self.get(authority_id)
        if auth is None:
            return False, "unknown_authority"
        if not quote or not quote.strip():
            return True, "no_quote"
        hay = normalize_ws(auth["text"]).lower()
        needle = normalize_ws(quote).lower().strip('"“”')
        if needle in hay:
            return True, "exact"
        # tolerate small omissions: require 85% of the quote's 6-grams to be present
        words = needle.split()
        if len(words) < 6:
            return False, "quote_not_found"
        grams = [" ".join(words[i : i + 6]) for i in range(len(words) - 5)]
        hits = sum(1 for g in grams if g in hay)
        return (hits / len(grams) >= 0.85, "fuzzy" if hits / len(grams) >= 0.85 else "quote_not_found")

    def packet_for_prompt(self, authority_ids: list[str] | None = None, max_chars: int = 30000) -> str:
        """Render library entries for inclusion in a stage prompt (ids, citations, titles, and text)."""
        rows = (
            [self.get(a) for a in authority_ids if self.get(a)] if authority_ids else
            [dict(r) | {"metadata": json.loads(r["metadata_json"])} for r in self.db.query("SELECT * FROM authorities ORDER BY id")]
        )
        out: list[str] = []
        used = 0
        for a in rows:
            block = f"[{a['id']}] {a['citation']} — {a['title']}\n{a['text'].strip()}\n"
            if used + len(block) > max_chars:
                out.append(f"[... {len(rows) - len(out)} further authorities omitted for length; search the library index by id ...]")
                break
            out.append(block)
            used += len(block)
        return "\n".join(out)

    def index_for_prompt(self) -> str:
        return "\n".join(f"{a['id']}: {a['citation']} — {a['title']}" for a in self.list())


def split_source(src: dict[str, Any]) -> list[dict[str, Any]]:
    prefix = src.get("citation_prefix", "Tex. Code §")
    slug = CODE_SLUG.get(prefix, "tx-" + re.sub(r"[^a-z]", "", prefix.lower())[:6])
    parts = [p.strip() for p in SECTION_SPLIT_RE.split(src["text"]) if p.strip()]
    out = []
    for part in parts:
        m = SECTION_HEAD_RE.match(part)
        if not m:
            continue
        num = m.group("num")
        title = normalize_ws(m.group("title")).title().replace("'S", "'s")
        text = part.strip() + "\n"
        out.append({
            "id": f"{slug}-{num}",
            "citation": f"{prefix} {num}",
            "title": title,
            "jurisdiction": src.get("jurisdiction", "US-TX"),
            "authority_type": src.get("authority_type", "statute"),
            "binding_scope": src.get("binding_scope", "statewide"),
            "source_url": src["source_url"],
            "retrieved_at": src["retrieved_at"],
            "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "text": text,
            "metadata": {
                "source_id": src["source_id"],
                "source_title": src["title"],
                "publisher": src.get("publisher"),
                "currency_statement": src.get("currency_statement"),
                "retrieval_method": src.get("retrieval_method"),
                "sections_included": src.get("sections_included"),
            },
        })
    return out
