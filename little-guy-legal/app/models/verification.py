from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

CheckStatus = Literal[
    "verified",
    "quote_mismatch",
    "location_not_found",
    "unknown_document",
    "unknown_authority",
    "invalid_ref",
    "no_evidence",
    "consistency_warning",
]


class VerificationCheck(BaseModel):
    target: str = Field(description="Dotted path to the finding, e.g. knowledge.facts.F2")
    ref: str | None
    kind: Literal["document", "authority", "finding"]
    status: CheckStatus
    material: bool
    detail: str = ""
    resolved_location: str | None = None


class VerificationSummary(BaseModel):
    total_checks: int
    verified: int
    failed: int
    material_failures: int
    unsupported_findings: int
    fabricated_authority_refs: int


class VerificationReport(BaseModel):
    run_id: str
    checks: list[VerificationCheck]
    summary: VerificationSummary
    material_failure: bool
    notes: list[str] = Field(default_factory=list)
    limitations: list[str] = Field(default_factory=list)
