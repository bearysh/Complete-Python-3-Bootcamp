from __future__ import annotations

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel

from ..models.case import CaseCreate, CaseOut, DocumentOut, IntakeData, SegmentOut
from ..services.cases import CaseNotFound
from ..services.documents import DocumentNotFound
from ..services.extraction import UnsupportedFileError
from ..services.intake import suggest_intake
from ..state import AppState
from .deps import get_state

router = APIRouter(prefix="/api/cases", tags=["cases"])


def _case_or_404(state: AppState, case_id: str) -> CaseOut:
    try:
        return state.cases.get(case_id)
    except CaseNotFound:
        raise HTTPException(404, "Case not found")


@router.post("", response_model=CaseOut, status_code=201)
def create_case(payload: CaseCreate, state: AppState = Depends(get_state)):
    return state.cases.create(payload)


@router.get("", response_model=list[CaseOut])
def list_cases(state: AppState = Depends(get_state)):
    return state.cases.list()


@router.get("/{case_id}", response_model=CaseOut)
def get_case(case_id: str, state: AppState = Depends(get_state)):
    return _case_or_404(state, case_id)


@router.delete("/{case_id}", status_code=204)
def delete_case(case_id: str, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    if state.pipeline.is_running(case_id):
        raise HTTPException(409, "Cancel the running analysis before deleting the case")
    state.cases.delete(case_id)


@router.get("/{case_id}/audit")
def audit(case_id: str, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    return state.cases.audit_trail(case_id)


# ---- documents ---------------------------------------------------------
@router.post("/{case_id}/documents", response_model=DocumentOut, status_code=201)
async def upload_document(case_id: str, file: UploadFile = File(...), state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    content = await file.read()
    try:
        return state.documents.store_and_extract(case_id, file.filename or "document", content)
    except UnsupportedFileError as exc:
        raise HTTPException(415, str(exc))


@router.get("/{case_id}/documents", response_model=list[DocumentOut])
def list_documents(case_id: str, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    return state.documents.list(case_id)


class KindUpdate(BaseModel):
    doc_kind: str


@router.patch("/{case_id}/documents/{doc_id}", response_model=DocumentOut)
def update_document(case_id: str, doc_id: str, payload: KindUpdate, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    try:
        return state.documents.set_kind(case_id, doc_id, payload.doc_kind[:40])
    except DocumentNotFound:
        raise HTTPException(404, "Document not found")


@router.delete("/{case_id}/documents/{doc_id}", status_code=204)
def delete_document(case_id: str, doc_id: str, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    try:
        state.documents.delete(case_id, doc_id)
    except DocumentNotFound:
        raise HTTPException(404, "Document not found")


@router.get("/{case_id}/documents/{doc_id}/segments", response_model=list[SegmentOut])
def document_segments(case_id: str, doc_id: str, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    try:
        return state.documents.segments(case_id, doc_id)
    except DocumentNotFound:
        raise HTTPException(404, "Document not found")


@router.get("/{case_id}/documents/{doc_id}/original")
def document_original(case_id: str, doc_id: str, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    try:
        doc = state.documents.get(case_id, doc_id)
        path = state.documents.original_path(case_id, doc_id)
    except DocumentNotFound:
        raise HTTPException(404, "Document not found")
    return FileResponse(path, media_type=doc.mime, filename=doc.filename)


@router.get("/{case_id}/segments/{ref}", response_model=SegmentOut)
def resolve_segment(case_id: str, ref: str, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    seg = state.documents.resolve_ref(case_id, ref)
    if seg is None:
        raise HTTPException(404, "Reference not found in this case")
    return seg


@router.get("/{case_id}/search")
def search_documents(case_id: str, q: str, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    return state.documents.search(case_id, q)


# ---- intake ------------------------------------------------------------
@router.get("/{case_id}/intake", response_model=IntakeData | None)
def get_intake(case_id: str, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    return state.cases.get_intake(case_id)


@router.put("/{case_id}/intake", response_model=IntakeData)
def put_intake(case_id: str, payload: IntakeData, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    return state.cases.save_intake(case_id, payload)


@router.get("/{case_id}/intake/suggestions")
def intake_suggestions(case_id: str, state: AppState = Depends(get_state)):
    _case_or_404(state, case_id)
    return suggest_intake(state.documents, case_id)
