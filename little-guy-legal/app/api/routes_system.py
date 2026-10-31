from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from ..state import AppState
from .deps import get_state

router = APIRouter(prefix="/api", tags=["system"])


@router.get("/health")
def health(state: AppState = Depends(get_state)):
    status = state.pipeline.provider_status()
    return {
        "status": "ok",
        "data_dir": str(state.settings.data_dir),
        "provider": status,
        "warnings": state.warnings,
        "authority_library_size": len(state.authorities.list()),
    }


@router.get("/health/inference")
def inference_health(state: AppState = Depends(get_state)):
    return state.pipeline.provider_health()


@router.get("/authorities")
def authorities(q: str | None = None, state: AppState = Depends(get_state)):
    if q:
        return state.authorities.search(q, limit=20)
    return state.authorities.list()


@router.get("/authorities/{authority_id}")
def authority(authority_id: str, state: AppState = Depends(get_state)):
    auth = state.authorities.get(authority_id)
    if auth is None:
        raise HTTPException(404, "Authority not in local library")
    return auth
