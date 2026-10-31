"""Structured output schemas for each specialist stage.

Every schema is validated with Pydantic before a stage is marked complete. Local
models are instructed to emit exactly these shapes; a bounded repair loop feeds
validation errors back when they do not.
"""
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

from .common import Basis, BindingStatus, Confidence, EvidenceRef

ArgumentStyle = Literal["by_the_book", "aggressive", "maximum_challenge"]
Side = Literal["customer", "opposing"]


class Party(BaseModel):
    name: str
    role: str = Field(description="landlord | tenant | guarantor | agent | other")
    refs: list[EvidenceRef] = Field(default_factory=list)


class DocumentSummary(BaseModel):
    doc_ref: str = Field(description="D{n}")
    document_type: str
    summary: str


class Provision(BaseModel):
    id: str = Field(description="P1, P2, ...")
    title: str
    summary: str
    refs: list[EvidenceRef] = Field(default_factory=list)
    ambiguity_notes: str | None = None


class Fact(BaseModel):
    id: str = Field(description="F1, F2, ...")
    statement: str
    basis: Basis
    date: str | None = None
    refs: list[EvidenceRef] = Field(default_factory=list)


class TimelineEvent(BaseModel):
    date: str
    description: str
    basis: Basis
    refs: list[EvidenceRef] = Field(default_factory=list)


class LegalQuestion(BaseModel):
    id: str = Field(description="Q1, Q2, ...")
    question: str
    why_it_matters: str


class AuthorityUse(BaseModel):
    authority_id: str = Field(description="Exact id from the authority library, or 'none' if not in library")
    citation: str
    relevance: str
    binding_status: BindingStatus
    quote: str | None = None


class KnowledgeOutput(BaseModel):
    parties: list[Party]
    document_summaries: list[DocumentSummary]
    key_provisions: list[Provision]
    facts: list[Fact]
    timeline: list[TimelineEvent]
    legal_questions: list[LegalQuestion]
    candidate_authorities: list[AuthorityUse]
    missing_information: list[str]
    caveats: list[str] = Field(default_factory=list)


class Argument(BaseModel):
    id: str
    title: str
    summary: str
    supporting_fact_ids: list[str] = Field(default_factory=list)
    supporting_provision_ids: list[str] = Field(default_factory=list)
    supporting_authority_ids: list[str] = Field(default_factory=list)
    refs: list[EvidenceRef] = Field(default_factory=list)
    assumptions: list[str] = Field(default_factory=list)
    evidentiary_weaknesses: list[str] = Field(default_factory=list)
    anticipated_counterarguments: list[str] = Field(default_factory=list)
    confidence: Confidence
    confidence_rationale: str


class ArgumentOutput(BaseModel):
    position: Side
    style: ArgumentStyle
    arguments: list[Argument]
    overall_assessment: str


class IssueAssessment(BaseModel):
    issue_id: str
    issue: str
    stronger_side: Literal["customer", "opposing", "unclear"]
    reasoning: str
    unsupported_claims: list[str] = Field(default_factory=list)
    evidence_gaps: list[str] = Field(default_factory=list)
    procedural_concerns: list[str] = Field(default_factory=list)
    refs: list[EvidenceRef] = Field(default_factory=list)


class UnsupportedInterpretation(BaseModel):
    argument_id: str
    problem: str


class ProvisionConflict(BaseModel):
    provision_ids: list[str]
    description: str


class EvidenceNeed(BaseModel):
    item: str
    why_it_matters: str
    priority: Literal["high", "medium", "low"]


class JudgeOutput(BaseModel):
    issue_assessments: list[IssueAssessment]
    unsupported_interpretations: list[UnsupportedInterpretation] = Field(default_factory=list)
    conflicting_provisions: list[ProvisionConflict] = Field(default_factory=list)
    additional_evidence_needed: list[EvidenceNeed] = Field(default_factory=list)
    attorney_review_required: list[str] = Field(default_factory=list)
    overall_commentary: str


class Issue(BaseModel):
    id: str
    title: str
    explanation: str
    customer_position: str
    opposing_position: str
    current_assessment: str
    refs: list[EvidenceRef] = Field(default_factory=list)


class TimeSensitiveConcern(BaseModel):
    concern: str
    date_or_deadline: str
    basis: Basis
    refs: list[EvidenceRef] = Field(default_factory=list)


class SeniorPartnerOutput(BaseModel):
    executive_summary: str
    main_issues: list[Issue]
    time_sensitive_concerns: list[TimeSensitiveConcern] = Field(default_factory=list)
    information_gaps: list[str] = Field(default_factory=list)
    practical_considerations: list[str] = Field(default_factory=list)
    questions_for_attorney: list[str]
    unverified_claims: list[str] = Field(default_factory=list)


STAGE_SCHEMAS: dict[str, type[BaseModel]] = {
    "knowledge": KnowledgeOutput,
    "advocate_customer": ArgumentOutput,
    "advocate_opposing": ArgumentOutput,
    "judge": JudgeOutput,
    "senior_partner": SeniorPartnerOutput,
}
