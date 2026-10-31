// Screen 3: case intake — documents, short questionnaire, suggestions, start analysis.
import { h, append, clear, replaceChildren, chip, statusChip, fmtBytes, fmtDateTime, plural, spinnerBlock, emptyState } from '../dom.js';
import { api, guarded, caseUrl, enc_ } from '../api.js';
import { navigate } from '../router.js';
import { openDrawer, toast, alertBox, field } from '../ui.js';
import { caseShell } from './shell.js';
import { evidenceChip, setEvidenceCase } from '../evidence.js';

const DOC_KINDS = ['lease', 'amendment', 'notice', 'communication', 'invoice', 'other'];
const ROLES = [['landlord', 'Landlord'], ['tenant', 'Tenant'], ['guarantor', 'Guarantor'], ['other', 'Other']];
const MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];

/** "March 1, 2024" / "3/1/2024" -> "2024-03-01"; anything else is returned unchanged. */
function toIsoDate(s) {
  const pad = (n) => String(n).padStart(2, '0');
  let m = /^(\w+)\s+(\d{1,2}),\s+(\d{4})$/.exec(s);
  if (m && MONTHS.includes(m[1].toLowerCase())) return `${m[3]}-${pad(MONTHS.indexOf(m[1].toLowerCase()) + 1)}-${pad(m[2])}`;
  m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s);
  if (m) return `${m[3]}-${pad(m[1])}-${pad(m[2])}`;
  return s;
}

export async function intakeView(root, { id }, isCurrent) {
  const shell = await caseShell(root, id, 'intake');
  if (!shell) return;
  setEvidenceCase(id);
  let c = shell.case;
  const body = shell.body;
  let pollTimer = null;
  let docs = [];
  let dirty = false;

  // Section containers ---------------------------------------------------------
  const docsSection = h('section', { class: 'card', 'aria-labelledby': 'docs-h' });
  const intakeSection = h('section', { class: 'card', 'aria-labelledby': 'intake-h' });
  const suggestSection = h('section', { class: 'card', 'aria-labelledby': 'sugg-h' });
  const startSection = h('section', { class: 'card', 'aria-labelledby': 'start-h' });
  const left = h('div', { class: 'col' }, docsSection, intakeSection);
  const right = h('div', { class: 'col' }, suggestSection, startSection);
  append(body, [h('div', { class: 'two-col' }, left, right)]);

  // ============================ Documents ======================================
  const uploads = []; // in-flight / failed upload rows: {name, state:'uploading'|'error', message}
  const fileInput = h('input', { type: 'file', accept: '.pdf,.docx', multiple: true, class: 'sr-only', id: 'file-input', tabindex: '-1',
    onchange: () => { uploadFiles([...fileInput.files]); fileInput.value = ''; } });
  const dropzone = h('div', { class: 'dropzone', role: 'button', tabindex: '0', 'aria-label': 'Add documents: drop PDF or Word files here, or press Enter to browse',
    onclick: () => fileInput.click(),
    onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fileInput.click(); } },
    ondragover: (e) => { e.preventDefault(); dropzone.classList.add('is-over'); },
    ondragleave: () => dropzone.classList.remove('is-over'),
    ondrop: (e) => { e.preventDefault(); dropzone.classList.remove('is-over'); uploadFiles([...e.dataTransfer.files]); } },
    h('p', { class: 'dz-title' }, 'Drop documents here, or click to choose'),
    h('p', { class: 'muted small' }, 'PDF or Word (.docx), up to 50 MB each. Lease, amendments, notices, emails, invoices.'));
  const docList = h('div', { class: 'doc-list' });
  const uploadList = h('div', { class: 'doc-list' });
  append(docsSection, [h('h2', { id: 'docs-h' }, 'Documents'), dropzone, fileInput, uploadList, docList]);

  async function uploadFiles(files) {
    for (const f of files) {
      const row = { name: f.name, state: 'uploading', message: '' };
      if (!/\.(pdf|docx)$/i.test(f.name)) {
        row.state = 'error'; row.message = 'Unsupported file type. Only .pdf and .docx files can be analyzed.';
        uploads.push(row); renderUploads();
        continue;
      }
      uploads.push(row); renderUploads();
      try {
        const fd = new FormData();
        fd.append('file', f);
        await api.upload(caseUrl(id, '/documents'), fd);
        uploads.splice(uploads.indexOf(row), 1);
      } catch (err) {
        row.state = 'error'; row.message = err.message;
      }
      renderUploads();
      await loadDocs();
      loadSuggestions();
    }
  }

  function renderUploads() {
    replaceChildren(uploadList, uploads.map((u) => h('div', { class: `doc-row ${u.state === 'error' ? 'doc-error' : ''}` },
      h('div', { class: 'doc-main' },
        h('strong', null, u.name),
        u.state === 'uploading' ? h('span', { class: 'muted small', role: 'status' }, ' Uploading and extracting text…') : h('p', { class: 'text-bad small' }, u.message)),
      u.state === 'error' ? h('button', { class: 'btn btn-quiet btn-sm', type: 'button', onclick: () => { uploads.splice(uploads.indexOf(u), 1); renderUploads(); } }, 'Dismiss') : null)));
  }

  function docRow(d) {
    const kinds = DOC_KINDS.includes(d.doc_kind) ? DOC_KINDS : [...DOC_KINDS, d.doc_kind];
    const select = h('select', { 'aria-label': `Document type for ${d.filename}`, onchange: async () => {
      const prev = d.doc_kind;
      const r = await guarded(() => api.patch(caseUrl(id, `/documents/${enc_(d.id)}`), { doc_kind: select.value }));
      if (r) { d.doc_kind = select.value; loadSuggestions(); } else select.value = prev;
    } }, kinds.map((k) => h('option', { value: k, selected: k === d.doc_kind }, k === 'unknown' ? 'Unclassified' : k[0].toUpperCase() + k.slice(1))));
    const meta = [];
    if (d.page_count) meta.push(plural(d.page_count, 'page'));
    if (d.segment_count !== null && d.segment_count !== undefined) meta.push(plural(d.segment_count, 'text segment'));
    meta.push(fmtBytes(d.size_bytes));
    return h('div', { class: 'doc-row' },
      h('div', { class: 'doc-main' },
        h('div', { class: 'doc-title' }, h('span', { class: 'chip chip-ref static', title: 'Reference prefix used in citations' }, d.ref_prefix), h('strong', null, d.filename)),
        h('div', { class: 'doc-meta' }, statusChip(d.extraction_status), h('span', { class: 'muted small' }, meta.filter(Boolean).join(' · '))),
        d.unreadable_pages && d.unreadable_pages.length
          ? alertBox(`${plural(d.unreadable_pages.length, 'page')} had no readable text (${d.unreadable_pages.join(', ')}). Scanned pages are not read by this version; their content is not part of the analysis.`, 'warn') : null,
        d.extraction_error ? alertBox(`Extraction failed: ${d.extraction_error}`, 'error') : null),
      h('div', { class: 'doc-actions' },
        h('label', { class: 'inline-label' }, h('span', { class: 'sr-only' }, 'Document type'), select),
        h('button', { class: 'btn btn-sm', type: 'button', disabled: d.extraction_status !== 'extracted', onclick: () => viewText(d) }, 'View text'),
        h('button', { class: 'btn btn-sm btn-danger-quiet', type: 'button', 'aria-label': `Delete ${d.filename}`, onclick: async () => {
          if (!confirm(`Delete "${d.filename}"? Its extracted text will be removed from this case.`)) return;
          const ok = await guarded(async () => { await api.del(caseUrl(id, `/documents/${enc_(d.id)}`)); return true; });
          if (ok) { await loadDocs(); loadSuggestions(); }
        } }, 'Delete')));
  }

  function viewText(d) {
    const body = api.get(caseUrl(id, `/documents/${enc_(d.id)}/segments`)).then((segs) => {
      if (!segs.length) return emptyState('No text segments', 'Nothing was extracted from this document.');
      const list = h('div', { class: 'seg-list' });
      const render = (q) => {
        const needle = q.trim().toLowerCase();
        const shown = needle ? segs.filter((s) => s.text.toLowerCase().includes(needle) || (s.section_label || '').toLowerCase().includes(needle)) : segs;
        replaceChildren(list, shown.length ? shown.map((s) => h('article', { class: 'seg' },
          h('header', null, h('span', { class: 'chip chip-ref static' }, `[${s.ref}]`), s.section_label ? h('span', { class: 'seg-section' }, s.section_label) : null),
          h('p', { class: 'seg-text' }, s.text))) : h('p', { class: 'muted' }, 'No segments match.'));
      };
      const search = h('input', { type: 'search', placeholder: 'Filter this document’s text', 'aria-label': 'Filter segments', oninput: () => render(search.value) });
      render('');
      return h('div', null, h('div', { class: 'drawer-tools' }, search, h('span', { class: 'muted small' }, plural(segs.length, 'segment'))), list);
    });
    openDrawer({ title: d.filename, subtitle: `${d.ref_prefix} · extracted text`, body, wide: true });
  }

  async function loadDocs() {
    try { docs = await api.get(caseUrl(id, '/documents')); }
    catch (err) { replaceChildren(docList, alertBox(err.message)); return; }
    if (!isCurrent()) return;
    replaceChildren(docList, docs.length ? docs.map(docRow) : (uploads.length ? null : h('p', { class: 'muted center small' }, 'No documents yet.')));
    renderStart();
    // Extraction may still be running; keep refreshing until nothing is pending.
    clearTimeout(pollTimer);
    if (docs.some((d) => d.extraction_status === 'pending')) pollTimer = setTimeout(() => loadDocs().then(loadSuggestions), 2000);
  }

  // ============================ Intake form ====================================
  const state = { user_role: 'unknown', narrative: '', desired_outcome: '', key_dates: [], prior_notices: [], confirmed_inferences: {} };
  const saveStatus = h('span', { class: 'muted small', role: 'status' });
  const datesHost = h('div', { class: 'rows' });
  const noticesHost = h('div', { class: 'rows' });

  const roleGroup = h('div', { class: 'radio-row', role: 'radiogroup', 'aria-labelledby': 'role-label' },
    ROLES.map(([v, l]) => h('label', { class: 'radio' },
      h('input', { type: 'radio', name: 'user_role', value: v, onchange: () => { state.user_role = v; touch(); } }), h('span', null, l))));
  const narrative = h('textarea', { rows: '6', maxlength: '20000', placeholder: 'Describe the dispute in your own words — who did what, and when.', oninput: () => { state.narrative = narrative.value; touch(); } });
  const outcome = h('textarea', { rows: '3', maxlength: '5000', placeholder: 'e.g. Recover the security deposit; avoid eviction; terminate the lease without penalty.', oninput: () => { state.desired_outcome = outcome.value; touch(); } });

  function touch() { dirty = true; saveStatus.textContent = 'Unsaved changes'; renderGap(); renderStart(); }

  // The "gaps" warning lives next to the Start button (renderStart); nothing to do here.
  function renderGap() {}

  function rowInput(value, placeholder, label, onInput, type = 'text') {
    const i = h('input', { type, value: value || '', placeholder, 'aria-label': label, oninput: () => onInput(i.value) });
    return i;
  }

  function renderDates() {
    replaceChildren(datesHost, state.key_dates.length ? state.key_dates.map((d, i) => h('div', { class: 'row-3' },
      rowInput(d.label, 'What the date is (e.g. rent due, notice received)', `Date label ${i + 1}`, (v) => { d.label = v; touch(); }),
      rowInput(d.date, 'YYYY-MM-DD or describe', `Date ${i + 1}`, (v) => { d.date = v; touch(); }),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: !!d.confirmed, onchange: (e) => { d.confirmed = e.target.checked; touch(); } }), h('span', null, 'Confirmed')),
      h('button', { class: 'btn btn-quiet btn-sm', type: 'button', 'aria-label': `Remove date ${i + 1}`, onclick: () => { state.key_dates.splice(i, 1); renderDates(); touch(); } }, 'Remove')))
      : h('p', { class: 'muted small' }, 'No dates added.'));
  }
  function renderNotices() {
    replaceChildren(noticesHost, state.prior_notices.length ? state.prior_notices.map((n, i) => h('div', { class: 'row-3 notice-row' },
      rowInput(n.kind, 'Kind (e.g. notice of default)', `Notice kind ${i + 1}`, (v) => { n.kind = v; touch(); }),
      rowInput(n.date, 'YYYY-MM-DD', `Notice date ${i + 1}`, (v) => { n.date = v; touch(); }),
      rowInput(n.description, 'Short description', `Notice description ${i + 1}`, (v) => { n.description = v; touch(); }),
      h('button', { class: 'btn btn-quiet btn-sm', type: 'button', 'aria-label': `Remove notice ${i + 1}`, onclick: () => { state.prior_notices.splice(i, 1); renderNotices(); touch(); } }, 'Remove')))
      : h('p', { class: 'muted small' }, 'None recorded.'));
  }

  function applyStateToForm() {
    for (const r of roleGroup.querySelectorAll('input')) r.checked = r.value === state.user_role;
    narrative.value = state.narrative; outcome.value = state.desired_outcome;
    renderDates(); renderNotices(); renderGap();
  }

  async function saveIntake({ quiet = false } = {}) {
    const payload = { ...state, key_dates: state.key_dates.filter((d) => d.label.trim() || d.date.trim()), prior_notices: state.prior_notices.filter((n) => n.kind.trim() || n.description.trim()) };
    const saved = await guarded(() => api.put(caseUrl(id, '/intake'), payload));
    if (!saved) return false;
    dirty = false;
    saveStatus.textContent = `Saved ${fmtDateTime(new Date().toISOString())}`;
    if (!quiet) toast('Intake saved', 'success');
    return true;
  }

  const saveBtn = h('button', { class: 'btn btn-primary', type: 'button', onclick: () => saveIntake() }, 'Save intake');
  append(intakeSection, [
    h('h2', { id: 'intake-h' }, 'Intake'),
    h('p', { class: 'muted' }, 'Four short questions. Anything you leave blank is recorded as an uncertainty, not guessed.'),
    h('fieldset', { class: 'field' }, h('legend', { id: 'role-label' }, 'Your role'), roleGroup),
    field('What happened?', narrative),
    field('What outcome are you seeking?', outcome),
    h('div', { class: 'field' },
      h('div', { class: 'field-head' }, h('span', { class: 'label' }, 'Important dates or deadlines'),
        h('button', { class: 'btn btn-sm', type: 'button', onclick: () => { state.key_dates.push({ label: '', date: '', confirmed: false }); renderDates(); touch(); } }, 'Add date')),
      datesHost),
    h('div', { class: 'field' },
      h('div', { class: 'field-head' }, h('span', { class: 'label' }, 'Have notices, demands, or legal filings already occurred?'),
        h('button', { class: 'btn btn-sm', type: 'button', onclick: () => { state.prior_notices.push({ kind: '', date: '', description: '' }); renderNotices(); touch(); } }, 'Add notice')),
      noticesHost),
    h('div', { class: 'actions' }, saveBtn, saveStatus)]);

  async function loadIntake() {
    try {
      const data = await api.get(caseUrl(id, '/intake'));
      if (data) Object.assign(state, { user_role: data.user_role || 'unknown', narrative: data.narrative || '', desired_outcome: data.desired_outcome || '',
        key_dates: data.key_dates || [], prior_notices: data.prior_notices || [], confirmed_inferences: data.confirmed_inferences || {} });
    } catch (err) { toast(err.message, 'error'); }
    applyStateToForm();
    renderStart();
  }

  // ============================ Suggestions ====================================
  const addedDates = new Set();
  async function loadSuggestions() {
    let s;
    try { s = await api.get(caseUrl(id, '/intake/suggestions')); }
    catch (err) { replaceChildren(suggestSection, h('h2', { id: 'sugg-h' }, 'Suggestions from your documents'), alertBox(err.message)); return; }
    if (!isCurrent()) return;
    const parties = Object.entries(s.parties || {});
    const dates = s.dates || [];
    const notices = s.notice_indicators || [];
    const amounts = s.amounts || [];
    replaceChildren(suggestSection,
      h('div', { class: 'card-head' }, h('h2', { id: 'sugg-h' }, 'Suggestions from your documents'), chip('Pattern-matched, not AI', 'muted')),
      h('p', { class: 'muted small' }, s.note || 'Suggestions are extracted by pattern matching, not AI. Confirm anything that matters before analysis.'),
      !parties.length && !dates.length && !notices.length
        ? emptyState('Nothing detected yet', 'Upload extracted documents to see detected parties, dates and notice language.') : null,
      parties.length ? h('div', { class: 'sugg-block' }, h('h3', null, 'Detected parties'),
        h('ul', { class: 'plain' }, parties.map(([role, p]) => h('li', null, h('span', { class: 'chip chip-neutral' }, role), ' ', h('strong', null, p.name), ' ', evidenceChip(p.ref))))) : null,
      dates.length ? h('div', { class: 'sugg-block' }, h('h3', null, `Detected dates (${dates.length})`),
        h('ul', { class: 'plain sugg-dates' }, dates.map((d) => {
          const iso = toIsoDate(d.date);
          const key = `${iso}|${d.ref}`;
          const btn = h('button', { class: 'btn btn-sm', type: 'button', disabled: addedDates.has(key), 'aria-label': `Add ${d.date} to key dates`, onclick: () => {
            state.key_dates.push({ label: (d.context || '').trim().slice(0, 120), date: iso, confirmed: false });
            addedDates.add(key); btn.disabled = true; btn.textContent = 'Added';
            renderDates(); touch();
          } }, addedDates.has(key) ? 'Added' : 'Add');
          return h('li', null, h('div', { class: 'sugg-line' }, h('strong', null, d.date), evidenceChip(d.ref), btn),
            h('p', { class: 'muted small ctx' }, `…${(d.context || '').trim()}…`), h('p', { class: 'muted small' }, d.document));
        }))) : null,
      notices.length ? h('div', { class: 'sugg-block' }, h('h3', null, 'Notice indicators'),
        h('p', { class: 'muted small' }, 'Phrases suggesting a notice, demand or filing may have occurred. Record any that are real in the notices section.'),
        h('ul', { class: 'plain' }, notices.map((n) => h('li', null, h('strong', null, `“${n.indicator}”`), ' in ', n.document, ' ', evidenceChip(n.ref))))) : null,
      amounts.length ? h('details', { class: 'sugg-block' }, h('summary', null, `Dollar amounts in the lease (${amounts.length})`),
        h('ul', { class: 'plain' }, amounts.map((a) => h('li', null, h('strong', null, a.amount), ' ', evidenceChip(a.ref), h('p', { class: 'muted small ctx' }, `…${(a.context || '').trim()}…`))))) : null);
  }

  // ============================ Start analysis =================================
  let style = 'by_the_book';
  const startErr = h('div');
  function renderStart() {
    const extracted = docs.filter((d) => d.extraction_status === 'extracted');
    const pending = docs.some((d) => d.extraction_status === 'pending');
    const running = ['queued', 'running'].includes(c.latest_run_status);
    let blocker = null;
    if (running) blocker = 'An analysis is already running for this case.';
    else if (!docs.length) blocker = 'Upload at least one document to start.';
    else if (pending) blocker = 'Waiting for text extraction to finish.';
    else if (!extracted.length) blocker = 'No document has extracted text. Remove failed uploads and add a readable PDF or Word file.';
    const btn = h('button', { class: 'btn btn-primary btn-lg', type: 'button', disabled: !!blocker, 'aria-describedby': 'start-note', onclick: start }, 'Start analysis');
    async function start() {
      btn.disabled = true; clear(startErr);
      if (dirty && !(await saveIntake({ quiet: true }))) { btn.disabled = false; return; }
      try {
        await api.post(caseUrl(id, '/analysis'), { argument_style: style });
        navigate(`/cases/${enc_(id)}/progress`);
      } catch (err) {
        replaceChildren(startErr, alertBox(err.message));
        btn.disabled = false;
      }
    }
    const styleOpts = [['by_the_book', 'By the Book', 'Arguments stay close to the documents and the authorities in the local library.'],
      ['aggressive', 'Aggressive', 'Advocates press harder on interpretation; weaker arguments are flagged by the skeptical review.']];
    replaceChildren(startSection,
      h('h2', { id: 'start-h' }, 'Start analysis'),
      h('fieldset', { class: 'field' }, h('legend', null, 'Argument style'),
        styleOpts.map(([v, l, d]) => h('label', { class: 'radio block' }, h('input', { type: 'radio', name: 'style', value: v, checked: style === v, onchange: () => { style = v; } }),
          h('span', null, h('strong', null, l), h('span', { class: 'muted small block-text' }, d)))),
        h('label', { class: 'radio block disabled' }, h('input', { type: 'radio', name: 'style', disabled: true }), h('span', null, h('strong', null, 'Maximum Challenge'), ' ', chip('coming later', 'muted')))),
      state.user_role === 'unknown' || !state.narrative.trim() || !state.desired_outcome.trim()
        ? alertBox(`Intake is incomplete (${[state.user_role === 'unknown' && 'role', !state.narrative.trim() && 'what happened', !state.desired_outcome.trim() && 'desired outcome'].filter(Boolean).join(', ')}). Analysis can proceed but the gaps will be recorded as uncertainties.`, 'warn') : null,
      h('p', { id: 'start-note', class: blocker ? 'text-bad small' : 'muted small' }, blocker || 'Runs eight stages on this computer. It can take several minutes; you can leave this page.'),
      startErr,
      h('div', { class: 'actions' }, btn,
        c.latest_run_id ? h('a', { class: 'btn btn-quiet', href: `/cases/${enc_(id)}/progress` }, running ? 'View progress' : 'View previous run') : null));
  }

  // ---- initial load ---------------------------------------------------------
  replaceChildren(docList, spinnerBlock('Loading documents…'));
  replaceChildren(suggestSection, h('h2', { id: 'sugg-h' }, 'Suggestions from your documents'), spinnerBlock());
  await Promise.all([loadDocs(), loadIntake()]);
  await loadSuggestions();

  const beforeUnload = (e) => { if (dirty) { e.preventDefault(); e.returnValue = ''; } };
  window.addEventListener('beforeunload', beforeUnload);
  return () => {
    clearTimeout(pollTimer);
    window.removeEventListener('beforeunload', beforeUnload);
    if (dirty) saveIntake({ quiet: true }); // don't lose edits when navigating away in-app
  };
}
