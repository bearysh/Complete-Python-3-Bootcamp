// Entry point: top bar, provider banner/status chip, and route table.
import { h, replaceChildren, chip } from './dom.js';
import { api } from './api.js';
import { addRoute, setNotFound, startRouter } from './router.js';
import { caseListView } from './views/caselist.js';
import { newCaseView } from './views/newcase.js';
import { intakeView } from './views/intake.js';
import { progressView } from './views/progress.js';
import { reviewView } from './views/review.js';
import { reportView } from './views/report.js';
import { emptyState } from './dom.js';

// ---- provider status (top bar chip + warning banner) --------------------------
function renderHealth(health, error) {
  const chipHost = document.getElementById('provider-chip');
  const banner = document.getElementById('provider-banner');
  const msgs = [];
  let tone = 'neutral', label = 'Checking provider…';
  let severity = null;

  if (error) {
    label = 'Server unreachable'; tone = 'bad';
    msgs.push(error);
    severity = 'bad';
  } else if (health) {
    const p = health.provider || {};
    if (p.configured === false) {
      label = 'No inference provider'; tone = 'bad'; severity = 'bad';
      msgs.push(`Inference provider unavailable${p.error ? ': ' + p.error : '.'} Start Hermes (or your configured local model server) and restart Little Guy Legal. Analysis cannot run until a provider is available.`);
    } else if (p.is_real_inference === false) {
      label = `Test provider: ${p.label || p.provider}`; tone = 'warn'; severity = 'warn';
      msgs.push('TEST PROVIDER ACTIVE — outputs are not model-generated');
    } else {
      label = `${p.label || p.provider}${p.model ? ' · ' + p.model : ''}`; tone = 'good';
    }
    for (const w of health.warnings || []) {
      // The test-provider warning is already covered by the headline above.
      if (/SCRIPTED TEST PROVIDER/i.test(w) && p.is_real_inference === false) continue;
      if (/Inference provider not available/i.test(w) && p.configured === false) continue;
      msgs.push(w);
      if (!severity) severity = 'warn';
    }
  }
  replaceChildren(chipHost, chip(label, tone, 'Inference provider reported by /api/health'));
  chipHost.firstChild.prepend(h('span', { class: 'dot', 'aria-hidden': 'true' }));
  if (msgs.length) {
    banner.hidden = false;
    banner.className = `provider-banner banner-${severity}`;
    replaceChildren(banner, h('div', { class: 'banner-inner' },
      h('strong', null, msgs[0]), msgs.slice(1).map((m) => h('div', null, m))));
  } else {
    banner.hidden = true;
  }
}

async function refreshHealth() {
  try { renderHealth(await api.get('/api/health')); }
  catch (err) { renderHealth(null, err.message); }
}

function buildTopbar() {
  const bar = document.getElementById('topbar');
  replaceChildren(bar,
    h('div', { class: 'topbar-inner' },
      h('a', { class: 'brand', href: '/' },
        h('span', { class: 'brand-mark', 'aria-hidden': 'true' }, 'L'),
        h('span', { class: 'brand-name' }, 'Little Guy Legal')),
      h('span', { class: 'badge-ai' }, 'AI-assisted research — for attorney review'),
      h('span', { class: 'spacer' }),
      h('span', { id: 'provider-chip' }, chip('Checking provider…', 'neutral'))));
}

// ---- boot ---------------------------------------------------------------------
buildTopbar();
refreshHealth();
setInterval(refreshHealth, 60000);

addRoute('/', caseListView);
addRoute('/cases/new', newCaseView);
addRoute('/cases/:id', intakeView);
addRoute('/cases/:id/progress', progressView);
addRoute('/cases/:id/review', reviewView);
addRoute('/cases/:id/report', reportView);
setNotFound((root) => {
  root.appendChild(h('div', { class: 'page narrow' },
    emptyState('Page not found', 'That address does not match a screen in this app.'),
    h('p', null, h('a', { class: 'btn', href: '/' }, 'Back to cases'))));
});
startRouter(document.getElementById('main'));
