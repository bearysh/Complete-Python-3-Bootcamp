// Screen 6: report preview and attorney-review (approve / reject) form.
import { h, append, replaceChildren, chip, statusChip, fmtDateTime, humanize, plural, emptyState, spinnerBlock } from '../dom.js';
import { api, guarded, caseUrl, enc_ } from '../api.js';
import { navigate, currentQuery } from '../router.js';
import { alertBox, field, toast } from '../ui.js';
import { caseShell } from './shell.js';
import { evidenceChip, setEvidenceCase } from '../evidence.js';

const NAME_KEY = 'lgl.reviewerName';
const readName = () => { try { return localStorage.getItem(NAME_KEY) || ''; } catch { return ''; } };
const saveName = (v) => { try { localStorage.setItem(NAME_KEY, v); } catch { /* storage unavailable */ } };

export async function reportView(root, { id }, isCurrent) {
  const shell = await caseShell(root, id, 'report');
  if (!shell) return;
  setEvidenceCase(id);
  const body = shell.body;
  body.appendChild(spinnerBlock('Loading reports…'));

  let reports;
  try { reports = await api.get(caseUrl(id, '/reports')); }
  catch (err) { replaceChildren(body, alertBox(err.message)); return; }
  if (!isCurrent()) return;
  if (!reports.length) {
    replaceChildren(body, emptyState('No report yet', 'A draft report is created when an analysis run finishes all stages.'),
      h('p', { class: 'center' }, h('a', { class: 'btn', href: `/cases/${enc_(id)}/progress` }, 'View analysis progress')));
    return;
  }
  reports = [...reports].sort((a, b) => b.version - a.version);
  const wanted = currentQuery().get('report');
  const meta0 = reports.find((r) => r.id === wanted) || reports[0];

  let detail;
  try { detail = await api.get(caseUrl(id, `/reports/${enc_(meta0.id)}`)); }
  catch (err) { replaceChildren(body, alertBox(err.message)); return; }
  if (!isCurrent()) return;
  const { meta, data } = detail;
  const v = data.verification || { checks: [], summary: {}, material_failure: false };
  const rid = enc_(meta.id);
  const pdfUrl = caseUrl(id, `/reports/${rid}/pdf`);
  const jsonUrl = caseUrl(id, `/reports/${rid}/json`);

  // ---- status banner: a draft is never styled like an approval ------------------
  const statusBanner = (() => {
    if (meta.status === 'approved') return h('div', { class: 'status-banner sb-approved', role: 'status' },
      h('strong', null, 'APPROVED'), h('span', null, `Reviewed by ${meta.reviewer} on ${fmtDateTime(meta.reviewed_at)}. Approval records operator review only; it is not attorney sign-off.`));
    if (meta.status === 'rejected') return h('div', { class: 'status-banner sb-rejected', role: 'status' },
      h('strong', null, 'REJECTED'), h('span', null, `Rejected by ${meta.reviewer} on ${fmtDateTime(meta.reviewed_at)}.`));
    return h('div', { class: 'status-banner sb-draft', role: 'status' },
      h('strong', null, 'DRAFT — NOT APPROVED'), h('span', null, 'This report has not been reviewed. Do not rely on it or share it as final.'));
  })();

  const picker = reports.length > 1 ? h('label', { class: 'inline-label' }, h('span', null, 'Version'),
    h('select', { onchange: (e) => navigate(`/cases/${enc_(id)}/report?report=${enc_(e.target.value)}`) },
      reports.map((r) => h('option', { value: r.id, selected: r.id === meta.id }, `v${r.version} — ${r.status}${r.id === reports[0].id ? ' (latest)' : ''}`)))) : null;

  // ---- preview ---------------------------------------------------------------
  const preview = h('section', { class: 'card', 'aria-labelledby': 'preview-h' },
    h('div', { class: 'card-head' }, h('h2', { id: 'preview-h' }, `Report v${meta.version}`), statusChip(meta.status)),
    h('div', { class: 'actions' }, picker,
      h('a', { class: 'btn btn-sm', href: pdfUrl, download: '' }, 'Download PDF'),
      h('a', { class: 'btn btn-sm', href: jsonUrl, download: '' }, 'Download JSON'),
      h('a', { class: 'btn btn-sm btn-quiet', href: pdfUrl, target: '_blank', rel: 'noopener' }, 'Open PDF in new tab')),
    h('iframe', { class: 'pdf-frame', src: pdfUrl, title: `Report v${meta.version} (${meta.status}) PDF preview` },
      'Your browser cannot display the PDF inline. Use the download link above.'));

  // ---- verification --------------------------------------------------------
  const s = v.summary || {};
  const unresolved = (v.checks || []).filter((c) => c.status !== 'verified').sort((a, b) => Number(b.material) - Number(a.material));
  const verification = h('section', { class: 'card', 'aria-labelledby': 'verif-h' },
    h('div', { class: 'card-head' }, h('h2', { id: 'verif-h' }, 'Verification'),
      v.material_failure ? chip('Material failures', 'bad') : chip('No material failures', 'good')),
    v.material_failure ? alertBox('Material verification failures are unresolved. These statements could not be confirmed against their sources.', 'error') : null,
    h('p', null, `${s.verified ?? 0} of ${s.total_checks ?? 0} checks verified · ${s.failed ?? 0} failed · ${s.material_failures ?? 0} material · ${s.unsupported_findings ?? 0} unsupported findings · ${s.fabricated_authority_refs ?? 0} unknown authority references`),
    h('h3', null, `Unresolved failures (${unresolved.length})`),
    unresolved.length ? h('ul', { class: 'failures' }, unresolved.map((c) => h('li', { class: c.material ? 'material' : '' },
      h('div', { class: 'item-head' }, c.material ? chip('material', 'bad') : chip('non-material', 'muted'), chip(humanize(c.status), c.material ? 'bad' : 'warn'), c.ref ? evidenceChip(c.ref) : null),
      h('p', { class: 'small' }, h('code', null, c.target)), c.detail ? h('p', null, c.detail) : null)))
      : h('p', { class: 'text-good' }, 'None. Every check passed.'),
    v.limitations?.length ? h('details', null, h('summary', null, 'Limitations of verification'), h('ul', { class: 'bullets' }, v.limitations.map((t) => h('li', null, t)))) : null);

  // ---- review form / recorded review ------------------------------------------
  let reviewPanel;
  if (meta.status === 'draft') {
    const name = h('input', { type: 'text', maxlength: '120', value: readName(), required: true, autocomplete: 'name', 'aria-describedby': 'name-err' });
    const note = h('textarea', { rows: '3', maxlength: '2000', placeholder: 'Optional: what you checked, or why you are rejecting.' });
    const ack = h('input', { type: 'checkbox', id: 'ack', onchange: sync });
    const err = h('p', { id: 'name-err', class: 'text-bad small', role: 'alert' });
    const formErr = h('div');
    const approve = h('button', { class: 'btn btn-primary', type: 'button', onclick: () => submit('approve') }, 'Approve');
    const reject = h('button', { class: 'btn btn-danger', type: 'button', onclick: () => submit('reject') }, 'Reject');
    function sync() { approve.disabled = !!v.material_failure && !ack.checked; }
    async function submit(action) {
      replaceChildren(formErr); err.textContent = '';
      if (!name.value.trim()) { err.textContent = 'Enter your name to record this review.'; name.focus(); return; }
      if (action === 'approve' && v.material_failure && !ack.checked) return;
      const verb = action === 'approve' ? 'Approve' : 'Reject';
      if (!confirm(`${verb} report v${meta.version} as "${name.value.trim()}"? This is recorded with a timestamp and cannot be undone.`)) return;
      saveName(name.value.trim());
      approve.disabled = reject.disabled = true;
      try {
        await api.post(caseUrl(id, `/reports/${rid}/review`), {
          action, reviewer: name.value.trim(), note: note.value, acknowledge_verification_failures: action === 'approve' && ack.checked,
        });
        toast(`Report ${action === 'approve' ? 'approved' : 'rejected'}`, 'success');
        navigate(location.pathname + location.search); // reload to show the recorded review
      } catch (e) {
        replaceChildren(formErr, alertBox(e.message));
        approve.disabled = reject.disabled = false; sync();
      }
    }
    reviewPanel = h('section', { class: 'card', 'aria-labelledby': 'review-h' },
      h('h2', { id: 'review-h' }, 'Review this draft'),
      h('p', { class: 'muted' }, 'Approving records that you reviewed this report for completeness and obvious errors. It does not make it legal advice or replace review by a licensed attorney.'),
      h('div', { class: 'field' }, h('label', { for: 'reviewer' }, 'Reviewer name'), (name.id = 'reviewer', name), err),
      field('Note (optional)', note),
      v.material_failure ? h('label', { class: 'check ack' }, ack, h('span', null, 'I acknowledge the unresolved verification failures listed above')) : null,
      formErr,
      h('div', { class: 'actions' }, approve, reject),
      v.material_failure ? h('p', { class: 'muted small' }, 'Approval stays disabled until the acknowledgement is checked. Rejecting does not require it.') : null);
    sync();
  } else {
    reviewPanel = h('section', { class: 'card', 'aria-labelledby': 'review-h' },
      h('h2', { id: 'review-h' }, 'Recorded review'),
      h('dl', { class: 'kv' },
        h('dt', null, 'Decision'), h('dd', null, statusChip(meta.status)),
        h('dt', null, 'Reviewer'), h('dd', null, meta.reviewer || '—'),
        h('dt', null, 'Action'), h('dd', null, meta.reviewer_action || '—'),
        h('dt', null, 'Recorded at'), h('dd', null, fmtDateTime(meta.reviewed_at)),
        h('dt', null, 'Verification failures acknowledged'), h('dd', null, meta.acknowledged_failures ? 'Yes' : 'No'),
        meta.reviewer_note ? [h('dt', null, 'Note'), h('dd', { class: 'prewrap' }, meta.reviewer_note)] : null),
      h('p', { class: 'muted small' }, 'A reviewed report cannot be changed. To get a new draft, run another analysis from the intake screen.'),
      h('div', { class: 'actions' }, h('a', { class: 'btn btn-quiet', href: `/cases/${enc_(id)}` }, 'Back to intake')));
  }

  const provWarn = data.metadata && data.metadata.provider_is_real_inference === false
    ? alertBox('This report was generated with the scripted test provider. Its content is canned test data, not model output.', 'warn') : null;

  replaceChildren(body, statusBanner, provWarn,
    h('div', { class: 'report-layout' },
      h('div', { class: 'col col-wide' }, preview),
      h('div', { class: 'col' }, verification, reviewPanel)));
}
