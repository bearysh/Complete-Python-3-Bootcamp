// Evidence inspection: clickable [D1:p4] / [A:tx-prop-93.002] chips and the drawer
// that resolves them to the original passage with the quoted text highlighted.
import { h, append, fmtDateTime } from './dom.js';
import { api, caseUrl, enc_ } from './api.js';
import { openDrawer } from './ui.js';

let currentCaseId = null;
export function setEvidenceCase(id) { currentCaseId = id; }

/** Normalise a string for loose matching, returning the normalised text and a map back to original indexes. */
function normalizeWithMap(text) {
  let out = '';
  const map = [];
  let lastSpace = true;
  for (let i = 0; i < text.length; i++) {
    let c = text[i];
    if (/\s/.test(c)) {
      if (lastSpace) continue;
      c = ' ';
      lastSpace = true;
    } else {
      lastSpace = false;
      if (c === '\u2018' || c === '\u2019') c = "'";
      else if (c === '\u201c' || c === '\u201d') c = '"';
      else if (c === '\u2013' || c === '\u2014') c = '-';
      c = c.toLowerCase();
    }
    out += c;
    map.push(i);
  }
  return { out, map };
}

/** Best-effort: find ranges [start,end) in `text` covering `quote` (case/whitespace-insensitive). */
export function findQuoteRanges(text, quote) {
  if (!quote || !quote.trim()) return [];
  const { out, map } = normalizeWithMap(text);
  const locate = (q) => {
    const nq = normalizeWithMap(q.trim()).out.trim();
    if (nq.length < 3) return null;
    const idx = out.indexOf(nq);
    if (idx < 0) return null;
    return [map[idx], map[idx + nq.length - 1] + 1];
  };
  const whole = locate(quote);
  if (whole) return [whole];
  // Quotes often elide with "…" or "..."; try each fragment on its own.
  const parts = quote.split(/\u2026|\.{3}/).map((s) => s.trim()).filter((s) => s.length >= 8);
  if (parts.length > 1) {
    return parts.map(locate).filter(Boolean).sort((a, b) => a[0] - b[0]);
  }
  return [];
}

/** Render text as nodes with <mark> around the given ranges. */
function highlighted(text, ranges) {
  const frag = document.createDocumentFragment();
  let pos = 0;
  for (const [s, e] of ranges) {
    if (s < pos) continue;
    if (s > pos) frag.appendChild(document.createTextNode(text.slice(pos, s)));
    frag.appendChild(h('mark', null, text.slice(s, e)));
    pos = e;
  }
  if (pos < text.length) frag.appendChild(document.createTextNode(text.slice(pos)));
  return frag;
}

function passage(text, quote) {
  const ranges = findQuoteRanges(text, quote);
  const box = h('div', { class: 'passage', tabindex: '0', 'aria-label': 'Source passage' });
  box.appendChild(highlighted(text, ranges));
  const wrap = h('div', null, box);
  // Once attached, scroll the first highlight into view inside the passage box.
  setTimeout(() => {
    const m = box.querySelector('mark');
    if (m) box.scrollTop = Math.max(0, m.offsetTop - box.clientHeight / 3);
  }, 60);
  if (quote && quote.trim()) {
    wrap.appendChild(h('div', { class: 'quote-block' },
      h('p', { class: 'eyebrow' }, 'Quoted by the analysis'),
      h('blockquote', null, quote),
      ranges.length
        ? h('p', { class: 'hint' }, 'Highlighted above in the source passage.')
        : h('p', { class: 'hint warn-text' }, 'This quote was not found verbatim in the passage. Treat it with caution and read the passage directly.')));
  }
  return wrap;
}

function kv(rows) {
  const dl = h('dl', { class: 'kv' });
  for (const [k, v] of rows) {
    if (v === null || v === undefined || v === '') continue;
    dl.appendChild(h('dt', null, k));
    dl.appendChild(h('dd', null, v));
  }
  return dl;
}

async function loadDocumentRef(ref, quote) {
  const seg = await api.get(caseUrl(currentCaseId, `/segments/${enc_(ref)}`)).catch((err) => {
    if (err.status === 404) throw new Error('Reference not found in this case');
    throw err;
  });
  return h('div', null,
    kv([['Reference', ref], ['Location', seg.locator_type === 'page' ? `Page ${seg.page_number}` : seg.paragraph_index != null ? `Paragraph ${seg.paragraph_index}` : null],
      ['Section', seg.section_label]]),
    passage(seg.text, quote));
}

async function loadAuthorityRef(ref, quote) {
  const id = ref.replace(/^A:/, '');
  const a = await api.get(`/api/authorities/${enc_(id)}`).catch((err) => {
    if (err.status === 404) throw new Error('Reference not found in this case (authority is not in the local library)');
    throw err;
  });
  const link = a.source_url ? h('a', { href: a.source_url, target: '_blank', rel: 'noopener noreferrer' }, a.source_url) : null;
  return h('div', null,
    kv([['Citation', a.citation], ['Title', a.title], ['Jurisdiction', a.jurisdiction], ['Source URL', link],
      ['Retrieved', fmtDateTime(a.retrieved_at)], ['SHA-256', h('code', { class: 'hash' }, a.sha256)]]),
    passage(a.text, quote),
    h('p', { class: 'hint' }, 'The library stores statute text as retrieved on the date above. It does not confirm the provision is current law.'));
}

/** Open the drawer for any evidence ref. */
export function openEvidence(ref, quote) {
  const isAuth = /^A:/.test(ref);
  const body = (isAuth ? loadAuthorityRef(ref, quote) : loadDocumentRef(ref, quote));
  openDrawer({
    title: isAuth ? 'Legal authority' : 'Source passage',
    subtitle: ref,
    body,
    wide: true,
  });
}

/** Open a bare authority by id (used by legal research list). */
export function openAuthority(id, quote) {
  openEvidence(`A:${id}`, quote);
}

/** A clickable evidence chip. `ref` is a string or {ref, quote}. */
export function evidenceChip(refObj) {
  const ref = typeof refObj === 'string' ? refObj : refObj.ref;
  const quote = typeof refObj === 'string' ? null : refObj.quote;
  return h('button', {
    class: 'chip chip-ref', type: 'button',
    'aria-label': `Inspect evidence ${ref}`, title: quote ? `“${quote.length > 160 ? quote.slice(0, 160) + '…' : quote}”` : 'Inspect source',
    onclick: () => openEvidence(ref, quote),
  }, `[${ref}]`);
}

/** A row of evidence chips (with a small label) for a list of refs. */
export function evidenceList(refs, { label = 'Evidence' } = {}) {
  if (!refs || !refs.length) return h('p', { class: 'muted small' }, 'No evidence references.');
  return h('div', { class: 'evidence-list' },
    h('span', { class: 'eyebrow' }, label),
    h('span', { class: 'chip-row' }, refs.map((r) => evidenceChip(r))),
    // Quotes shown inline are the model's claims; the drawer shows the actual source.
    refs.some((r) => r.quote) ? h('details', { class: 'quotes' },
      h('summary', null, 'Show quoted text'),
      h('ul', null, refs.filter((r) => r.quote).map((r) => h('li', null, h('span', { class: 'chip chip-ref static' }, `[${r.ref}]`), ' ', h('q', null, r.quote))))) : null);
}
