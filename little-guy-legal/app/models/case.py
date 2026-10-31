from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

CaseStatus = Literal["intake", "analyzing", "analyzed", "report_draft", "report_approved", "report_rejected"]
DocKind = Literal["lease", "amendment", "notice", "communication", "invoice", "photo", "other", "unknown"]


class CaseCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    county: str = Field(default="Tarrant", max_length=80)


class CaseOut(BaseModel):
    id: str
    title: str
    status: CaseStatus
    jurisdiction: str
    county: str
    matter_type: str
    created_at: str
    updated_at: str
    document_count: int = 0
    has_intake: bool = False
    latest_run_id: str | None = None
    latest_run_status: str | None = None
    latest_report_id: str | None = None
    latest_report_status: str | None = None


class DocumentOut(BaseModel):
    id: str
    case_id: str
    ordinal: int
    ref_prefix: str
    filename: str
    mime: str
    doc_kind: str
    size_bytes: int
    sha256: str
    uploaded_at: str
    extraction_status: str
    extraction_error: str | None = None
    page_count: int | None = None
    segment_count: int | None = None
    unreadable_pages: list[int] = Field(default_factory=list)


class SegmentOut(BaseModel):
    id: int
    document_id: str
    ref: str
    locator_type: str
    page_number: int | None
    paragraph_index: int | None
    section_label: str | None
    text: str


class IntakeDate(BaseModel):
    label: str = Field(max_length=200)
    date: str = Field(max_length=40, description="ISO date or free text if uncertain")
    confirmed: bool = False


class IntakeNotice(BaseModel):
    kind: str = Field(max_length=120, description="e.g. notice of default, demand letter, lawsuit filed")
    date: str = Field(default="", max_length=40)
    description: str = Field(default="", max_length=2000)


class IntakeData(BaseModel):
    user_role: Literal["landlord", "tenant", "guarantor", "other", "unknown"] = "unknown"
    narrative: str = Field(default="", max_length=20000, description="What happened?")
    desired_outcome: str = Field(default="", max_length=5000)
    key_dates: list[IntakeDate] = Field(default_factory=list)
    prior_notices: list[IntakeNotice] = Field(default_factory=list)
    confirmed_inferences: dict[str, bool] = Field(
        default_factory=dict, description="High-impact facts inferred from documents that the user confirmed/denied"
    )

    def missing_essentials(self) -> list[str]:
        missing = []
        if self.user_role == "unknown":
            missing.append("user_role")
        if not self.narrative.strip():
            missing.append("narrative")
        if not self.desired_outcome.strip():
            missing.append("desired_outcome")
        return missing
