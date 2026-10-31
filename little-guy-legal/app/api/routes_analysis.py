from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from ..models.stages import ArgumentStyle
from ..services.cases import CaseNotFound
from ..services.pipeline import PipelineError
from ..state import AppState
from .deps import get_state

router = APIRouter(prefix="/api/cases/{case_id}/analysis", tags=["analysis"])


def _check(state: AppState, case_id: str) -> None:
    try:
        state.cases.get(case_id)
    except CaseNotFound:
        raise HTTPException(404, "Case not found")


class StartRequest(BaseModel):
    argument_style: ArgumentStyle = "by_the_book"


@router.post("", status_code=202)
def start_analysis(case_id: str, payload: StartRequest, state: AppState = Depends(get_state)):
    _check(state, case_id)
    try:
        return state.pipeline.start(case_id, payload.argument_style)
    except PipelineError as exc:
        raise HTTPException(409, str(exc))


@router.get("")
def latest(case_id: str, state: AppState = Depends(get_state)):
    _check(state, case_id)
    run = state.pipeline.latest_run(case_id)
    return run or {"status": "none", "stages": []}


@router.get("/runs")
def runs(case_id: str, state: AppState = Depends(get_state)):
    _check(state, case_id)
    return state.pipeline.list_runs(case_id)


@router.get("/runs/{run_id}")
def get_run(case_id: str, run_id: str, state: AppState = Depends(get_state)):
    _check(state, case_id)
    try:
        return state.pipeline.get_run(case_id, run_id)
    except PipelineError as exc:
        raise HTTPException(404, str(exc))


@router.post("/runs/{run_id}/cancel")
def cancel(case_id: str, run_id: str, state: AppState = Depends(get_state)):
    _check(state, case_id)
    try:
        return state.pipeline.cancel(case_id, run_id)
    except PipelineError as exc:
        raise HTTPException(404, str(exc))


@router.post("/runs/{run_id}/resume", status_code=202)
def resume(case_id: str, run_id: str, state: AppState = Depends(get_state)):
    _check(state, case_id)
    try:
        return state.pipeline.resume(case_id, run_id)
    except PipelineError as exc:
        raise HTTPException(409, str(exc))


@router.get("/runs/{run_id}/results")
def results(case_id: str, run_id: str, state: AppState = Depends(get_state)):
    _check(state, case_id)
    try:
        state.pipeline.get_run(case_id, run_id)
    except PipelineError as exc:
        raise HTTPException(404, str(exc))
    return state.pipeline.stage_outputs(case_id, run_id)
