// M365 Manager · Exchange-RBAC
// Lesen über benannte Abfragen der RBAC-PowerShell; jede Änderung wird als PowerShell-Befehl angezeigt
// und erst nach Bestätigung genau so ausgeführt.
(() => {
  'use strict';

  const host = window.chrome && window.chrome.webview;
  const post = msg => host && host.postMessage(msg);
  const $ = id => document.getElementById(id);
  const el = (tag, props = {}, ...children) => {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === 'class') e.className = v;
      else if (k === 'html') e.innerHTML = v;
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else if (v !== undefined && v !== null && v !== false) e.setAttribute(k, v === true ? '' : v);
    }
    for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) e.append(c instanceof Node ? c : document.createTextNode(String(c)));
    return e;
  };
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  const q = s => "'" + String(s ?? '').replace(/'/g, "''") + "'";            // PowerShell-String in einfachen Anführungszeichen
  const qd = s => '"' + String(s ?? '').replace(/[`"$]/g, c => '`' + c) + '"';  // PowerShell-String in doppelten Anführungszeichen

  // ---------------------------------------------------------------- Anfragen an die App
  const pending = new Map();
  let counter = 0;
  function request(msg) {
    return new Promise((resolve, reject) => {
      const id = ++counter;
      pending.set(id, m => (m.ok ? resolve(m.data) : reject(new Error(m.error || 'Fehler'))));
      post({ ...msg, id });
    });
  }
  const call = (op, args) => request({ t: 'call', op, args: args || {} });
  const runScript = script => request({ t: 'run', script });

  let busyCount = 0;
  async function busy(text, fn) {
    busyCount++;
    $('busyText').textContent = text;
    $('busy').hidden = false;
    try { return await fn(); }
    finally { if (--busyCount === 0) $('busy').hidden = true; }
  }
  let toastTimer = 0;
  function toast(text, bad) {
    const t = $('toast');
    t.textContent = text;
    t.className = bad ? 'bad' : '';
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, bad ? 9000 : 3500);
  }

  // ---------------------------------------------------------------- Zwischenspeicher
  const cache = {};
  async function load(key, op, text, force) {
    if (!force && cache[key]) return cache[key];
    const data = await busy(text, () => call(op));
    cache[key] = Array.isArray(data) ? data : (data ?? []);
    return cache[key];
  }
  const invalidate = (...keys) => keys.forEach(k => delete cache[k]);

  // ---------------------------------------------------------------- Dialoge
  function closeModal() { $('modal').hidden = true; $('dialog').replaceChildren(); }
  function openModal(title, body, buttons) {
    const d = $('dialog');
    d.replaceChildren(el('div', { class: 'dhead' }, title), el('div', { class: 'dbody' }, body), el('div', { class: 'dfoot' }, buttons));
    $('modal').hidden = false;
    return d;
  }
  function confirmBox(title, html, okText = 'OK', danger = false) {
    return new Promise(resolve => {
      openModal(title, el('div', { html }), [
        el('button', { class: 'outline', onclick: () => { closeModal(); resolve(false); } }, 'Abbrechen'),
        el('button', { class: danger ? 'danger' : 'primary', onclick: () => { closeModal(); resolve(true); } }, okText),
      ]);
    });
  }

  /**
   * Befehl zeigen → bestätigen → ausführen. Liefert true, wenn ohne Fehler ausgeführt.
   * Der Befehl kann vorher angepasst werden; ausgeführt wird genau der Text im Feld.
   */
  function preview(title, script, { explain = '', danger = false, okText = 'Ausführen' } = {}) {
    return new Promise(resolve => {
      const area = el('textarea', { rows: Math.min(24, script.split('\n').length + 1), spellcheck: 'false', style: 'width:100%' });
      area.value = script;
      const out = el('div');
      const body = el('div', {},
        explain ? el('div', { class: 'note' + (danger ? ' warn' : ''), html: explain }) : null,
        el('label', {}, 'Dieser PowerShell-Befehl wird ausgeführt (anpassbar):'),
        area, out);
      let ran = false;
      const run = el('button', { class: danger ? 'danger' : 'primary' }, okText);
      const close = el('button', { class: 'outline', onclick: () => { closeModal(); resolve(ran); } }, 'Abbrechen');
      run.onclick = async () => {
        run.disabled = true; close.disabled = true; area.readOnly = true;
        out.replaceChildren(el('div', { class: 'note' }, 'Wird ausgeführt …'));
        try {
          const text = await runScript(area.value);
          const failed = /^FEHLER:/m.test(text);
          ran = !failed;
          out.replaceChildren(el('div', { class: 'note ' + (failed ? 'bad' : 'ok') }, failed ? 'Teilweise fehlgeschlagen – siehe Ausgabe.' : '✓ Ausgeführt.'),
            text ? el('pre', { class: 'code out' }, text) : null);
        } catch (e) {
          out.replaceChildren(el('div', { class: 'note bad' }, 'Fehlgeschlagen: ' + e.message));
        }
        close.disabled = false;
        close.textContent = 'Schließen';
        run.hidden = true;
      };
      openModal(title, body, [
        el('button', { class: 'outline', onclick: () => { post({ t: 'copy', text: area.value }); toast('Befehl kopiert'); } }, 'Kopieren'),
        el('button', { class: 'outline', onclick: () => { post({ t: 'toeditor', name: title, code: area.value }); toast('Im Skript-Editor geöffnet'); } }, 'In Skript-Editor'),
        el('span', { class: 'grow' }), close, run,
      ]);
    });
  }

  // ---------------------------------------------------------------- Tabelle mit Filter, Sortierung, Auswahl, CSV
  function table({ columns, rows, onSelect, empty = 'Keine Einträge.', selectedKey, key }) {
    let sortCol = null, desc = false, selected = selectedKey ?? null;
    const wrap = el('div', { class: 'tablewrap' });
    const render = () => {
      let list = rows.slice();
      if (sortCol) {
        const c = columns[sortCol];
        const v = r => (c.sort ? c.sort(r) : (c.text ? c.text(r) : r[c.key])) ?? '';
        list.sort((a, b) => { const x = v(a), y = v(b); const r = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y), 'de', { sensitivity: 'base', numeric: true }); return desc ? -r : r; });
      }
      if (!list.length) { wrap.replaceChildren(el('div', { class: 'empty' }, empty)); return; }
      const head = el('tr', {}, columns.map((c, i) => el('th', {
        class: sortCol === i ? 'sorted' + (desc ? ' desc' : '') : '',
        onclick: () => { if (sortCol === i) desc = !desc; else { sortCol = i; desc = false; } render(); },
      }, c.title)));
      const body = list.map(r => {
        const tr = el('tr', { class: 'row' + (key && selected === key(r) ? ' sel' : '') }, columns.map(c => {
          const td = el('td', { title: c.text ? c.text(r) : (r[c.key] ?? '') });
          const v = c.render ? c.render(r) : (c.text ? c.text(r) : r[c.key]);
          if (v instanceof Node || Array.isArray(v)) td.append(...[v].flat()); else td.textContent = v ?? '';
          return td;
        }));
        tr.onclick = () => { if (key) selected = key(r); wrap.querySelectorAll('tr.sel').forEach(x => x.classList.remove('sel')); tr.classList.add('sel'); onSelect && onSelect(r); };
        return tr;
      });
      wrap.replaceChildren(el('table', {}, el('thead', {}, head), el('tbody', {}, body)));
    };
    render();
    wrap.toCsv = () => {
      const cell = s => { s = String(s ?? ''); return /[;"\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
      return [columns.map(c => cell(c.title)).join(';'), ...rows.map(r => columns.map(c => cell(c.text ? c.text(r) : r[c.key])).join(';'))].join('\r\n');
    };
    return wrap;
  }
  const matches = (r, text, fields) => !text || text.toLowerCase().split(/\s+/).filter(Boolean)
    .every(w => fields.some(f => String(typeof f === 'function' ? f(r) : r[f] ?? '').toLowerCase().includes(w)));
  const badge = (text, kind = '') => el('span', { class: 'badge ' + kind }, text);

  /** Gerüst einer Ansicht: Kopf, Werkzeugleiste (Suche, Chips, Knöpfe), Tabelle, Detailbereich. */
  function viewFrame({ title, sub, chips = [], chip, onChip, search, onSearch, buttons = [] }) {
    const main = $('main');
    const details = el('aside', { class: 'details', hidden: true });
    const tableSlot = el('div', { style: 'flex:1;min-width:0;display:flex' });
    const searchBox = el('input', { class: 'search', placeholder: 'Filtern …', value: search || '' });
    searchBox.addEventListener('input', () => onSearch(searchBox.value));
    main.replaceChildren(
      el('div', { class: 'head' }, el('div', {}, el('h1', {}, title), sub ? el('div', { class: 'sub', html: sub }) : null)),
      el('div', { class: 'toolbar' }, searchBox,
        chips.map(([k, label]) => el('button', { class: 'chip' + (chip === k ? ' on' : ''), onclick: () => onChip(k) }, label)),
        el('span', { style: 'flex:1' }), buttons),
      el('div', { class: 'body' }, tableSlot, details));
    return { tableSlot, details, searchBox };
  }
  function showDetails(details, ...content) { details.hidden = false; details.replaceChildren(...content.flat(Infinity).filter(x => x !== null && x !== undefined && x !== false)); }
  const kv = pairs => el('div', { class: 'kv' }, pairs.filter(p => p[1] !== undefined && p[1] !== null && p[1] !== '').flatMap(([k, v]) => [el('div', {}, k), el('div', {}, v)]));

  function exportCsv(name, wrap) { post({ t: 'export', name, csv: wrap.toCsv() }); }

  // ---------------------------------------------------------------- Navigation
  let current = 'apps';
  const state = {};
  function go(view) {
    current = view;
    document.querySelectorAll('#nav button[data-view]').forEach(b => b.classList.toggle('active', b.dataset.view === view));
    views[view]().catch(e => showError(e));
  }
  function showError(e) {
    $('main').replaceChildren(el('div', { class: 'head' }, el('div', {},
      el('h1', {}, 'Das hat nicht geklappt'),
      el('div', { class: 'note bad', style: 'margin-top:12px;max-width:820px' }, e.message || String(e)),
      el('div', { class: 'sub' }, 'Tipp: Fehlt eine Exchange-Rolle (mindestens „View-Only Organization Management“, für Änderungen „Organization Management“) oder ist eine PIM-Rolle noch nicht aktiv? Nach einer Aktivierung „↻ Neu verbinden“.'),
      el('div', { style: 'margin-top:12px' }, el('button', { class: 'primary', onclick: () => go(current) }, 'Erneut versuchen')))));
  }

  // ================================================================ Anwendungen (RBAC for Applications)
  const appStatus = a => {
    const wide = (a.grants || []).length > 0, scoped = (a.rbac || []).length > 0;
    if (wide && scoped) return ['gemischt', 'warn', 'Hat RBAC-Zuweisungen, aber zusätzlich noch tenantweite Entra-Rechte – damit gilt weiterhin der Zugriff auf ALLE Postfächer.'];
    if (wide) return ['tenantweit', 'bad', 'Die App darf per Entra-Anwendungsberechtigung auf alle Postfächer zugreifen.'];
    if (scoped) return ['eingeschränkt', 'ok', 'Nur per RBAC for Applications berechtigt – Zugriff nur innerhalb der zugewiesenen Bereiche.'];
    return ['ohne Postfachrechte', '', ''];
  };

  async function viewApps(force) {
    const apps = await load('apps', 'apps', 'Lese Anwendungen mit Postfach-Berechtigungen (Entra + Exchange) …', force);
    state.apps ??= { chip: 'all', search: '' };
    const s = state.apps;
    const f = viewFrame({
      title: 'Anwendungen',
      sub: 'Apps mit Anwendungsberechtigungen auf Postfächer (z. B. Mail.ReadWrite, Mail.Send, Calendars.ReadWrite). ' +
        '<b>Tenantweit</b> = Zugriff auf alle Postfächer. Mit <b>RBAC for Applications</b> lässt sich das auf eine Gruppe von Postfächern beschränken.',
      chips: [['all', 'Alle'], ['wide', 'Tenantweit'], ['mixed', 'Gemischt'], ['scoped', 'Eingeschränkt']], chip: s.chip,
      onChip: k => { s.chip = k; viewApps(); }, search: s.search, onSearch: v => { s.search = v; refresh(); },
      buttons: [
        el('button', { class: 'primary', onclick: () => restrictWizard(null) }, '＋ App auf Postfächer einschränken …'),
        el('button', { class: 'outline', onclick: () => viewApps(true) }, '↻'),
      ],
    });
    const refresh = () => {
      const rows = apps.filter(a => matches(a, s.search, ['displayName', 'appId', r => (r.grants || []).map(g => g.permission).join(' ')]))
        .filter(a => s.chip === 'all' || appStatus(a)[0] === ({ wide: 'tenantweit', mixed: 'gemischt', scoped: 'eingeschränkt' })[s.chip]);
      f.tableSlot.replaceChildren(table({
        rows, key: a => a.appId, empty: 'Keine Apps mit Postfach-Berechtigungen gefunden.',
        columns: [
          { title: 'Anwendung', key: 'displayName' },
          { title: 'Status', text: a => appStatus(a)[0], render: a => { const [t, k, tip] = appStatus(a); const b = badge(t, k); b.title = tip; return b; } },
          { title: 'Entra-Rechte (tenantweit)', text: a => (a.grants || []).map(g => g.permission).join(', '), render: a => (a.grants || []).map(g => badge(g.permission, 'bad')) },
          { title: 'RBAC (eingeschränkt)', text: a => (a.rbac || []).map(r => r.role.replace(/^Application /, '')).join(', '), render: a => (a.rbac || []).map(r => badge(r.role.replace(/^Application /, '') + (r.scope ? ' · ' + r.scope : ''), 'ok')) },
          { title: 'App-ID', key: 'appId' },
        ],
        onSelect: a => appDetails(f.details, a),
      }));
    };
    refresh();
  }

  function appDetails(details, a) {
    const [status, kind, tip] = appStatus(a);
    showDetails(details,
      el('h2', {}, a.displayName), badge(status, kind), el('div', { class: 'muted', style: 'margin-top:6px' }, tip),
      el('h3', {}, 'Kennungen'),
      kv([['App-ID', a.appId], ['Objekt-ID', a.objectId], ['In Exchange', a.exoIdentity || 'noch nicht angelegt'], ['Hersteller', a.ownTenant ? 'eigener Tenant' : 'fremder Tenant (Multi-Tenant-App)']]),
      el('h3', {}, 'Tenantweite Entra-Rechte'),
      (a.grants || []).length ? el('ul', { class: 'list' }, a.grants.map(g => el('li', {}, badge(g.permission, 'bad'), el('span', { class: 'grow muted' }, g.resource))))
        : el('div', { class: 'muted' }, 'Keine – gut.'),
      el('h3', {}, 'RBAC-Zuweisungen (Exchange)'),
      (a.rbac || []).length ? el('ul', { class: 'list' }, a.rbac.map(r => el('li', {}, el('span', { class: 'grow' }, r.role, el('div', { class: 'muted' }, r.scope ? 'Bereich: ' + r.scope : 'ganze Organisation')), r.enabled ? null : badge('deaktiviert', 'warn'),
        el('button', { class: 'small danger', onclick: async () => { if (await preview('Zuweisung entfernen', 'Remove-ManagementRoleAssignment -Identity ' + q(r.name) + ' -Confirm:$false', { danger: true, okText: 'Entfernen' })) { invalidate('apps', 'assignments'); viewApps(true); } } }, 'Entfernen'))))
        : el('div', { class: 'muted' }, 'Keine.'),
      (a.policies || []).length ? [el('h3', {}, 'Alte Application Access Policies'),
        el('div', { class: 'note warn' }, 'Diese App hat noch eine Application Access Policy (Vorgänger von RBAC for Applications). Microsoft empfiehlt, nach der Umstellung auf RBAC die alte Richtlinie zu entfernen.'),
        el('ul', { class: 'list' }, a.policies.map(p => el('li', {}, el('span', { class: 'grow' }, p.restriction + ' · ' + p.scope),
          el('button', { class: 'small danger', onclick: async () => { if (await preview('Application Access Policy entfernen', 'Remove-ApplicationAccessPolicy -Identity ' + q(p.identity) + ' -Confirm:$false', { danger: true, okText: 'Entfernen' })) viewApps(true); } }, 'Entfernen'))))] : null,
      el('div', { class: 'actions' },
        el('button', { class: 'primary', onclick: () => restrictWizard(a) }, (a.rbac || []).length ? 'Einschränkung bearbeiten …' : 'Auf Postfächer einschränken …'),
        el('button', { class: 'outline', disabled: !a.exoIdentity, title: a.exoIdentity ? '' : 'Erst einschränken – dann ist die App in Exchange angelegt', onclick: () => testDialog(a) }, 'Zugriff testen …'),
        (a.grants || []).length && (a.rbac || []).length ? el('button', { class: 'danger', onclick: () => removeGrants(a) }, 'Tenantweite Rechte entfernen …') : null));
  }

  // Graph-/EWS-Recht → Exchange-Anwendungsrolle
  function roleFor(permission, appRoles) {
    const names = new Set(appRoles.map(r => r.name));
    const map = { 'full_access_as_app': 'Application EWS.AccessAsApp', 'Mail.ReadBasic.All': 'Application Mail.ReadBasic' };
    const candidate = map[permission] || 'Application ' + permission;
    return names.has(candidate) ? candidate : null;
  }

  async function restrictWizard(app) {
    const appRoles = await load('appRoles', 'appRoles', 'Lese Exchange-Anwendungsrollen …');
    const scopes = await load('scopes', 'scopes', 'Lese Bereiche …');
    const w = {
      app, step: app ? 1 : 0,
      roles: new Set(app ? (app.grants || []).map(g => roleFor(g.permission, appRoles)).filter(Boolean) : []),
      mode: 'group', group: null, scopeName: '', existingScope: '', au: '',
    };
    if (app && !(app.grants || []).length) (app.rbac || []).forEach(r => w.roles.add(r.role));
    const stepNames = ['App wählen', 'Rechte', 'Postfächer', 'Befehle', 'Testen'];

    const render = () => {
      const steps = el('div', { class: 'steps' }, stepNames.map((n, i) => el('span', { class: i === w.step ? 'on' : i < w.step ? 'done' : '' }, (i < w.step ? '✓ ' : (i + 1) + '. ') + n)));
      const body = el('div', {}, steps);
      const back = el('button', { class: 'outline', onclick: () => { w.step--; render(); } }, '‹ Zurück');
      const next = el('button', { class: 'primary' }, 'Weiter ›');
      back.disabled = w.step === 0 || (w.step === 1 && !!app);
      const foot = [el('button', { class: 'outline', onclick: closeModal }, 'Schließen'), el('span', { class: 'grow' }), back, next];

      if (w.step === 0) {
        body.append(el('div', { class: 'note' }, 'Unternehmensanwendung (Service Principal) suchen – Name oder App-ID, z. B. „Monitor“.'));
        const input = el('input', { placeholder: 'Name oder App-ID …', style: 'width:100%' });
        const pick = el('div', { class: 'pick' });
        let timer = 0;
        input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(async () => {
          if (input.value.trim().length < 2) { pick.replaceChildren(); return; }
          try {
            const found = await call('findEntraApps', { text: input.value.trim() });
            pick.replaceChildren(...(found.length ? found : []).map(f => el('div', { class: w.app && w.app.appId === f.appId ? 'sel' : '', onclick: () => {
              const known = (cache.apps || []).find(x => x.appId === f.appId);
              w.app = known || { ...f, grants: [], rbac: [], policies: [] };
              w.roles = new Set((w.app.grants || []).map(g => roleFor(g.permission, appRoles)).filter(Boolean));
              render();
            } }, f.displayName, el('div', { class: 'muted mono' }, f.appId))));
            if (!found.length) pick.replaceChildren(el('div', { class: 'muted' }, 'Nichts gefunden.'));
          } catch (e) { pick.replaceChildren(el('div', { class: 'muted' }, e.message)); }
        }, 350); });
        body.append(input, pick, w.app ? el('div', { class: 'note ok' }, 'Gewählt: ', el('b', {}, w.app.displayName), ' (' + w.app.appId + ')') : null);
        next.disabled = !w.app;
        next.onclick = () => { w.step = 1; render(); };
        setTimeout(() => input.focus(), 0);
      }

      if (w.step === 1) {
        const a = w.app;
        body.append(el('div', {}, el('b', {}, a.displayName), el('span', { class: 'muted mono' }, '  ' + a.appId)));
        if ((a.grants || []).length) {
          body.append(el('div', { class: 'note bad' }, 'Diese App hat aktuell tenantweit: ', a.grants.map(g => badge(g.permission, 'bad')),
            el('div', { style: 'margin-top:6px' }, 'Für jedes Recht wird unten die passende Exchange-Anwendungsrolle vorgeschlagen – diese gilt dann nur für die gewählten Postfächer.')));
          const unmapped = a.grants.filter(g => !roleFor(g.permission, appRoles));
          if (unmapped.length) body.append(el('div', { class: 'note warn' }, 'Ohne RBAC-Gegenstück (bleibt tenantweit, falls nicht in Entra entfernt): ' + unmapped.map(g => g.permission).join(', ')));
        } else {
          body.append(el('div', { class: 'note' }, 'Keine tenantweiten Postfach-Rechte gefunden. Wähle die Rollen, die die App für die ausgewählten Postfächer bekommen soll.'));
        }
        body.append(el('label', {}, 'Exchange-Anwendungsrollen (nur für die gewählten Postfächer):'));
        body.append(el('div', { class: 'checks' }, appRoles.map(r => {
          const cb = el('input', { type: 'checkbox' });
          cb.checked = w.roles.has(r.name);
          cb.onchange = () => { cb.checked ? w.roles.add(r.name) : w.roles.delete(r.name); next.disabled = !w.roles.size; };
          return el('label', { title: r.description }, cb, r.name.replace(/^Application /, ''), el('span', { class: 'muted' }, ' – ' + (r.description || '').slice(0, 90)));
        })));
        next.disabled = !w.roles.size;
        next.onclick = () => { w.step = 2; render(); };
      }

      if (w.step === 2) {
        const opt = (value, title, desc) => {
          const r = el('input', { type: 'radio', name: 'mode' });
          r.checked = w.mode === value;
          r.onchange = () => { w.mode = value; render(); };
          return el('label', { class: 'opt' }, r, el('div', {}, el('div', { class: 't' }, title), el('div', { class: 'muted' }, desc)));
        };
        body.append(
          opt('group', 'Mitglieder einer Gruppe (empfohlen)', 'Z. B. eine Sicherheits- oder E-Mail-aktivierte Gruppe „Monitor-Postfächer“. Zählt nur direkte Mitglieder – keine verschachtelten Gruppen.'),
          opt('scope', 'Vorhandener Bereich', 'Einen bereits angelegten Management Scope verwenden.'),
          opt('au', 'Verwaltungseinheit (Entra)', 'Alle Postfächer einer Administrative Unit – auch dynamische AUs möglich.'));

        if (w.mode === 'group') {
          const input = el('input', { placeholder: 'Gruppe suchen …', style: 'width:100%' });
          const pick = el('div', { class: 'pick' });
          let timer = 0;
          input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(async () => {
            if (input.value.trim().length < 2) return;
            try {
              const found = await call('findGroups', { text: input.value.trim() });
              pick.replaceChildren(...found.map(g => el('div', { class: w.group && w.group.dn === g.dn ? 'sel' : '', onclick: () => {
                w.group = g;
                if (!w.scopeName) w.scopeName = ('App-' + w.app.displayName + '-Postfaecher').replace(/[^\w.-]+/g, '-').replace(/-+/g, '-');
                render();
              } }, g.displayName || g.name, el('div', { class: 'muted' }, g.type + ' · ' + g.members + ' Mitglieder' + (g.smtp ? ' · ' + g.smtp : '')))));
              if (!found.length) pick.replaceChildren(el('div', { class: 'muted' }, 'Keine Gruppe gefunden.'));
            } catch (e) { pick.replaceChildren(el('div', { class: 'muted' }, e.message)); }
          }, 350); });
          const name = el('input', { value: w.scopeName, style: 'width:100%' });
          name.oninput = () => { w.scopeName = name.value; next.disabled = !(w.group && w.scopeName.trim()); };
          body.append(el('label', {}, 'Gruppe'), input, pick);
          if (w.group) {
            const prev = el('div');
            body.append(el('div', { class: 'note ok' }, 'Gruppe: ', el('b', {}, w.group.displayName || w.group.name), ' · ' + w.group.members + ' Mitglieder ',
              el('button', { class: 'small outline', onclick: () => previewMembers(groupFilter(w.group), prev) }, 'Postfächer im Bereich anzeigen')), prev,
              el('label', {}, 'Name des neuen Bereichs (Management Scope)'), name);
          }
          next.disabled = !(w.group && w.scopeName.trim());
        } else if (w.mode === 'scope') {
          const sel = el('select', { style: 'width:100%' }, el('option', { value: '' }, '– Bereich wählen –'),
            scopes.filter(s => s.type === 'RecipientScope').map(s => el('option', { value: s.name, selected: s.name === w.existingScope }, s.name + (s.filter ? '  ·  ' + s.filter : ''))));
          sel.onchange = () => { w.existingScope = sel.value; render(); };
          const prev = el('div');
          const chosen = scopes.find(s => s.name === w.existingScope);
          body.append(el('label', {}, 'Bereich'), sel,
            chosen && chosen.filter ? el('div', { style: 'margin-top:6px' }, el('button', { class: 'small outline', onclick: () => previewMembers(chosen.filter, prev) }, 'Postfächer im Bereich anzeigen'), prev) : null);
          next.disabled = !w.existingScope;
        } else {
          const id = el('input', { value: w.au, placeholder: 'Objekt-ID der Verwaltungseinheit (GUID)', style: 'width:100%' });
          id.oninput = () => { w.au = id.value.trim(); next.disabled = !/^[0-9a-f-]{36}$/i.test(w.au); };
          body.append(el('label', {}, 'Verwaltungseinheit'), id, el('div', { class: 'muted', style: 'margin-top:6px' }, 'Zu finden im Entra Admin Center unter Rollen und Administratoren → Verwaltungseinheiten → Objekt-ID.'));
          next.disabled = !/^[0-9a-f-]{36}$/i.test(w.au);
        }
        next.onclick = () => { w.step = 3; render(); };
      }

      if (w.step === 3) {
        const a = w.app;
        const lines = [];
        lines.push('# App: ' + a.displayName);
        if (!a.exoIdentity) {
          lines.push('# 1. App in Exchange Online bekannt machen');
          lines.push('New-ServicePrincipal -AppId ' + q(a.appId) + ' -ObjectId ' + q(a.objectId) + ' -DisplayName ' + q(a.displayName));
        }
        let scopeArg;
        if (w.mode === 'group') {
          lines.push('', '# 2. Bereich: nur die direkten Mitglieder der Gruppe „' + (w.group.displayName || w.group.name) + '“');
          lines.push('New-ManagementScope -Name ' + q(w.scopeName.trim()) + ' -RecipientRestrictionFilter ' + qd(groupFilter(w.group)));
          scopeArg = '-CustomResourceScope ' + q(w.scopeName.trim());
        } else if (w.mode === 'scope') {
          scopeArg = '-CustomResourceScope ' + q(w.existingScope);
        } else {
          scopeArg = '-RecipientAdministrativeUnitScope ' + q(w.au);
        }
        lines.push('', '# 3. Rollen nur für diesen Bereich zuweisen');
        const existing = new Set((a.rbac || []).map(r => r.role));
        for (const role of [...w.roles].sort()) {
          if (existing.has(role)) lines.push('# ' + role + ': bereits zugewiesen (' + ((a.rbac || []).find(r => r.role === role).scope || 'ganze Organisation') + ')');
          else lines.push('New-ManagementRoleAssignment -App ' + q(a.objectId) + ' -Role ' + q(role) + ' ' + scopeArg);
        }
        const script = lines.join('\n');
        body.append(
          el('div', { class: 'note' }, 'Diese Befehle legen die Einschränkung in Exchange an. ', el('b', {}, 'Noch ändert sich am Zugriff nichts'),
            ', solange die App ihre tenantweiten Entra-Rechte behält – die werden im letzten Schritt entfernt, wenn der Test passt.'),
          el('pre', { class: 'code' }, script),
          el('div', { class: 'muted' }, 'Exchange übernimmt neue Zuweisungen mit Verzögerung (meist 30 Minuten, bis zu 2 Stunden).'));
        next.textContent = 'Befehle ausführen …';
        next.onclick = async () => {
          if (await preview('App einschränken: ' + a.displayName, script, { okText: 'Ausführen' })) {
            invalidate('apps', 'assignments', 'scopes');
            const fresh = (await load('apps', 'apps', 'Lese Anwendungen …', true)).find(x => x.appId === a.appId);
            if (fresh) w.app = fresh;
            w.step = 4;
          }
          render();
        };
      }

      if (w.step === 4) {
        const a = w.app;
        body.append(el('div', { class: 'note ok' }, '✓ Die RBAC-Zuweisungen sind angelegt.'));
        body.append(testPanel(a));
        if ((a.grants || []).length) {
          body.append(el('div', { class: 'note warn', style: 'margin-top:14px' },
            el('b', {}, 'Letzter Schritt: tenantweite Entra-Rechte entfernen. '),
            'Entra-Rechte und RBAC addieren sich – solange ' + a.grants.map(g => g.permission).join(', ') + ' in Entra erteilt ist, hat die App weiter Zugriff auf alle Postfächer. ',
            'Erst entfernen, wenn der Test oben für die Postfächer der Gruppe „Im Bereich: ja“ zeigt.'),
            el('button', { class: 'danger', onclick: () => removeGrants(a, ok => { if (ok) w.app.grants = []; render(); }) }, 'Tenantweite Rechte entfernen …'));
        } else {
          body.append(el('div', { class: 'note ok', style: 'margin-top:14px' }, 'Keine tenantweiten Postfach-Rechte mehr – die App ist auf den Bereich beschränkt.'));
        }
        next.textContent = 'Fertig';
        next.onclick = () => { closeModal(); viewApps(true); };
      }

      openModal('App auf Postfächer einschränken', body, foot);
    };
    render();
  }

  // Filter: direkte Mitglieder einer Gruppe (Distinguished Name, Apostroph verdoppelt)
  const groupFilter = g => "MemberOfGroup -eq '" + String(g.dn).replace(/'/g, "''") + "'";

  async function previewMembers(filter, slot) {
    try {
      const res = await busy('Ermittle Empfänger im Bereich …', () => call('previewFilter', { filter }));
      const items = res.items || [];
      slot.replaceChildren(el('div', { class: 'note' }, items.length + (res.truncated ? '+' : '') + ' Empfänger im Bereich' + (res.truncated ? ' (Anzeige auf 500 begrenzt)' : '') + ':',
        el('div', { class: 'pick' }, items.map(i => el('div', {}, i.name, el('span', { class: 'muted' }, '  ' + i.smtp + ' · ' + i.type))))));
    } catch (e) { slot.replaceChildren(el('div', { class: 'note bad' }, e.message)); }
  }

  function testPanel(a) {
    const box = el('div');
    const input = el('input', { placeholder: 'Postfach (E-Mail-Adresse) – eins innerhalb und eins außerhalb der Gruppe testen', style: 'width:100%' });
    const out = el('div');
    const run = async () => {
      if (!input.value.trim()) return;
      try {
        const rows = await busy('Prüfe Zugriff …', () => call('testApp', { identity: a.exoIdentity || a.objectId, resource: input.value.trim() }));
        out.append(el('div', { class: 'note' }, el('b', {}, input.value.trim()), rows.length ? el('table', {}, el('tbody', {}, rows.map(r => el('tr', {},
          el('td', {}, r.role), el('td', {}, r.inScope ? badge('Im Bereich: ja', 'ok') : badge('Im Bereich: nein', 'bad')), el('td', { class: 'muted' }, r.scope || r.scopeType))))) : el('div', { class: 'muted' }, 'Keine RBAC-Rolle für diese App.')));
      } catch (e) { out.append(el('div', { class: 'note bad' }, input.value.trim() + ': ' + e.message)); }
    };
    input.addEventListener('keydown', e => { if (e.key === 'Enter') run(); });
    box.append(el('h3', { style: 'font-size:12px;text-transform:uppercase;color:var(--muted);margin:14px 0 6px' }, 'Zugriff testen (Test-ServicePrincipalAuthorization)'),
      el('div', { style: 'display:flex;gap:8px' }, input, el('button', { class: 'outline', onclick: run }, 'Testen')), out,
      el('div', { class: 'muted', style: 'margin-top:6px' }, 'Prüft die RBAC-Zuweisungen in Exchange. Tenantweite Entra-Rechte berücksichtigt der Test nicht.'));
    return box;
  }

  function testDialog(a) {
    openModal('Zugriff testen: ' + a.displayName, testPanel(a), [el('button', { class: 'primary', onclick: closeModal }, 'Schließen')]);
  }

  /**
   * Tenantweite Entra-Rechte entfernen – bewusst NICHT per PowerShell, sondern im Entra-Portal mit der Portal-Anmeldung.
   * Der RBAC-Bereich fordert dadurch nie zusätzliche Graph-Berechtigungen an und ändert in Entra selbst nichts.
   */
  function removeGrants(a, after) {
    const url = 'https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Permissions/objectId/' +
      encodeURIComponent(a.objectId) + '/appId/' + encodeURIComponent(a.appId);
    const grantList = grants => el('ul', { class: 'list' }, grants.map(g => el('li', {}, badge(g.permission, 'bad'), el('span', { class: 'grow muted' }, g.resource))));
    const status = el('div');
    let removed = false;
    const finish = () => { closeModal(); if (removed) invalidate('apps'); if (after) after(removed); else if (removed) viewApps(true); };
    const check = el('button', { class: 'outline' }, 'Erneut prüfen');
    const done = el('button', { class: 'primary', onclick: finish }, 'Schließen');
    check.onclick = async () => {
      check.disabled = true;
      status.replaceChildren(el('div', { class: 'note' }, 'Prüfe die Entra-Rechte …'));
      try {
        invalidate('apps');
        const fresh = (await load('apps', 'apps', 'Prüfe Entra-Rechte …', true)).find(x => x.appId === a.appId);
        const left = fresh ? (fresh.grants || []) : [];
        if (!left.length) {
          removed = true;
          a.grants = [];
          status.replaceChildren(el('div', { class: 'note ok' }, '✓ Keine tenantweiten Postfach-Rechte mehr. Die App erreicht jetzt nur noch die Postfächer ihrer RBAC-Bereiche (wirksam nach bis zu 2 Stunden).'));
        } else {
          status.replaceChildren(el('div', { class: 'note warn' }, 'Noch in Entra erteilt:'), grantList(left));
        }
      } catch (e) {
        status.replaceChildren(el('div', { class: 'note bad' }, 'Prüfen fehlgeschlagen: ' + e.message));
      }
      check.disabled = false;
    };
    openModal('Tenantweite Rechte entfernen: ' + a.displayName, el('div', {},
      el('div', { class: 'note' }, el('b', {}, 'Im Entra-Portal, nicht per PowerShell. '),
        'So fordert die App keine zusätzlichen Graph-Berechtigungen an und ändert in Entra nichts selbst. Du entfernst die Rechte mit deiner Portal-Anmeldung, nötig ist dafür die Rolle Cloudanwendungsadministrator.'),
      el('ol', { style: 'padding-left:20px;line-height:1.8;margin:12px 0' },
        el('li', {}, el('button', { class: 'small primary', onclick: () => { post({ t: 'portal', url }); toast('Entra-Portal im Browser-Tab geöffnet'); } }, 'Im Entra-Portal öffnen'),
          ' Unternehmensanwendungen → ' + a.displayName + ' → Berechtigungen.'),
        el('li', {}, 'Reiter „Administratorzustimmung“: bei jeder dieser Berechtigungen „…“ → „Berechtigung widerrufen“:', grantList(a.grants || [])),
        el('li', {}, 'Andere Berechtigungen der App nicht anfassen. Danach über den Tab „Exchange-RBAC“ hierher zurückkehren und „Erneut prüfen“ wählen.')),
      el('div', { class: 'note warn', html: '<b>Danach greift nur noch RBAC.</b> Bis Exchange die RBAC-Zuweisungen übernommen hat (bis zu 2 Stunden), kann die App kurz gar keinen Zugriff haben, am besten also außerhalb der Arbeitszeit. ' +
        'Rückgängig: an derselben Stelle im Entra-Portal „Administratorzustimmung erteilen“.' }),
      status),
      [el('span', { class: 'grow' }), check, done]);
  }

  // ================================================================ Rollengruppen
  async function viewGroups(force) {
    const groups = await load('groups', 'roleGroups', 'Lese Rollengruppen …', force);
    state.groups ??= { search: '', chip: 'all' };
    const s = state.groups;
    const f = viewFrame({
      title: 'Rollengruppen', sub: 'Gruppen, die Rollen bündeln – Mitglieder erhalten alle Rollen der Gruppe (im jeweiligen Bereich).',
      chips: [['all', 'Alle'], ['custom', 'Eigene'], ['members', 'Mit Mitgliedern']], chip: s.chip, onChip: k => { s.chip = k; viewGroups(); },
      search: s.search, onSearch: v => { s.search = v; refresh(); },
      buttons: [el('button', { class: 'primary', onclick: newRoleGroup }, '＋ Neue Rollengruppe …'), el('button', { class: 'outline', onclick: () => exportCsv('Rollengruppen', tbl) }, 'CSV'), el('button', { class: 'outline', onclick: () => viewGroups(true) }, '↻')],
    });
    let tbl;
    const refresh = () => {
      const rows = groups.filter(g => matches(g, s.search, ['name', 'description', r => r.roles.join(' ')]))
        .filter(g => s.chip === 'all' || (s.chip === 'custom' ? !g.builtIn : g.members > 0));
      tbl = table({
        rows, key: g => g.name,
        columns: [
          { title: 'Name', key: 'name' }, { title: 'Herkunft', text: g => g.builtIn ? 'Standard' : 'Eigene', render: g => badge(g.builtIn ? 'Standard' : 'Eigene', g.builtIn ? '' : 'info') },
          { title: 'Mitglieder', key: 'members', sort: g => g.members }, { title: 'Rollen', text: g => String(g.roles.length), sort: g => g.roles.length },
          { title: 'Bereich', key: 'writeScope' }, { title: 'Beschreibung', key: 'description' },
        ],
        onSelect: g => groupDetails(f.details, g),
      });
      f.tableSlot.replaceChildren(tbl);
    };
    refresh();
  }

  async function groupDetails(details, g) {
    const members = el('div', { class: 'muted' }, 'Lade Mitglieder …');
    showDetails(details, el('h2', {}, g.name), el('div', { class: 'muted' }, g.description),
      el('h3', {}, 'Rollen (' + g.roles.length + ')'), el('ul', { class: 'list' }, g.roles.map(r => el('li', {}, el('span', { class: 'grow' }, r)))),
      g.writeScope ? [el('h3', {}, 'Bereich'), el('div', {}, g.writeScope)] : null,
      el('h3', {}, 'Mitglieder'), members,
      el('div', { class: 'actions' },
        el('button', { class: 'primary', onclick: () => addMember(g) }, '＋ Mitglied'),
        !g.builtIn ? el('button', { class: 'danger', onclick: async () => { if (await preview('Rollengruppe löschen', 'Remove-RoleGroup -Identity ' + q(g.name) + ' -Confirm:$false', { danger: true, okText: 'Löschen' })) { invalidate('groups', 'assignments'); viewGroups(true); } } }, 'Löschen') : null));
    try {
      const list = await call('roleGroupMembers', { identity: g.name });
      members.replaceWith(list.length ? el('ul', { class: 'list' }, list.map(m => el('li', {}, el('span', { class: 'grow' }, m.displayName || m.name, el('div', { class: 'muted' }, (m.smtp || '') + ' · ' + m.type)),
        el('button', { class: 'small danger', onclick: async () => { if (await preview('Mitglied entfernen', 'Remove-RoleGroupMember -Identity ' + q(g.name) + ' -Member ' + q(m.smtp || m.identity) + ' -BypassSecurityGroupManagerCheck -Confirm:$false', { danger: true, okText: 'Entfernen' })) { invalidate('groups'); groupDetails(details, g); } } }, 'Entfernen'))))
        : el('div', { class: 'muted' }, 'Keine Mitglieder.'));
    } catch (e) { members.textContent = e.message; }
  }

  function recipientPicker(onPick, placeholder = 'Benutzer oder Gruppe suchen …') {
    const input = el('input', { placeholder, style: 'width:100%' });
    const pick = el('div', { class: 'pick' });
    let timer = 0;
    input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(async () => {
      if (input.value.trim().length < 2) return;
      try {
        const found = await call('findRecipients', { text: input.value.trim() });
        pick.replaceChildren(...found.map(r => el('div', { onclick: e => { pick.querySelectorAll('.sel').forEach(x => x.classList.remove('sel')); e.currentTarget.classList.add('sel'); onPick(r); } },
          r.name, el('span', { class: 'muted' }, '  ' + r.smtp + ' · ' + r.type))));
        if (!found.length) pick.replaceChildren(el('div', { class: 'muted' }, 'Nichts gefunden.'));
      } catch (e) { pick.replaceChildren(el('div', { class: 'muted' }, e.message)); }
    }, 350); });
    setTimeout(() => input.focus(), 0);
    return el('div', {}, input, pick);
  }

  function addMember(g) {
    let chosen = null;
    const ok = el('button', { class: 'primary', disabled: true }, 'Weiter …');
    openModal('Mitglied zu „' + g.name + '“ hinzufügen', recipientPicker(r => { chosen = r; ok.disabled = false; }), [el('button', { class: 'outline', onclick: closeModal }, 'Abbrechen'), ok]);
    ok.onclick = async () => {
      if (await preview('Mitglied hinzufügen', 'Add-RoleGroupMember -Identity ' + q(g.name) + ' -Member ' + q(chosen.smtp || chosen.identity) + ' -BypassSecurityGroupManagerCheck')) { invalidate('groups'); viewGroups(true); }
    };
  }

  async function newRoleGroup() {
    const roles = await load('roles', 'roles', 'Lese Rollen …');
    const scopes = await load('scopes', 'scopes', 'Lese Bereiche …');
    const name = el('input', { style: 'width:100%', placeholder: 'z. B. Helpdesk-Standort-Berlin' });
    const desc = el('input', { style: 'width:100%' });
    const filter = el('input', { placeholder: 'Rollen filtern …', style: 'width:100%;margin-bottom:6px' });
    const picked = new Set();
    const list = el('div', { class: 'checks' });
    const renderRoles = () => list.replaceChildren(...roles.filter(r => !r.endUser && !r.app && matches(r, filter.value, ['name', 'description'])).map(r => {
      const cb = el('input', { type: 'checkbox' }); cb.checked = picked.has(r.name);
      cb.onchange = () => cb.checked ? picked.add(r.name) : picked.delete(r.name);
      return el('label', { title: r.description }, cb, r.name, r.custom ? badge('eigene', 'info') : null);
    }));
    filter.oninput = renderRoles; renderRoles();
    const scope = el('select', { style: 'width:100%' }, el('option', { value: '' }, 'ganze Organisation'), scopes.filter(s => s.type === 'RecipientScope').map(s => el('option', { value: s.name }, s.name)));
    const ok = el('button', { class: 'primary' }, 'Weiter …');
    openModal('Neue Rollengruppe', el('div', {}, el('label', {}, 'Name'), name, el('label', {}, 'Beschreibung'), desc, el('label', {}, 'Rollen'), filter, list, el('label', {}, 'Schreibbereich (optional)'), scope,
      el('div', { class: 'muted', style: 'margin-top:6px' }, 'Mitglieder fügst du danach in der Gruppe hinzu.')), [el('button', { class: 'outline', onclick: closeModal }, 'Abbrechen'), ok]);
    ok.onclick = async () => {
      if (!name.value.trim() || !picked.size) { toast('Name und mindestens eine Rolle angeben.', true); return; }
      let cmd = 'New-RoleGroup -Name ' + q(name.value.trim()) + ' -Roles ' + [...picked].map(q).join(', ');
      if (desc.value.trim()) cmd += ' -Description ' + q(desc.value.trim());
      if (scope.value) cmd += ' -CustomRecipientWriteScope ' + q(scope.value);
      if (await preview('Neue Rollengruppe', cmd)) { invalidate('groups', 'assignments'); viewGroups(true); }
    };
  }

  // ================================================================ Rollen
  async function viewRoles(force) {
    const roles = await load('roles', 'roles', 'Lese Rollen …', force);
    state.roles ??= { search: '', chip: 'admin' };
    const s = state.roles;
    const f = viewFrame({
      title: 'Rollen', sub: 'Eine Rolle ist eine Sammlung von Cmdlets und Parametern. Eigene Rollen leiten sich von einer Standardrolle ab und können nur weniger.',
      chips: [['admin', 'Verwaltung'], ['custom', 'Eigene'], ['app', 'Anwendungen'], ['user', 'Endbenutzer'], ['all', 'Alle']], chip: s.chip, onChip: k => { s.chip = k; viewRoles(); },
      search: s.search, onSearch: v => { s.search = v; refresh(); },
      buttons: [el('button', { class: 'outline', onclick: () => exportCsv('Rollen', tbl) }, 'CSV'), el('button', { class: 'outline', onclick: () => viewRoles(true) }, '↻')],
    });
    let tbl;
    const refresh = () => {
      const rows = roles.filter(r => matches(r, s.search, ['name', 'description', 'parent']))
        .filter(r => s.chip === 'all' || (s.chip === 'custom' ? r.custom : s.chip === 'app' ? r.app : s.chip === 'user' ? r.endUser : !r.endUser && !r.app));
      tbl = table({
        rows, key: r => r.name,
        columns: [{ title: 'Name', key: 'name' }, { title: 'Herkunft', text: r => r.custom ? 'Eigene' : 'Standard', render: r => badge(r.custom ? 'Eigene' : 'Standard', r.custom ? 'info' : '') },
          { title: 'Abgeleitet von', key: 'parent' }, { title: 'Typ', key: 'type' }, { title: 'Beschreibung', key: 'description' }],
        onSelect: r => roleDetails(f.details, r),
      });
      f.tableSlot.replaceChildren(tbl);
    };
    refresh();
  }

  async function roleDetails(details, r) {
    const entries = el('div', { class: 'muted' }, 'Lade Cmdlets …');
    const search = el('input', { placeholder: 'Cmdlet oder Parameter filtern …', style: 'width:100%' });
    showDetails(details, el('h2', {}, r.name), r.custom ? badge('Eigene Rolle', 'info') : badge('Standard'), el('div', { class: 'muted', style: 'margin-top:6px' }, r.description),
      kv([['Abgeleitet von', r.parent], ['Typ', r.type]]),
      el('div', { class: 'actions' },
        !r.endUser && !r.app ? el('button', { class: 'primary', onclick: () => customRoleWizard(r) }, 'Eigene Rolle davon ableiten …') : null,
        r.custom ? el('button', { class: 'outline', onclick: () => editEntries(r) }, 'Cmdlets bearbeiten …') : null,
        r.custom ? el('button', { class: 'danger', onclick: async () => { if (await preview('Eigene Rolle löschen', 'Remove-ManagementRole -Identity ' + q(r.name) + ' -Confirm:$false', { danger: true, okText: 'Löschen' })) { invalidate('roles'); viewRoles(true); } } }, 'Löschen') : null),
      el('h3', {}, 'Cmdlets'), search, entries);
    try {
      const list = await call('roleEntries', { role: r.name });
      const render = () => {
        const rows = list.filter(e => matches(e, search.value, ['name', x => x.parameters.join(' ')]));
        entries.replaceChildren(el('div', { class: 'muted', style: 'margin:6px 0' }, rows.length + ' von ' + list.length + ' Cmdlets'),
          el('ul', { class: 'list' }, rows.map(e => el('li', { title: e.parameters.map(p => '-' + p).join(' ') }, el('span', { class: 'grow mono' }, e.name), el('span', { class: 'muted' }, e.parameters.length + ' Param.')))));
      };
      entries.className = '';
      search.oninput = render; render();
    } catch (e) { entries.textContent = e.message; }
  }

  async function customRoleWizard(parent) {
    const name = el('input', { style: 'width:100%', value: parent.name + ' (eingeschränkt)' });
    const desc = el('input', { style: 'width:100%' });
    const ok = el('button', { class: 'primary' }, 'Weiter …');
    openModal('Eigene Rolle ableiten von „' + parent.name + '“', el('div', {},
      el('div', { class: 'note' }, 'Die neue Rolle startet mit allen Cmdlets von „' + parent.name + '“. Danach wählst du ab, was sie nicht können soll.'),
      el('label', {}, 'Name'), name, el('label', {}, 'Beschreibung'), desc), [el('button', { class: 'outline', onclick: closeModal }, 'Abbrechen'), ok]);
    ok.onclick = async () => {
      let cmd = 'New-ManagementRole -Name ' + q(name.value.trim()) + ' -Parent ' + q(parent.name);
      if (desc.value.trim()) cmd += ' -Description ' + q(desc.value.trim());
      if (await preview('Eigene Rolle anlegen', cmd)) {
        invalidate('roles');
        await load('roles', 'roles', 'Lese Rollen …', true);
        editEntries({ name: name.value.trim(), custom: true });
      }
    };
  }

  async function editEntries(role) {
    const list = await busy('Lese Cmdlets …', () => call('roleEntries', { role: role.name }));
    const keep = new Set(list.map(e => e.name));
    const filter = el('input', { placeholder: 'Filtern (z. B. Get-, Mailbox) …', style: 'width:100%;margin-bottom:6px' });
    const box = el('div', { class: 'checks', style: 'max-height:52vh' });
    const render = () => box.replaceChildren(...list.filter(e => matches(e, filter.value, ['name'])).map(e => {
      const cb = el('input', { type: 'checkbox' }); cb.checked = keep.has(e.name);
      cb.onchange = () => cb.checked ? keep.add(e.name) : keep.delete(e.name);
      return el('label', { title: e.parameters.map(p => '-' + p).join(' ') }, cb, el('span', { class: 'mono' }, e.name));
    }));
    filter.oninput = render; render();
    const bulk = (fn, on) => { list.filter(e => matches(e, filter.value, ['name']) && fn(e.name)).forEach(e => on ? keep.add(e.name) : keep.delete(e.name)); render(); };
    const ok = el('button', { class: 'primary' }, 'Weiter …');
    openModal('Cmdlets von „' + role.name + '“', el('div', {},
      el('div', { class: 'note' }, 'Abgewählte Cmdlets werden aus der Rolle entfernt. Entfernte Cmdlets lassen sich nur wieder hinzufügen, wenn die Elternrolle sie enthält.'),
      filter,
      el('div', { style: 'display:flex;gap:6px;margin-bottom:6px;flex-wrap:wrap' },
        el('button', { class: 'small outline', onclick: () => bulk(() => true, true) }, 'Sichtbare an'), el('button', { class: 'small outline', onclick: () => bulk(() => true, false) }, 'Sichtbare aus'),
        el('button', { class: 'small outline', onclick: () => bulk(n => !/^Get-|^Test-|^Search-/.test(n), false) }, 'Nur lesen (Get/Test/Search behalten)')),
      box), [el('button', { class: 'outline', onclick: closeModal }, 'Abbrechen'), ok]);
    ok.onclick = async () => {
      const removed = list.filter(e => !keep.has(e.name));
      if (!removed.length) { toast('Nichts geändert.'); return; }
      const script = '# ' + removed.length + ' Cmdlets aus „' + role.name + '“ entfernen\n' + removed.map(e => 'Remove-ManagementRoleEntry -Identity ' + q(role.name + '\\' + e.name) + ' -Confirm:$false').join('\n');
      if (await preview('Cmdlets entfernen', script, { danger: true, okText: 'Entfernen' })) { invalidate('roles'); viewRoles(true); }
    };
  }

  // ================================================================ Zuweisungen
  async function viewAssignments(force) {
    const list = await load('assignments', 'assignments', 'Lese Rollenzuweisungen …', force);
    state.assignments ??= { search: '', chip: 'all' };
    const s = state.assignments;
    const f = viewFrame({
      title: 'Zuweisungen', sub: 'Wer (Rollengruppe, Benutzer, App, Richtlinie) welche Rolle in welchem Bereich hat. ' +
        'Direkte Zuweisungen an Benutzer oder Apps zeigt das Exchange Admin Center nicht an.',
      chips: [['all', 'Alle'], ['direct', 'Direkt (nicht über Rollengruppe)'], ['apps', 'Apps'], ['scoped', 'Mit Bereich'], ['disabled', 'Deaktiviert']], chip: s.chip, onChip: k => { s.chip = k; viewAssignments(); },
      search: s.search, onSearch: v => { s.search = v; refresh(); },
      buttons: [el('button', { class: 'primary', onclick: newAssignment }, '＋ Neue Zuweisung …'), el('button', { class: 'outline', onclick: () => exportCsv('Rollenzuweisungen', tbl) }, 'CSV'), el('button', { class: 'outline', onclick: () => viewAssignments(true) }, '↻')],
    });
    const scopeOf = a => a.resourceScope || a.customWriteScope || (a.writeScope && !/^(Organization|NotApplicable)$/.test(a.writeScope) ? a.writeScope : '');
    let tbl;
    const refresh = () => {
      const rows = list.filter(a => matches(a, s.search, ['name', 'role', 'assignee', 'assigneeType', scopeOf]))
        .filter(a => s.chip === 'all' || (s.chip === 'direct' ? !/RoleGroup|RoleAssignmentPolicy/.test(a.assigneeType) : s.chip === 'apps' ? a.assigneeType === 'ServicePrincipal' : s.chip === 'scoped' ? !!scopeOf(a) : !a.enabled));
      tbl = table({
        rows, key: a => a.name,
        columns: [
          { title: 'Rolle', key: 'role' }, { title: 'Zugewiesen an', key: 'assignee' },
          { title: 'Typ', key: 'assigneeType', render: a => badge(a.assigneeType, a.assigneeType === 'ServicePrincipal' ? 'info' : /RoleGroup|Policy/.test(a.assigneeType) ? '' : 'warn') },
          { title: 'Bereich', text: a => scopeOf(a) || 'Organisation' }, { title: 'Aktiv', text: a => a.enabled ? 'ja' : 'nein', render: a => a.enabled ? 'ja' : badge('nein', 'warn') },
          { title: 'Art', text: a => a.delegating === 'Delegating' ? 'delegierend' : 'regulär' }, { title: 'Erstellt', key: 'created' },
        ],
        onSelect: a => showDetails(f.details, el('h2', {}, a.name),
          kv([['Rolle', a.role], ['Zugewiesen an', a.assignee + ' (' + a.assigneeType + ')'], ['Schreibbereich', a.customWriteScope || a.writeScope], ['Ressourcenbereich', a.resourceScope], ['Lesebereich', a.readScope], ['Konfiguration', a.configScope], ['Aktiv', a.enabled ? 'ja' : 'nein'], ['Art', a.delegating], ['Erstellt', a.created]]),
          !/RoleGroup|Policy/.test(a.assigneeType) ? el('div', { class: 'note warn' }, 'Direkte Zuweisung – im Exchange Admin Center nicht sichtbar.') : null,
          el('div', { class: 'actions' },
            el('button', { class: 'outline', onclick: async () => { if (await preview(a.enabled ? 'Zuweisung deaktivieren' : 'Zuweisung aktivieren', 'Set-ManagementRoleAssignment -Identity ' + q(a.name) + ' -Enabled $' + (!a.enabled))) { invalidate('assignments', 'apps'); viewAssignments(true); } } }, a.enabled ? 'Deaktivieren' : 'Aktivieren'),
            el('button', { class: 'danger', onclick: async () => { if (await preview('Zuweisung entfernen', 'Remove-ManagementRoleAssignment -Identity ' + q(a.name) + ' -Confirm:$false', { danger: true, okText: 'Entfernen' })) { invalidate('assignments', 'apps'); viewAssignments(true); } } }, 'Entfernen'))),
      });
      f.tableSlot.replaceChildren(tbl);
    };
    refresh();
  }

  async function newAssignment() {
    const roles = await load('roles', 'roles', 'Lese Rollen …');
    const scopes = await load('scopes', 'scopes', 'Lese Bereiche …');
    let who = null;
    const role = el('select', { style: 'width:100%' }, roles.filter(r => !r.endUser && !r.app).sort((a, b) => a.name.localeCompare(b.name)).map(r => el('option', { value: r.name }, r.name)));
    const scope = el('select', { style: 'width:100%' }, el('option', { value: '' }, 'ganze Organisation'), scopes.filter(s => s.type === 'RecipientScope').map(s => el('option', { value: s.name }, s.name)));
    const ok = el('button', { class: 'primary' }, 'Weiter …');
    openModal('Neue Rollenzuweisung', el('div', {},
      el('div', { class: 'note' }, 'Für Apps den Assistenten unter „Anwendungen“ verwenden. Für Benutzer sind Rollengruppen meist übersichtlicher.'),
      el('label', {}, 'Rolle'), role, el('label', {}, 'Benutzer oder Sicherheitsgruppe'), recipientPicker(r => { who = r; }), el('label', {}, 'Schreibbereich'), scope),
      [el('button', { class: 'outline', onclick: closeModal }, 'Abbrechen'), ok]);
    ok.onclick = async () => {
      if (!who) { toast('Bitte Benutzer oder Gruppe wählen.', true); return; }
      const isGroup = /Group/.test(who.type);
      let cmd = 'New-ManagementRoleAssignment -Role ' + q(role.value) + (isGroup ? ' -SecurityGroup ' : ' -User ') + q(who.smtp || who.identity);
      if (scope.value) cmd += ' -CustomRecipientWriteScope ' + q(scope.value);
      if (await preview('Neue Rollenzuweisung', cmd)) { invalidate('assignments'); viewAssignments(true); }
    };
  }

  // ================================================================ Bereiche
  async function viewScopes(force) {
    const list = await load('scopes', 'scopes', 'Lese Bereiche …', force);
    state.scopes ??= { search: '' };
    const s = state.scopes;
    const assignments = cache.assignments;
    const f = viewFrame({
      title: 'Bereiche', sub: 'Management Scopes legen fest, auf welche Empfänger eine Zuweisung wirkt – z. B. nur die Postfächer einer Gruppe oder Abteilung.',
      search: s.search, onSearch: v => { s.search = v; refresh(); },
      buttons: [el('button', { class: 'primary', onclick: newScope }, '＋ Neuer Bereich …'), el('button', { class: 'outline', onclick: () => exportCsv('Bereiche', tbl) }, 'CSV'), el('button', { class: 'outline', onclick: () => viewScopes(true) }, '↻')],
    });
    let tbl;
    const refresh = () => {
      tbl = table({
        rows: list.filter(x => matches(x, s.search, ['name', 'filter', 'root'])), key: x => x.name,
        columns: [{ title: 'Name', key: 'name' }, { title: 'Typ', key: 'type' }, { title: 'Filter', key: 'filter', render: x => el('span', { class: 'mono' }, x.filter) }, { title: 'Stamm', key: 'root' }, { title: 'Erstellt', key: 'created' }],
        onSelect: async x => {
          const prev = el('div');
          const used = (assignments || await call('assignments').then(r => (cache.assignments = r)).catch(() => [])).filter(a => a.resourceScope === x.name || a.customWriteScope === x.name);
          showDetails(f.details, el('h2', {}, x.name), kv([['Typ', x.type], ['Stamm', x.root], ['Exklusiv', x.exclusive ? 'ja' : '']]),
            el('h3', {}, 'Filter'), el('pre', { class: 'code', style: 'white-space:pre-wrap' }, x.filter || '–'),
            el('h3', {}, 'Verwendet von (' + used.length + ')'), used.length ? el('ul', { class: 'list' }, used.map(a => el('li', {}, el('span', { class: 'grow' }, a.role, el('div', { class: 'muted' }, a.assignee))))) : el('div', { class: 'muted' }, 'Keiner Zuweisung zugeordnet.'),
            el('div', { class: 'actions' },
              x.filter ? el('button', { class: 'outline', onclick: () => previewMembers(x.filter, prev) }, 'Empfänger anzeigen') : null,
              el('button', { class: 'danger', onclick: async () => { if (await preview('Bereich löschen', 'Remove-ManagementScope -Identity ' + q(x.name) + ' -Confirm:$false', { danger: true, okText: 'Löschen', explain: used.length ? 'Der Bereich wird noch von ' + used.length + ' Zuweisung(en) verwendet – Exchange lehnt das Löschen dann ab.' : '' })) { invalidate('scopes'); viewScopes(true); } } }, 'Löschen')),
            prev);
        },
      });
      f.tableSlot.replaceChildren(tbl);
    };
    refresh();
  }

  function newScope() {
    let group = null;
    const name = el('input', { style: 'width:100%' });
    const custom = el('textarea', { rows: 3, style: 'width:100%', placeholder: "z. B. Department -eq 'Vertrieb'  oder  CustomAttribute1 -eq 'FirmaB'" });
    const prev = el('div');
    const groupInput = el('input', { placeholder: 'Gruppe suchen …', style: 'width:100%' });
    const pick = el('div', { class: 'pick' });
    let timer = 0;
    groupInput.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(async () => {
      if (groupInput.value.trim().length < 2) return;
      const found = await call('findGroups', { text: groupInput.value.trim() }).catch(() => []);
      pick.replaceChildren(...found.map(g => el('div', { onclick: e => { group = g; custom.value = groupFilter(g); pick.querySelectorAll('.sel').forEach(x => x.classList.remove('sel')); e.currentTarget.classList.add('sel'); if (!name.value) name.value = 'Mitglieder-' + (g.name || '').replace(/[^\w.-]+/g, '-'); } },
        g.displayName || g.name, el('span', { class: 'muted' }, '  ' + g.type + ' · ' + g.members + ' Mitglieder'))));
    }, 350); });
    const ok = el('button', { class: 'primary' }, 'Weiter …');
    openModal('Neuer Bereich', el('div', {},
      el('label', {}, 'Name'), name,
      el('label', {}, 'Schnellwahl: Mitglieder einer Gruppe'), groupInput, pick,
      el('label', {}, 'Empfängerfilter (OPATH)'), custom,
      el('div', { style: 'margin-top:6px' }, el('button', { class: 'small outline', onclick: () => custom.value.trim() && previewMembers(custom.value.trim(), prev) }, 'Empfänger vorab anzeigen')), prev),
      [el('button', { class: 'outline', onclick: closeModal }, 'Abbrechen'), ok]);
    ok.onclick = async () => {
      if (!name.value.trim() || !custom.value.trim()) { toast('Name und Filter angeben.', true); return; }
      if (await preview('Neuer Bereich', 'New-ManagementScope -Name ' + q(name.value.trim()) + ' -RecipientRestrictionFilter ' + qd(custom.value.trim()))) { invalidate('scopes'); viewScopes(true); }
    };
  }

  // ================================================================ Nachschlagen
  async function viewLookup() {
    const main = $('main');
    const userIn = el('input', { placeholder: 'UPN oder Alias, z. B. helpdesk@contoso.com', style: 'width:360px' });
    const cmdIn = el('input', { placeholder: 'Cmdlet, z. B. Set-Mailbox', style: 'width:360px' });
    const userOut = el('div'), cmdOut = el('div');
    const userGo = async () => {
      if (!userIn.value.trim()) return;
      try {
        const res = await busy('Ermittle Rechte (prüft alle Rollengruppen) …', () => call('userRights', { user: userIn.value.trim() }));
        userOut.replaceChildren(el('div', { class: 'muted', style: 'margin:8px 0' }, res.user + ' · ' + res.rows.length + ' Rollen'),
          table({ rows: res.rows, columns: [{ title: 'Rolle', key: 'role' }, { title: 'Über', key: 'via' }, { title: 'Bereich', key: 'scope' }], empty: 'Keine Exchange-Rollen.' }));
      } catch (e) { userOut.replaceChildren(el('div', { class: 'note bad' }, e.message)); }
    };
    const cmdGo = async () => {
      if (!cmdIn.value.trim()) return;
      try {
        const rows = await busy('Suche Rollen …', () => call('commandLookup', { cmdlet: cmdIn.value.trim() }));
        cmdOut.replaceChildren(table({ rows, columns: [{ title: 'Rolle', key: 'name' }, { title: 'Herkunft', text: r => r.custom ? 'Eigene' : 'Standard' }, { title: 'Beschreibung', key: 'description' }], empty: 'Kein Treffer – Cmdlet-Name prüfen.' }));
      } catch (e) { cmdOut.replaceChildren(el('div', { class: 'note bad' }, e.message)); }
    };
    userIn.addEventListener('keydown', e => e.key === 'Enter' && userGo());
    cmdIn.addEventListener('keydown', e => e.key === 'Enter' && cmdGo());
    main.replaceChildren(el('div', { class: 'head' }, el('div', {}, el('h1', {}, 'Nachschlagen'), el('div', { class: 'sub' }, 'Was darf ein Konto? Welche Rolle erlaubt ein Cmdlet?'))),
      el('div', { style: 'overflow:auto;padding:0 20px 20px' },
        el('h3', { class: 'muted' }, 'Rechte eines Kontos'), el('div', { style: 'display:flex;gap:8px' }, userIn, el('button', { class: 'primary', onclick: userGo }, 'Anzeigen')), userOut,
        el('h3', { class: 'muted', style: 'margin-top:28px' }, 'Welche Rolle erlaubt …'), el('div', { style: 'display:flex;gap:8px' }, cmdIn, el('button', { class: 'primary', onclick: cmdGo }, 'Suchen')), cmdOut));
  }

  const views = { apps: viewApps, groups: viewGroups, roles: viewRoles, assignments: viewAssignments, scopes: viewScopes, lookup: viewLookup };

  // ---------------------------------------------------------------- Start
  function setTheme(name) { document.documentElement.classList.toggle('light', name === 'light'); }

  async function connect() {
    try {
      const info = await busy('Verbinde mit Exchange Online (Browser-Anmeldung) …', () => call('connect'));
      $('org').textContent = (info.organization || info.tenant) + ' · ' + info.upn;
      go(current);
    } catch (e) {
      $('org').textContent = 'nicht verbunden';
      showError(e);
    }
  }

  document.querySelectorAll('#nav button[data-view]').forEach(b => b.addEventListener('click', () => go(b.dataset.view)));
  $('btnReconnect').onclick = () => { Object.keys(cache).forEach(k => delete cache[k]); post({ t: 'reset' }); connect(); };
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && !$('modal').hidden && !$('modal').querySelector('button:disabled')) closeModal(); });

  if (!host) { $('main').textContent = 'Nur innerhalb von M365 Manager nutzbar.'; return; }
  host.addEventListener('message', e => {
    const m = e.data;
    switch (m.t) {
      case 'res': { const cb = pending.get(m.id); if (cb) { pending.delete(m.id); cb(m); } break; }
      case 'init': setTheme(m.theme); connect(); break;
      case 'theme': setTheme(m.name); break;
      case 'notice': toast(m.text); $('busyText').textContent = m.text; break;
    }
  });
  post({ t: 'ready' });
})();
