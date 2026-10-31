from pathlib import Path

import pytest

from app.services.extraction import UnsupportedFileError, extract, guess_doc_kind, sniff_mime
from tests.conftest import FIXTURES


def test_pdf_extraction_preserves_pages_and_sections():
    r = extract(FIXTURES / "01_commercial_lease.pdf", "application/pdf")
    assert r.page_count == 6 and len(r.segments) == 6
    assert r.segments[3].ref(1) == "D1:p4"
    assert "ARTICLE 15" in (r.segments[3].section_label or "")
    assert "change the door locks of the Premises in accordance with Section 93.002" in r.full_text.replace("\n", " ")
    assert r.unreadable_pages == []


def test_docx_extraction_uses_paragraph_locators_not_pages():
    r = extract(FIXTURES / "02_notice_of_default.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    assert r.page_count is None
    assert all(s.locator_type == "paragraph" for s in r.segments)
    assert r.segments[0].ref(2) == "D2:para1"
    assert any("$7,717.50" in s.text for s in r.segments)


def test_sniff_rejects_disguised_files(tmp_path):
    bad = tmp_path / "evil.pdf"
    bad.write_bytes(b"#!/bin/sh\necho pwned\n")
    with pytest.raises(UnsupportedFileError):
        sniff_mime(bad)


def test_doc_kind_heuristics():
    assert guess_doc_kind("02_notice_of_default.docx", "Re: NOTICE OF DEFAULT") == "notice"
    assert guess_doc_kind("lease.pdf", "This Retail Lease Agreement") == "lease"
    assert guess_doc_kind("x.docx", "From: a@b\nSubject: hi") == "communication"
