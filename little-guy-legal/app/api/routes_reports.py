from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from ..services.cases import CaseNotFound
from ..state import AppState
from .deps import get_state

router = APIRouter(prefix="/api/cases/{case_id}/reports", tags=["reports"])


def _check(state: AppState, case_id: str) -> None:
    try:
        state.cases.get(case_id)
    except CaseNotFound:
        raise HTTPException(404, "Case not found")


@router.get("")
def list_reports(case_id: str, state: AppState = Depends(get_state)):
    _check(state, case_id)
    return state.reports.list(case_id)


@router.get("/{report_id}")
def get_report(case_id: str, report_id: str, state: AppState = Depends(get_state)):
    _check(state, case_id)
    try:
        return {"meta": state.reports.get(case_id, report_id), "data": state.reports.load_json(case_id, report_id)}
    except LookupError:
        raise HTTPException(404, "Report not found")


class ReviewRequest(BaseModel):
    action: str
    reviewer: str = Field(min_length=1, max_length=120)
    note: str = Field(default="", max_length=2000)
    acknowledge_verification_failures: bool = False


@router.post("/{report_id}/review")
def review(case_id: str, report_id: str, payload: ReviewRequest, state: AppState = Depends(get_state)):
    _check(state, case_id)
    try:
        return state.reports.review(case_id, report_id, payload.action, payload.reviewer, payload.note, payload.acknowledge_verification_failures)
    except LookupError:
        raise HTTPException(404, "Report not found")
    except PermissionError as exc:
        raise HTTPException(409, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))


@router.get("/{report_id}/pdf")
def pdf(case_id: str, report_id: str, state: AppState = Depends(get_state)):
    _check(state, case_id)
    try:
        meta = state.reports.get(case_id, report_id)
    except LookupError:
        raise HTTPException(404, "Report not found")
    fname = f"Little-Guy-Legal-Case-Research-Report-v{meta['version']}-{meta['status']}.pdf"
    return FileResponse(meta["pdf_path"], media_type="application/pdf", filename=fname)


@router.get("/{report_id}/json")
def json_download(case_id: str, report_id: str, state: AppState = Depends(get_state)):
    _check(state, case_id)
    try:
        meta = state.reports.get(case_id, report_id)
    except LookupError:
        raise HTTPException(404, "Report not found")
    return FileResponse(meta["json_path"], media_type="application/json", filename=f"report-v{meta['version']}.json")
