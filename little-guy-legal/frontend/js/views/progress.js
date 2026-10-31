// Screen 4: analysis progress. Polls while the run is queued/running. Never shows percentages.
import { h, append, replaceChildren, statusChip, fmtDateTime, fmtDuration, emptyState, spinnerBlock, humanize } from '../dom.js';
import { api, guarded, caseUrl, enc_ } from '../api.js';
import { navigate } from '../router.js';
import { alertBox } from '../ui.js';
import { caseShell } from './shell.js';

const POLL_MS = 2500;
const STAGE_ICON = { pending: '', running: '', completed: '✓', failed: '✕', cancelled: '–' };
const STYLE_LABEL = { by_the_book: 'By the Book', aggressive: 'Aggressive', maximum_challenge: 'Maximum Challenge' };

export async function progressView(root, { id }, isCurrent) {
  const shell = await caseShell(root, id, 'progress');
  if (!shell) return;
  let timer = null;
  let stopped = false;
  let wasActive = false;
  const host = h('div', { class: 'progress-view' });
  const runsHost = h('details', { class: 'card runs-card' }, h('summary', null, 'Previous runs'), h('div', { class: 'runs-body' }, spinnerBlock()));
  append(shell.body, [host, runsHost]);

  function stageItem(s) {
    const bits = [];
    if (s.duration_ms !== null && s.duration_ms !== undefined) bits.push(fmtDuration(s.duration_ms));
    if (s.attempt && s.attempt > 1) bits.push(`attempt ${s.attempt}`);
    else if (s.attempt && s.status !== 'pending') bits.push(`attempt ${s.attempt}`);
    const aria = `${s.label}: ${s.status}${bits.length ? ', ' + bits.join(', ') : ''}`;
    return h('li', { class: `stage stage-${s.status}`, 'aria-label': aria, tabindex: '0' },
      h('span', { class: 'stage-marker', 'aria-hidden': 'true' }, s.status === 'running' ? h('span', { class: 'spinner' }) : STAGE_ICON[s.status] || ''),
      h('div', { class: 'stage-main' },
        h('div', { class: 'stage-title' }, h('strong', null, s.label), statusChip(s.status)),
        bits.length ? h('div', { class: 'muted small' }, bits.join(' · ')) : null,
        s.error ? h('p', { class: 'text-bad small stage-error' }, s.error) : null));
  }

  async function runAction(label, fn) {
    const r = await guarded(fn);
    if (r) { await refresh(); loadRuns(); }
  }

  function renderRun(run) {
    if (!run || run.status === 'none') {
      replaceChildren(host, emptyState('No analysis has been run', 'Add documents and complete intake, then start an analysis.'),
        h('p', { class: 'center' }, h('a', { class: 'btn btn-primary', href: `/cases/${enc_(id)}` }, 'Go to intake')));
      return;
    }
    const active = ['queued', 'running'].includes(run.status);
    const resumable = ['failed', 'interrupted', 'cancelled'].includes(run.status);
    const actions = h('div', { class: 'actions' },
      active ? h('button', { class: 'btn', type: 'button', onclick: () => runAction('cancel', () => api.post(caseUrl(id, `/analysis/runs/${enc_(run.id)}/cancel`))) }, 'Cancel') : null,
      resumable ? h('button', { class: 'btn btn-primary', type: 'button', onclick: () => runAction('resume', () => api.post(caseUrl(id, `/analysis/runs/${enc_(run.id)}/resume`))) }, 'Resume') : null,
      run.status === 'completed' ? h('a', { class: 'btn btn-primary', href: `/cases/${enc_(id)}/review` }, 'Open review') : null,
      !active ? h('a', { class: 'btn btn-quiet', href: `/cases/${enc_(id)}` }, 'Back to intake') : null);
    const heading = {
      queued: 'Analysis queued', running: 'Analysis in progress', completed: 'Analysis complete', failed: 'Analysis stopped with an error',
      cancelled: 'Analysis cancelled', interrupted: 'Analysis interrupted',
    }[run.status] || 'Analysis';
    replaceChildren(host, h('section', { class: 'card', 'aria-labelledby': 'run-h' },
      h('div', { class: 'card-head' }, h('h2', { id: 'run-h' }, heading), statusChip(run.status)),
      h('dl', { class: 'kv kv-inline' },
        h('dt', null, 'Provider'), h('dd', null, [run.provider, run.model].filter(Boolean).join(' · ') || '—'),
        h('dt', null, 'Style'), h('dd', null, STYLE_LABEL[run.argument_style] || humanize(run.argument_style)),
        h('dt', null, 'Started'), h('dd', null, fmtDateTime(run.started_at)),
        run.finished_at ? [h('dt', null, 'Finished'), h('dd', null, fmtDateTime(run.finished_at))] : null),
      run.provider === 'scripted' ? alertBox('This run uses the scripted test provider. Its outputs are canned fixtures, not model-generated.', 'warn') : null,
      run.error ? alertBox(run.error, 'error') : null,
      h('div', { class: 'sr-only', role: 'status', 'aria-live': 'polite' }, `${heading}. Current stage: ${run.current_stage ? humanize(run.current_stage) : 'none'}.`),
      h('ol', { class: 'stages', 'aria-label': 'Analysis stages' }, (run.stages || []).map(stageItem)),
      active ? h('p', { class: 'muted small' }, 'Stages run one after another on this computer. This page updates automatically; you can leave and come back.') : null,
      resumable ? h('p', { class: 'muted small' }, 'Resume continues from the last completed stage; finished stages are not repeated.') : null,
      actions));
  }

  async function refresh() {
    clearTimeout(timer);
    let run;
    try { run = await api.get(caseUrl(id, '/analysis')); }
    catch (err) {
      if (!stopped) { replaceChildren(host, alertBox(err.message)); timer = setTimeout(refresh, POLL_MS * 2); }
      return;
    }
    if (stopped || !isCurrent()) return;
    const active = run && ['queued', 'running'].includes(run.status);
    if (wasActive && !active) { navigate(location.pathname, { replace: true }); return; } // re-render so the case header/step nav update
    wasActive = active;
    renderRun(run);
    if (active) timer = setTimeout(refresh, POLL_MS);
  }

  async function loadRuns() {
    const body = runsHost.querySelector('.runs-body');
    try {
      const runs = await api.get(caseUrl(id, '/analysis/runs'));
      if (stopped) return;
      runsHost.querySelector('summary').textContent = `Previous runs (${runs.length})`;
      replaceChildren(body, runs.length ? h('table', { class: 'table compact' },
        h('thead', null, h('tr', null, ['Started', 'Status', 'Provider', 'Style', ''].map((t) => h('th', { scope: 'col' }, t)))),
        h('tbody', null, runs.map((r) => h('tr', null,
          h('td', null, fmtDateTime(r.started_at)), h('td', null, statusChip(r.status)),
          h('td', null, [r.provider, r.model].filter(Boolean).join(' · ')), h('td', null, STYLE_LABEL[r.argument_style] || humanize(r.argument_style)),
          h('td', null, r.status === 'completed' ? h('a', { href: `/cases/${enc_(id)}/review?run=${enc_(r.id)}` }, 'View results') : null)))))
        : h('p', { class: 'muted' }, 'No runs yet.'));
    } catch (err) { replaceChildren(body, alertBox(err.message)); }
  }

  replaceChildren(host, spinnerBlock('Loading analysis status…'));
  await Promise.all([refresh(), loadRuns()]);
  return () => { stopped = true; clearTimeout(timer); };
}
