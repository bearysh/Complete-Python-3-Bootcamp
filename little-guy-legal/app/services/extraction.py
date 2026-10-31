"""Local text extraction for PDF and DOCX files.

Everything runs in-process on the local machine. Extraction yields *segments*
with stable locators: PDF pages (``D{n}:p{page}``) and DOCX paragraphs
(``D{n}:para{index}``). Page numbers are never invented for DOCX files.
"""
from __future__ import annotations

import re
import shutil
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import fitz  # PyMuPDF

HEADING_RE = re.compile(
    r"^\s*(?:(ARTICLE|Article|SECTION|Section|Sec\.)\s+[\dIVXLC]+[\.\d]*\s*[:\.\-–—]?\s*[A-Z][^\n]{0,80}"
    r"|\d{1,2}(?:\.\d{1,2}){0,2}\s+[A-Z][A-Za-z ,'&/\-]{2,80})\s*$"
)
MIN_TEXT_CHARS_PER_PAGE = 25


@dataclass
class Segment:
    locator_type: str  # "page" | "paragraph"
    page_number: int | None
    paragraph_index: int | None
    section_label: str | None
    text: str

    def ref(self, doc_ordinal: int) -> str:
        if self.locator_type == "page":
            return f"D{doc_ordinal}:p{self.page_number}"
        return f"D{doc_ordinal}:para{self.paragraph_index}"


@dataclass
class ExtractionResult:
    segments: list[Segment]
    page_count: int | None
    unreadable_pages: list[int] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    ocr_used: bool = False

    @property
    def full_text(self) -> str:
        return "\n\n".join(s.text for s in self.segments)


class UnsupportedFileError(ValueError):
    pass


def sniff_mime(path: Path) -> str:
    """Determine the type from file content, not just the extension."""
    with open(path, "rb") as fh:
        head = fh.read(8)
    if head.startswith(b"%PDF"):
        return "application/pdf"
    if head.startswith(b"PK\x03\x04"):
        try:
            with zipfile.ZipFile(path) as zf:
                names = set(zf.namelist())
            if "[Content_Types].xml" in names and "word/document.xml" in names:
                return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        except zipfile.BadZipFile:
            pass
    raise UnsupportedFileError("Only PDF and DOCX files are supported; file content did not match either format.")


def _find_headings(text: str) -> list[str]:
    found = []
    for line in text.splitlines():
        line = line.strip()
        if 3 < len(line) < 100 and HEADING_RE.match(line):
            found.append(re.sub(r"\s+", " ", line))
    return found[:6]


def _tesseract_available() -> bool:
    return shutil.which("tesseract") is not None


def extract_pdf(path: Path, ocr: bool = True) -> ExtractionResult:
    segments: list[Segment] = []
    unreadable: list[int] = []
    warnings: list[str] = []
    ocr_used = False
    last_heading: str | None = None
    with fitz.open(path) as doc:
        if doc.is_encrypted:
            raise UnsupportedFileError("Encrypted PDFs are not supported.")
        page_count = doc.page_count
        for i, page in enumerate(doc, start=1):
            text = page.get_text("text") or ""
            text = text.replace("\x00", "").strip()
            has_images = bool(page.get_images(full=False))
            if len(text) < MIN_TEXT_CHARS_PER_PAGE and has_images:
                if ocr and _tesseract_available():
                    try:
                        tp = page.get_textpage_ocr(full=True)
                        text = (page.get_text("text", textpage=tp) or "").strip()
                        ocr_used = True
                    except Exception as exc:  # pragma: no cover - depends on local tesseract
                        warnings.append(f"OCR failed on page {i}: {type(exc).__name__}")
                if len(text) < MIN_TEXT_CHARS_PER_PAGE:
                    unreadable.append(i)
                    segments.append(
                        Segment("page", i, None, last_heading, "[UNREADABLE PAGE: no selectable text; OCR unavailable]")
                    )
                    continue
            headings = _find_headings(text)
            if headings:
                last_heading = headings[-1]
            label = "; ".join(headings) if headings else last_heading
            segments.append(Segment("page", i, None, label, text))
    if unreadable:
        warnings.append(
            f"{len(unreadable)} page(s) had no selectable text and could not be OCR'd locally: {unreadable}"
        )
    return ExtractionResult(segments, page_count, unreadable, warnings, ocr_used)


def extract_docx(path: Path) -> ExtractionResult:
    import docx  # python-docx

    document = docx.Document(str(path))
    segments: list[Segment] = []
    idx = 0
    last_heading: str | None = None
    for para in document.paragraphs:
        text = (para.text or "").replace("\x00", "").strip()
        if not text:
            continue
        idx += 1
        style = (para.style.name if para.style is not None else "") or ""
        is_heading = style.lower().startswith("heading") or style.lower() == "title" or bool(HEADING_RE.match(text))
        if is_heading:
            last_heading = re.sub(r"\s+", " ", text)[:120]
        segments.append(Segment("paragraph", None, idx, last_heading, text))
    for t_i, table in enumerate(document.tables, start=1):
        for r_i, row in enumerate(table.rows, start=1):
            cells = [c.text.strip() for c in row.cells]
            line = " | ".join(c for c in cells if c)
            if not line:
                continue
            idx += 1
            segments.append(Segment("paragraph", None, idx, f"Table {t_i}, row {r_i}", line))
    warnings = []
    if not segments:
        warnings.append("DOCX contained no extractable text.")
    return ExtractionResult(segments, page_count=None, warnings=warnings)


def extract(path: Path, mime: str) -> ExtractionResult:
    if mime == "application/pdf":
        return extract_pdf(path)
    if mime.endswith("wordprocessingml.document"):
        return extract_docx(path)
    raise UnsupportedFileError(f"Unsupported mime type {mime}")


def guess_doc_kind(filename: str, text: str) -> str:
    name = filename.lower()
    sample = text[:4000].lower()
    if "notice" in name or "notice of default" in sample or "notice to vacate" in sample or "re: notice" in sample:
        return "notice"
    if "email" in name or "from:" in sample or "subject:" in sample or "correspondence" in name:
        return "communication"
    if "amend" in name or sample.lstrip().startswith("amendment") or "first amendment to lease" in sample:
        return "amendment"
    if "invoice" in name or sample.lstrip().startswith("invoice"):
        return "invoice"
    if "lease" in name or "lease agreement" in sample[:1500]:
        return "lease"
    if "letter" in name:
        return "communication"
    return "other"
