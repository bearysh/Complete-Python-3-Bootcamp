// Shared page chrome for a single case: title, status, and the Intake → Progress → Review → Report stepper.
import { h, statusChip, fmtDate, replaceChildren, spinnerBlock, emptyState } from '../dom.js';
import { api, caseUrl } from '../api.js';

const STEPS = [
  { key: 'intake', label: 'Intake', path: '' },
  { key: 'progress', label: 'Progress', path: '/progress' },
  { key: 'review', label: 'Review', path: '/review' },
  { key: 'report', label: 'Report', path: '/report' },
];

/** Which steps are reachable / finished, derived from the case record. */
export function stepStates(c) {
  const hasRun = !!c.latest_run_id;
  const reviewable = ['analyzed', 'report_draft', 'report_approved', 'report_rejected'].includes(c.status) || c.latest_run_status === 'completed';
  const hasReport = !!c.latest_report_id;
  const finalReport = ['report_approved', 'report_rejected'].includes(c.status);
  return {
    intake: { enabled: true, done: hasRun },
    progress: { enabled: hasRun, done: reviewable },
    review: { enabled: reviewable, done: hasReport },
    report: { enabled: hasReport, done: finalReport },
  };
}

export function stepNav(c, active) {
  const st = stepStates(c);
  const items = STEPS.map((s, i) => {
    const state = st[s.key];
    const isActive = s.key === active;
    const cls = ['step', isActive ? 'is-current' : '', state.done ? 'is-done' : '', !state.enabled ? 'is-disabled' : ''].join(' ').trim();
    const num = h('span', { class: 'step-num', 'aria-hidden': 'true' }, state.done && !isActive ? '✓' : String(i + 1));
    const label = h('span', { class: 'step-label' }, s.label);
    const status = isActive ? 'current step' : state.done ? 'completed' : state.enabled ? 'available' : 'not available yet';
    const sr = h('span', { class: 'sr-only' }, ` (${status})`);
    const inner = [num, label, sr];
    const li = h('li', { class: cls });
    if (state.enabled) {
      li.appendChild(h('a', { href: `/cases/${encodeURIComponent(c.id)}${s.path}`, 'aria-current': isActive ? 'step' : null }, inner));
    } else {
      li.appendChild(h('span', { 'aria-disabled': 'true' }, inner));
    }
    return li;
  });
  return h('nav', { class: 'stepnav', 'aria-label': 'Case workflow' }, h('ol', null, items));
}

/**
 * Render the case header into `root` and return { page, body, case } where `body` is the container for the view.
 * On failure renders an error panel and returns null.
 */
export async function caseShell(root, caseId, active) {
  root.appendChild(spinnerBlock('Loading case…'));
  let c;
  try {
    c = await api.get(caseUrl(caseId));
  } catch (err) {
    replaceChildren(root, h('div', { class: 'page narrow' },
      emptyState(err.status === 404 ? 'Case not found' : 'Could not load this case', err.message),
      h('p', null, h('a', { class: 'btn', href: '/' }, 'Back to cases'))));
    return null;
  }
  const body = h('div', { class: 'case-body' });
  const header = h('header', { class: 'case-header' },
    h('nav', { class: 'crumbs', 'aria-label': 'Breadcrumb' }, h('a', { href: '/' }, 'Cases'), ' / ', h('span', null, c.title)),
    h('div', { class: 'case-title-row' },
      h('h1', null, c.title),
      statusChip(c.status)),
    h('p', { class: 'muted small' }, `${c.county} County, ${c.jurisdiction} · ${c.matter_type} · created ${fmtDate(c.created_at)}`),
    stepNav(c, active));
  const page = h('div', { class: 'page' }, header, body);
  document.title = `${c.title} — Little Guy Legal`;
  replaceChildren(root, page);
  return { page, body, case: c };
}
