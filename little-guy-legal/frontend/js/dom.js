// Tiny DOM helpers. All text goes through text nodes / textContent, never innerHTML,
// so untrusted strings (document text, model output) cannot inject markup.

/** Create an element: h('div', {class:'x', onclick: fn, 'aria-label':'..'}, 'text', childNode, ...) */
export function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v === undefined || v === null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'dataset') Object.assign(el.dataset, v);
      else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
      else if (k === 'value' || k === 'checked' || k === 'disabled' || k === 'selected' || k === 'hidden') el[k] = v;
      else el.setAttribute(k, v === true ? '' : String(v));
    }
  }
  append(el, children);
  return el;
}

/** Append strings/nodes/arrays (nested) to a parent. null/false are skipped. */
export function append(parent, children) {
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    if (Array.isArray(c)) append(parent, c);
    else if (c instanceof Node) parent.appendChild(c);
    else parent.appendChild(document.createTextNode(String(c)));
  }
  return parent;
}

export function clear(el) {
  while (el.firstChild) el.removeChild(el.firstChild);
  return el;
}

export function replaceChildren(el, ...children) {
  clear(el);
  return append(el, children);
}

// ---- formatting -----------------------------------------------------------

export function fmtDateTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return String(iso);
  return d.toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

export function fmtDate(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return String(iso);
  return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}

export function fmtDuration(ms) {
  if (ms === null || ms === undefined) return '';
  if (ms < 1000) return `${ms} ms`;
  const s = ms / 1000;
  if (s < 60) return `${s.toFixed(1)} s`;
  const m = Math.floor(s / 60);
  return `${m} min ${Math.round(s - m * 60)} s`;
}

export function fmtBytes(n) {
  if (n === null || n === undefined) return '';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

/** "customer_allegation" -> "customer allegation" */
export function humanize(s) {
  return String(s ?? '').replace(/_/g, ' ');
}

export function plural(n, one, many) {
  return `${n} ${n === 1 ? one : (many || one + 's')}`;
}

// ---- chips ----------------------------------------------------------------

/** A status chip. tone: neutral|info|good|warn|bad|muted. */
export function chip(label, tone = 'neutral', title) {
  return h('span', { class: `chip chip-${tone}`, title }, label);
}

const STATUS_TONE = {
  intake: ['Intake', 'neutral'], analyzing: ['Analyzing', 'info'], analyzed: ['Analysis complete', 'good'],
  report_draft: ['Report draft', 'warn'], report_approved: ['Report approved', 'good'], report_rejected: ['Report rejected', 'bad'],
  draft: ['Draft — not approved', 'warn'], approved: ['Approved', 'good'], rejected: ['Rejected', 'bad'],
  queued: ['Queued', 'info'], running: ['Running', 'info'], completed: ['Completed', 'good'], failed: ['Failed', 'bad'],
  cancelled: ['Cancelled', 'muted'], interrupted: ['Interrupted', 'warn'], pending: ['Pending', 'muted'], extracted: ['Extracted', 'good'],
};

export function statusChip(status, fallback = '—') {
  if (!status) return h('span', { class: 'muted' }, fallback);
  const [label, tone] = STATUS_TONE[status] || [humanize(status), 'neutral'];
  return chip(label, tone);
}

const BASIS_TONE = { documented: 'good', customer_allegation: 'warn', inference: 'info', unverified: 'bad' };
export function basisChip(basis) {
  return chip(humanize(basis), BASIS_TONE[basis] || 'neutral', 'Basis of this statement');
}

const CONF_TONE = { high: 'good', moderate: 'info', low: 'warn' };
export function confidenceChip(c) {
  return chip(`${c} confidence`, CONF_TONE[c] || 'neutral');
}

export function emptyState(title, hint) {
  return h('div', { class: 'empty' }, h('p', { class: 'empty-title' }, title), hint ? h('p', { class: 'muted' }, hint) : null);
}

export function spinnerBlock(text = 'Loading…') {
  return h('div', { class: 'loading', role: 'status' }, h('span', { class: 'spinner', 'aria-hidden': 'true' }), text);
}
