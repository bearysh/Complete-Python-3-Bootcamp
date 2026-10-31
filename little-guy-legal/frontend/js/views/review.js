// Screen 5: review. Tabs over the stage outputs; every evidence ref is an inspectable chip.
import { h, append, clear, replaceChildren, chip, basisChip, confidenceChip, humanize, fmtDateTime, plural, emptyState, spinnerBlock } from '../dom.js';
import { api, caseUrl, enc_ } from '../api.js';
import { currentQuery } from '../router.js';
import { alertBox } from '../ui.js';
import { caseShell } from './shell.js';
import { evidenceChip, evidenceList, setEvidenceCase, openAuthority } from '../evidence.js';

// ---- small render helpers -------------------------------------------------------
const paras = (text) => String(text || '').split(/\n{2,}/).filter(Boolean).map((p) => h('p', null, p));
const section = (title, ...kids) => h('section', { class: 'rv-section' }, title ? h('h3', null, title) : null, kids);
const bullets = (items, empty) => items && items.length ? h('ul', { class: 'bullets' }, items.map((t) => h('li', null, t))) : (empty ? h('p', { class: 'muted' }, empty) : null);
const labelled = (label, content) => content ? h('div', { class: 'lbl-block' }, h('p', { class: 'eyebrow' }, label), content) : null;
const unavailable = (stage) => emptyState('Not available', `The ${stage} stage output is not part of this run's results.`);
const refChips = (ids, kind) => ids && ids.length ? h('span', { class: 'chip-row' }, ids.map((i) => kind === 'A' ? evidenceChip(i.startsWith('A:') ? i : `A:${i}`) : h('span', { class: 'chip chip-neutral static', title: kind === 'F' ? 'Fact id' : 'Provision id' }, i))) : null;

const SIDE_TONE = { customer: ['Customer side stronger', 'info'], opposing: ['Opposing side stronger', 'warn'], unclear: ['Unclear', 'muted'] };
const PRIORITY_TONE = { high: 'bad', medium: 'warn', low: 'muted' };
const BINDING_TONE = { binding: 'good', persuasive: 'info', unverified: 'bad' };
const CHECK_TONE = { verified: 'good', quote_mismatch: 'warn', location_not_found: 'bad', unknown_document: 'bad', unknown_authority: 'bad', invalid_ref: 'bad', no_evidence: 'warn' };

// ---- tab panels ---------------------------------------------------------------
const TABS = [
  { key: 'summary', label: 'Executive summary', count: () => null, render: panelSummary },
  { key: 'issues', label: 'Issues', count: (r) => r.senior_partner?.main_issues?.length, render: panelIssues },
  { key: 'facts', label: 'Key facts & timeline', count: (r) => r.knowledge?.facts?.length, render: panelFacts },
  { key: 'provisions', label: 'Lease provisions', count: (r) => r.knowledge?.key_provisions?.length, render: panelProvisions },
  { key: 'customer', label: 'Customer arguments', count: (r) => r.advocate_customer?.arguments?.length, render: (r) => panelArguments(r.advocate_customer, 'advocate_customer') },
  { key: 'opposing', label: 'Opposing arguments', count: (r) => r.advocate_opposing?.arguments?.length, render: (r) => panelArguments(r.advocate_opposing, 'advocate_opposing') },
  { key: 'skeptic', label: 'Skeptical review', count: (r) => r.judge?.issue_assessments?.length, render: panelSkeptic },
  { key: 'missing', label: 'Missing evidence', count: (r) => missingItems(r).length, render: panelMissing },
  { key: 'research', label: 'Legal research status', count: (r) => r.knowledge?.candidate_authorities?.length, render: panelResearch },
  { key: 'verification', label: 'Verification', count: (r) => failedChecks(r).length, countTone: 'bad', render: panelVerification },
  { key: 'questions', label: 'Questions for counsel', count: (r) => r.senior_partner?.questions_for_attorney?.length, render: panelQuestions },
  { key: 'urgent', label: 'Time-sensitive concerns', count: (r) => r.senior_partner?.time_sensitive_concerns?.length, render: panelUrgent },
];

function panelSummary(r) {
  const sp = r.senior_partner;
  if (!sp) return unavailable('senior partner');
  return h('div', null,
    section(null, h('div', { class: 'prose' }, paras(sp.executive_summary))),
    sp.practical_considerations?.length ? section('Practical considerations', bullets(sp.practical_considerations)) : null,
    sp.unverified_claims?.length ? section('Claims that remain unverified', bullets(sp.unverified_claims)) : null,
    r.knowledge?.caveats?.length ? section('Caveats from document review', bullets(r.knowledge.caveats)) : null,
    r.judge?.attorney_review_required?.length ? section('Flagged for attorney review', bullets(r.judge.attorney_review_required)) : null);
}

function panelIssues(r) {
  const issues = r.senior_partner?.main_issues;
  if (!issues) return unavailable('senior partner');
  if (!issues.length) return emptyState('No issues identified');
  return h('div', { class: 'stack' }, issues.map((i) => h('article', { class: 'card inner' },
    h('div', { class: 'card-head' }, h('h3', null, i.title), h('span', { class: 'chip chip-neutral static' }, i.id)),
    h('p', null, i.explanation),
    h('div', { class: 'versus' },
      h('div', { class: 'versus-col side-customer' }, h('p', { class: 'eyebrow' }, 'Customer position'), h('p', null, i.customer_position)),
      h('div', { class: 'versus-col side-opposing' }, h('p', { class: 'eyebrow' }, 'Opposing position'), h('p', null, i.opposing_position))),
    labelled('Current assessment', h('p', null, i.current_assessment)),
    evidenceList(i.refs))));
}

function panelFacts(r) {
  const k = r.knowledge;
  if (!k) return unavailable('knowledge');
  const legend = h('div', { class: 'legend' },
    [['documented', 'Stated in a document'], ['customer_allegation', 'Claimed by the customer, not documented'], ['inference', 'Reasoned from other facts'], ['unverified', 'Could not be checked']]
      .map(([b, d]) => h('span', { class: 'legend-item' }, basisChip(b), h('span', { class: 'muted small' }, d))));
  return h('div', null,
    legend,
    section('Key facts', k.facts?.length ? h('div', { class: 'stack tight' }, k.facts.map((f) => h('article', { class: 'item' },
      h('div', { class: 'item-head' }, h('span', { class: 'chip chip-neutral static' }, f.id), basisChip(f.basis), f.date ? h('span', { class: 'muted small' }, f.date) : null),
      h('p', null, f.statement), evidenceList(f.refs)))) : h('p', { class: 'muted' }, 'No facts were extracted.')),
    section('Timeline', k.timeline?.length ? h('ol', { class: 'timeline' }, [...k.timeline].sort((a, b) => String(a.date).localeCompare(String(b.date))).map((t) => h('li', null,
      h('div', { class: 'tl-date' }, t.date), h('div', { class: 'tl-body' }, h('div', { class: 'item-head' }, basisChip(t.basis)), h('p', null, t.description), evidenceList(t.refs))))) : h('p', { class: 'muted' }, 'No timeline events.')),
    k.parties?.length ? section('Parties', h('div', { class: 'stack tight' }, k.parties.map((p) => h('article', { class: 'item' },
      h('div', { class: 'item-head' }, h('strong', null, p.name), chip(p.role, 'neutral')), evidenceList(p.refs))))) : null,
    k.document_summaries?.length ? section('Document summaries', h('div', { class: 'stack tight' }, k.document_summaries.map((d) => h('article', { class: 'item' },
      h('div', { class: 'item-head' }, evidenceChip(d.doc_ref), h('span', { class: 'muted small' }, d.document_type)), h('p', null, d.summary))))) : null);
}

function panelProvisions(r) {
  const provs = r.knowledge?.key_provisions;
  if (!provs) return unavailable('knowledge');
  if (!provs.length) return emptyState('No provisions identified');
  return h('div', { class: 'stack' }, provs.map((p) => h('article', { class: 'card inner' },
    h('div', { class: 'card-head' }, h('h3', null, p.title), h('span', { class: 'chip chip-neutral static' }, p.id)),
    h('p', null, p.summary),
    (p.refs || []).filter((x) => x.quote).map((x) => h('figure', { class: 'quote-fig' },
      h('blockquote', null, x.quote), h('figcaption', null, evidenceChip(x)))),
    (p.refs || []).filter((x) => !x.quote).length ? evidenceList(p.refs.filter((x) => !x.quote)) : null,
    p.ambiguity_notes ? alertBox(h('span', null, h('strong', null, 'Possible ambiguity: '), p.ambiguity_notes), 'warn') : null)));
}

function panelArguments(out, stage) {
  if (!out) return unavailable(humanize(stage));
  const side = stage === 'advocate_customer' ? 'customer' : 'opposing';
  return h('div', null,
    h('div', { class: 'callout' }, h('p', { class: 'eyebrow' }, `Overall assessment · ${humanize(out.style)} style`), h('p', null, out.overall_assessment)),
    h('p', { class: 'muted small' }, 'These are advocacy positions, written to argue one side. They are not conclusions; see the skeptical review for how well each holds up.'),
    out.arguments?.length ? h('div', { class: 'stack' }, out.arguments.map((a) => h('article', { class: `card inner side-${side}` },
      h('div', { class: 'card-head' }, h('h3', null, a.title), h('span', { class: 'head-chips' }, h('span', { class: 'chip chip-neutral static' }, a.id), confidenceChip(a.confidence))),
      h('p', null, a.summary),
      a.confidence_rationale ? h('p', { class: 'muted small' }, `Why this confidence: ${a.confidence_rationale}`) : null,
      (a.supporting_fact_ids?.length || a.supporting_provision_ids?.length || a.supporting_authority_ids?.length) ? labelled('Relies on', h('div', { class: 'chip-row' },
        refChips(a.supporting_fact_ids, 'F'), refChips(a.supporting_provision_ids, 'P'), refChips(a.supporting_authority_ids, 'A'))) : null,
      evidenceList(a.refs),
      h('div', { class: 'three-col' },
        labelled('Assumptions', bullets(a.assumptions, 'None stated.')),
        labelled('Evidentiary weaknesses', bullets(a.evidentiary_weaknesses, 'None stated.')),
        labelled('Anticipated counterarguments', bullets(a.anticipated_counterarguments, 'None stated.')))))) : emptyState('No arguments produced'));
}

function panelSkeptic(r) {
  const j = r.judge;
  if (!j) return unavailable('judge');
  return h('div', null,
    h('div', { class: 'callout' }, h('p', { class: 'eyebrow' }, 'Overall commentary'), h('p', null, j.overall_commentary)),
    section('Issue assessments', j.issue_assessments?.length ? h('div', { class: 'stack' }, j.issue_assessments.map((a) => {
      const [label, tone] = SIDE_TONE[a.stronger_side] || [humanize(a.stronger_side), 'neutral'];
      return h('article', { class: 'card inner' },
        h('div', { class: 'card-head' }, h('h3', null, a.issue), h('span', { class: 'head-chips' }, h('span', { class: 'chip chip-neutral static' }, a.issue_id), chip(label, tone))),
        h('p', null, a.reasoning),
        h('div', { class: 'three-col' },
          labelled('Unsupported claims', bullets(a.unsupported_claims?.length ? a.unsupported_claims : null)),
          labelled('Evidence gaps', bullets(a.evidence_gaps?.length ? a.evidence_gaps : null)),
          labelled('Procedural concerns', bullets(a.procedural_concerns?.length ? a.procedural_concerns : null))),
        evidenceList(a.refs));
    })) : h('p', { class: 'muted' }, 'No assessments.')),
    j.unsupported_interpretations?.length ? section('Unsupported interpretations', h('div', { class: 'stack tight' }, j.unsupported_interpretations.map((u) =>
      h('article', { class: 'item' }, h('div', { class: 'item-head' }, h('span', { class: 'chip chip-neutral static' }, u.argument_id)), h('p', null, u.problem))))) : null,
    j.conflicting_provisions?.length ? section('Conflicting provisions', h('div', { class: 'stack tight' }, j.conflicting_provisions.map((c) =>
      h('article', { class: 'item' }, h('div', { class: 'item-head' }, (c.provision_ids || []).map((p) => h('span', { class: 'chip chip-neutral static' }, p))), h('p', null, c.description))))) : null,
    j.additional_evidence_needed?.length ? section('Additional evidence needed', h('div', { class: 'stack tight' }, [...j.additional_evidence_needed]
      .sort((a, b) => ['high', 'medium', 'low'].indexOf(a.priority) - ['high', 'medium', 'low'].indexOf(b.priority)).map((e) =>
        h('article', { class: 'item' }, h('div', { class: 'item-head' }, chip(`${e.priority} priority`, PRIORITY_TONE[e.priority] || 'neutral'), h('strong', null, e.item)), h('p', null, e.why_it_matters))))) : null,
    j.attorney_review_required?.length ? section('Attorney review required', bullets(j.attorney_review_required)) : null);
}

function missingItems(r) {
  const all = [...(r.knowledge?.missing_information || []), ...(r.senior_partner?.information_gaps || [])];
  return [...new Set(all)];
}
function panelMissing(r) {
  if (!r.knowledge && !r.senior_partner) return unavailable('knowledge / senior partner');
  const items = missingItems(r);
  return items.length ? h('div', null, h('p', { class: 'muted' }, 'Information the analysis could not find in the uploaded documents or intake. Gathering these would strengthen or change the analysis.'), bullets(items))
    : emptyState('No missing information was recorded');
}

function panelResearch(r) {
  const k = r.knowledge;
  if (!k) return unavailable('knowledge');
  const cands = k.candidate_authorities || [];
  return h('div', null,
    alertBox('Authorities come from a local library of Texas statutes. A match here means the cited text exists in the library — not that it is current, applicable, or good law. Case law is not covered.', 'info'),
    section('Candidate authorities', cands.length ? h('div', { class: 'stack' }, cands.map((a) => {
      const none = !a.authority_id || a.authority_id === 'none';
      return h('article', { class: 'card inner' },
        h('div', { class: 'card-head' }, h('h3', null, a.citation), h('span', { class: 'head-chips' },
          chip(a.binding_status, BINDING_TONE[a.binding_status] || 'neutral', 'Binding status asserted by the analysis'),
          none ? chip('Not in local library', 'bad', 'authority_id is "none": this cannot be checked against stored text') : chip('In local library', 'good'))),
        h('p', null, a.relevance),
        a.quote ? h('figure', { class: 'quote-fig' }, h('blockquote', null, a.quote)) : null,
        none ? alertBox('This authority is not in the local library, so its text and citation could not be verified. Treat it as an unverified lead for counsel.', 'warn')
          : h('div', { class: 'actions' }, h('button', { class: 'btn btn-sm', type: 'button', onclick: () => openAuthority(a.authority_id, a.quote) }, 'View statute text'), h('code', { class: 'hash' }, a.authority_id)));
    })) : h('p', { class: 'muted' }, 'No authorities were identified.')),
    k.legal_questions?.length ? section('Legal questions raised', h('div', { class: 'stack tight' }, k.legal_questions.map((q) =>
      h('article', { class: 'item' }, h('div', { class: 'item-head' }, h('span', { class: 'chip chip-neutral static' }, q.id), h('strong', null, q.question)), h('p', { class: 'muted' }, q.why_it_matters))))) : null);
}

function failedChecks(r) { return (r.verification?.checks || []).filter((c) => c.status !== 'verified'); }

function panelVerification(r) {
  const v = r.verification;
  if (!v) return unavailable('verification');
  const s = v.summary || {};
  const tile = (n, label, tone) => h('div', { class: `stat ${tone ? 'stat-' + tone : ''}` }, h('div', { class: 'stat-n' }, String(n ?? 0)), h('div', { class: 'stat-l' }, label));
  const failed = failedChecks(r);
  return h('div', null,
    v.material_failure ? alertBox(h('span', null, h('strong', null, 'Material verification failure. '),
      'At least one citation, quote or finding that matters to the analysis could not be confirmed against the source. Do not rely on the affected statements until counsel has checked them.'), 'error') : null,
    h('div', { class: 'stats' },
      tile(s.total_checks, 'Checks run'), tile(s.verified, 'Verified', 'good'), tile(s.failed, 'Failed', s.failed ? 'bad' : ''),
      tile(s.material_failures, 'Material failures', s.material_failures ? 'bad' : ''), tile(s.unsupported_findings, 'Unsupported findings', s.unsupported_findings ? 'warn' : ''),
      tile(s.fabricated_authority_refs, 'Unknown authority refs', s.fabricated_authority_refs ? 'bad' : '')),
    h('p', { class: 'muted small' }, 'Verification is mechanical: it checks that cited passages exist and that quotes appear in them. It does not judge whether the reasoning is right.'),
    section(`Checks needing attention (${failed.length})`, failed.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'table compact' },
      h('thead', null, h('tr', null, ['Target', 'Reference', 'Status', 'Detail'].map((t) => h('th', { scope: 'col' }, t)))),
      h('tbody', null, failed.map((c) => h('tr', null,
        h('td', null, h('code', null, c.target), c.material ? h('div', null, chip('material', 'bad')) : null),
        h('td', null, c.ref ? evidenceChip(c.ref) : h('span', { class: 'muted' }, '—')),
        h('td', null, chip(humanize(c.status), CHECK_TONE[c.status] || 'neutral')),
        h('td', null, c.detail || '', c.resolved_location ? h('div', { class: 'muted small' }, `Resolved to ${c.resolved_location}`) : null)))))) : h('p', { class: 'text-good' }, 'Every check passed.')),
    v.notes?.length ? section('Notes', bullets(v.notes)) : null,
    v.limitations?.length ? section('Limitations of verification', bullets(v.limitations)) : null);
}

function panelQuestions(r) {
  const q = r.senior_partner?.questions_for_attorney;
  if (!q) return unavailable('senior partner');
  return q.length ? h('ol', { class: 'numbered' }, q.map((t) => h('li', null, t))) : emptyState('No questions recorded');
}

function panelUrgent(r) {
  const t = r.senior_partner?.time_sensitive_concerns;
  if (!t) return unavailable('senior partner');
  if (!t.length) return emptyState('No time-sensitive concerns were identified', 'This does not mean there are none. Confirm all deadlines with counsel.');
  return h('div', { class: 'stack' }, t.map((c) => h('article', { class: 'card inner urgent' },
    h('div', { class: 'item-head' }, chip(c.date_or_deadline, 'warn'), basisChip(c.basis)), h('p', null, c.concern), evidenceList(c.refs))));
}

// ---- view -----------------------------------------------------------------------
export async function reviewView(root, { id }, isCurrent) {
  const shell = await caseShell(root, id, 'review');
  if (!shell) return;
  setEvidenceCase(id);
  const body = shell.body;
  body.appendChild(spinnerBlock('Loading results…'));

  // Pick the run: ?run= override, else latest if completed, else newest completed run.
  let run = null, note = null;
  try {
    const wanted = currentQuery().get('run');
    const latest = await api.get(caseUrl(id, '/analysis'));
    if (wanted) {
      run = await api.get(caseUrl(id, `/analysis/runs/${enc_(wanted)}`));
    } else if (latest.status === 'completed') {
      run = latest;
    } else {
      const runs = await api.get(caseUrl(id, '/analysis/runs'));
      run = runs.filter((r) => r.status === 'completed').sort((a, b) => String(b.started_at).localeCompare(String(a.started_at)))[0] || null;
      if (run && latest.status && latest.status !== 'none') note = `The latest run is ${latest.status}; showing results from the most recent completed run (started ${fmtDateTime(run.started_at)}).`;
    }
    if (!isCurrent()) return;
    if (!run) {
      replaceChildren(body, emptyState('No completed analysis yet', 'Results appear here once all stages have finished.'),
        h('p', { class: 'center' }, h('a', { class: 'btn btn-primary', href: `/cases/${enc_(id)}/${latest.status && latest.status !== 'none' ? 'progress' : ''}` }, latest.status && latest.status !== 'none' ? 'View progress' : 'Go to intake')));
      return;
    }
    const results = await api.get(caseUrl(id, `/analysis/runs/${enc_(run.id)}/results`));
    if (!isCurrent()) return;
    renderResults(body, results, run, note);
  } catch (err) {
    replaceChildren(body, alertBox(err.message));
  }

  function renderResults(host, results, run, note) {
    const startKey = currentQuery().get('tab');
    let active = TABS.some((t) => t.key === startKey) ? startKey : 'summary';
    const panelBox = h('div', { class: 'tabpanel-wrap' });
    const cache = {};
    const tabEls = {};

    const select = (key, focus) => {
      active = key;
      for (const t of TABS) {
        const on = t.key === key;
        tabEls[t.key].setAttribute('aria-selected', String(on));
        tabEls[t.key].tabIndex = on ? 0 : -1;
      }
      if (!cache[key]) {
        const t = TABS.find((x) => x.key === key);
        let content;
        try { content = t.render(results); } catch (e) { content = alertBox(`Could not display this section: ${e.message}`); }
        cache[key] = h('div', { class: 'tabpanel', role: 'tabpanel', id: `panel-${key}`, 'aria-labelledby': `tab-${key}`, tabindex: '0' },
          h('h2', null, t.label), content);
      }
      replaceChildren(panelBox, cache[key]);
      const url = new URL(location.href);
      url.searchParams.set('tab', key);
      history.replaceState({}, '', url);
      if (focus) tabEls[key].focus();
    };

    const nav = h('div', { class: 'tablist', role: 'tablist', 'aria-label': 'Result sections', 'aria-orientation': 'vertical',
      onkeydown: (e) => {
        const i = TABS.findIndex((t) => t.key === active);
        let n = null;
        if (e.key === 'ArrowDown' || e.key === 'ArrowRight') n = (i + 1) % TABS.length;
        else if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') n = (i - 1 + TABS.length) % TABS.length;
        else if (e.key === 'Home') n = 0;
        else if (e.key === 'End') n = TABS.length - 1;
        if (n !== null) { e.preventDefault(); select(TABS[n].key, true); }
      } },
      TABS.map((t) => {
        const count = t.count(results);
        const el = h('button', { class: 'tab', type: 'button', role: 'tab', id: `tab-${t.key}`, 'aria-controls': `panel-${t.key}`, 'aria-selected': 'false', tabindex: '-1',
          onclick: () => select(t.key) },
          h('span', null, t.label), count ? h('span', { class: `tab-count ${t.countTone ? 'tone-' + t.countTone : ''}`, 'aria-label': `${count} items` }, String(count)) : null);
        tabEls[t.key] = el;
        return el;
      }));

    const v = results.verification;
    const real = run.provider !== 'scripted';
    replaceChildren(host,
      h('div', { class: 'review-top' },
        h('div', null,
          h('p', { class: 'muted small' }, `Analysis run ${fmtDateTime(run.started_at)} · ${[run.provider, run.model].filter(Boolean).join(' · ')} · ${humanize(run.argument_style)} style`)),
        h('a', { class: 'btn btn-primary', href: `/cases/${enc_(id)}/report` }, 'Go to report')),
      note ? alertBox(note, 'warn') : null,
      !real ? alertBox('These results were produced by the scripted test provider. They are canned fixtures, not model-generated analysis.', 'warn') : null,
      v?.material_failure ? alertBox(h('span', null, h('strong', null, 'Verification found material failures. '), h('a', { href: '#', onclick: (e) => { e.preventDefault(); select('verification', true); } }, 'See the Verification tab.')), 'error') : null,
      alertBox('AI-assisted research for attorney review. Select any [reference] to read the original passage the statement relies on.', 'info'),
      h('div', { class: 'review-layout' }, nav, panelBox),
      h('div', { class: 'actions end' }, h('a', { class: 'btn btn-primary', href: `/cases/${enc_(id)}/report` }, 'Go to report')));
    select(active);
  }
}
