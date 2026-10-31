"""Shared value types used across stage schemas."""
from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel, Field, field_validator

# Evidence reference grammar understood by the verifier.
#   D3:p2      -> document ordinal 3, page 2 (PDF)
#   D2:para14  -> document ordinal 2, paragraph 14 (DOCX)
#   A:tx-prop-93.002 -> legal authority id in the local library
DOC_REF_RE = re.compile(r"^D(?P<doc>\d+):(?:p(?P<page>\d+)|para(?P<para>\d+))$")
AUTH_REF_RE = re.compile(r"^A:(?P<id>[a-z0-9][a-z0-9\-\._]{1,80})$")

Basis = Literal["documented", "customer_allegation", "inference", "unverified"]
Confidence = Literal["low", "moderate", "high"]
BindingStatus = Literal["binding", "persuasive", "unverified"]


class EvidenceRef(BaseModel):
    """A pointer to a source passage (document) or authority with an optional verbatim quote."""

    ref: str = Field(description="D{n}:p{page} | D{n}:para{index} | A:{authority_id}")
    quote: str | None = Field(default=None, description="Verbatim excerpt from the source")

    @field_validator("ref")
    @classmethod
    def _normalize(cls, v: str) -> str:
        return v.strip()

    @property
    def kind(self) -> Literal["document", "authority", "invalid"]:
        if DOC_REF_RE.match(self.ref):
            return "document"
        if AUTH_REF_RE.match(self.ref):
            return "authority"
        return "invalid"
