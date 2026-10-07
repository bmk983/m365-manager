// M365 Manager · Skript-Editor (Monaco)
(() => {
  'use strict';

  const host = window.chrome && window.chrome.webview;
  const post = msg => host && host.postMessage(msg);

  // ---------------------------------------------------------------- Anfragen an die App
  const pending = new Map();
  let requestCounter = 0;
  function request(msg, timeoutMs = 15000) {
    return new Promise(resolve => {
      const id = ++requestCounter;
      const timer = setTimeout(() => { pending.delete(id); resolve(null); }, timeoutMs);
      pending.set(id, data => { clearTimeout(timer); resolve(data); });
      post({ ...msg, id });
    });
  }

  // ---------------------------------------------------------------- Zustand
  let editor = null;
  let tabs = [];
  let active = null;
  let profileId = 'default';
  let untitledCounter = 1;
  let tabCounter = 0;
  const $ = id => document.getElementById(id);

  const WELCOME = [
    '# Neues Skript',
    '# F5 = alles ausführen · F8 = Auswahl bzw. aktuelle Zeile · Strg+Leertaste = Vorschläge',
    '# Läuft im aktiven Terminal dieses Profils – inklusive bestehender Verbindungen (Graph, Exchange, …).',
    '',
    ''
  ].join('\n');

  // Deutsche Texte kommen aus vs/nls/lang/de.js (per <script> geladen, setzt globale Variablen).
  require.config({ paths: { vs: 'vs' } });
  require(['vs/editor/editor.main'], start);

  // ---------------------------------------------------------------- PowerShell-Sprache
  function registerPowerShell() {
    monaco.languages.register({ id: 'ps', extensions: ['.ps1', '.psm1', '.psd1'], aliases: ['PowerShell'] });

    monaco.languages.setLanguageConfiguration('ps', {
      wordPattern: /(-?\d*\.\d\w*)|([^\s`~!@#%^&*()=+\[{\]}\\|;'",.<>\/?]+)/g,
      comments: { lineComment: '#', blockComment: ['<#', '#>'] },
      brackets: [['{', '}'], ['[', ']'], ['(', ')']],
      autoClosingPairs: [
        { open: '{', close: '}' }, { open: '[', close: ']' }, { open: '(', close: ')' },
        { open: '"', close: '"', notIn: ['string'] }, { open: "'", close: "'", notIn: ['string', 'comment'] },
        { open: '<#', close: '#>', notIn: ['string'] }
      ],
      surroundingPairs: [{ open: '{', close: '}' }, { open: '[', close: ']' }, { open: '(', close: ')' }, { open: '"', close: '"' }, { open: "'", close: "'" }],
      folding: { markers: { start: /^\s*#region\b/, end: /^\s*#endregion\b/ } }
    });

    const variable = /\$(?:\{[^}]*\}|(?:global|script|local|private|using|env|function|variable|alias):[\w?]+|[\w?]+|[$^_])/;

    monaco.languages.setMonarchTokensProvider('ps', {
      ignoreCase: true,
      tokenPostfix: '.ps',
      keywords: ['begin', 'break', 'catch', 'class', 'continue', 'data', 'default', 'do', 'dynamicparam', 'else', 'elseif', 'end', 'enum',
        'exit', 'filter', 'finally', 'for', 'foreach', 'from', 'function', 'hidden', 'if', 'in', 'param', 'process', 'return', 'static',
        'switch', 'throw', 'trap', 'try', 'until', 'using', 'while', 'workflow', 'parallel', 'sequence', 'configuration', 'clean'],
      constants: ['$true', '$false', '$null'],
      wordOperators: /-(?:[ci]?(?:eq|ne|gt|ge|lt|le|like|notlike|match|notmatch|contains|notcontains|in|notin|replace|split))|-(?:join|is|isnot|as|and|or|not|xor|band|bor|bxor|bnot|shl|shr|f)\b/,
      variable,
      tokenizer: {
        root: [
          [/\s+/, ''],
          [/<#/, 'comment', '@blockComment'],
          [/#.*$/, 'comment'],
          [/@"\s*$/, 'string', '@hereDouble'],
          [/@'\s*$/, 'string', '@hereSingle'],
          [/"/, 'string', '@double'],
          [/'/, 'string', '@single'],
          [/\$(?:true|false|null)\b/, 'constant'],
          [/@variable/, 'variable'],
          [/\[(?=[a-z_])[\w.`]+(?:\[\])?\]/, 'type'],
          [/@wordOperators(?![\w-])/, 'operator.word'],
          [/-[a-z_][\w-]*:?/, 'parameter'],
          [/[a-z][a-z]*-[a-z][\w.]*/, 'cmdlet'],
          [/[a-z_][\w]*/, { cases: { '@keywords': 'keyword', '@default': 'identifier' } }],
          [/0x[0-9a-f]+/, 'number'],
          [/\d+(?:\.\d+)?(?:e[-+]?\d+)?(?:kb|mb|gb|tb|pb)?/, 'number'],
          [/[{}()\[\]]/, '@brackets'],
          [/[|;,]/, 'delimiter'],
          [/[=+*\/%!<>&.:-]/, 'operator']
        ],
        blockComment: [
          [/#>/, 'comment', '@pop'],
          [/\.(?:synopsis|description|parameter|example|notes|outputs|inputs|link)\b/, 'comment.doc'],
          [/[^#.]+/, 'comment'],
          [/[#.]/, 'comment']
        ],
        double: [
          [/`./, 'string.escape'],
          [/""/, 'string'],
          [/\$\(/, 'variable'],
          [/@variable/, 'variable'],
          [/"/, 'string', '@pop'],
          [/[^"`$]+/, 'string'],
          [/./, 'string']
        ],
        single: [
          [/''/, 'string'],
          [/'/, 'string', '@pop'],
          [/[^']+/, 'string']
        ],
        hereDouble: [
          [/^"@/, 'string', '@pop'],
          [/`./, 'string.escape'],
          [/@variable/, 'variable'],
          [/[^$`]+/, 'string'],
          [/./, 'string']
        ],
        hereSingle: [
          [/^'@/, 'string', '@pop'],
          [/.+$/, 'string']
        ]
      }
    });

    // Farben angelehnt an VS Code (Dark+/Light+)
    monaco.editor.defineTheme('m365-dark', {
      base: 'vs-dark', inherit: true,
      rules: [
        { token: 'comment', foreground: '6A9955' }, { token: 'comment.doc', foreground: '6A9955', fontStyle: 'bold' },
        { token: 'string', foreground: 'CE9178' }, { token: 'string.escape', foreground: 'D7BA7D' },
        { token: 'variable', foreground: '9CDCFE' }, { token: 'constant', foreground: '569CD6' },
        { token: 'cmdlet', foreground: 'DCDCAA' }, { token: 'parameter', foreground: 'A0A8B8' },
        { token: 'keyword', foreground: 'C586C0' }, { token: 'operator.word', foreground: 'C586C0' },
        { token: 'type', foreground: '4EC9B0' }, { token: 'number', foreground: 'B5CEA8' },
        { token: 'operator', foreground: 'D4D4D4' }, { token: 'identifier', foreground: 'D4D4D4' }
      ],
      colors: {
        'editor.background': '#1c1c1f', 'editorGutter.background': '#1c1c1f', 'minimap.background': '#1c1c1f',
        'editor.lineHighlightBackground': '#25252b', 'editorLineNumber.foreground': '#5a5a63', 'editorLineNumber.activeForeground': '#c8c8cf'
      }
    });
    monaco.editor.defineTheme('m365-light', {
      base: 'vs', inherit: true,
      rules: [
        { token: 'comment', foreground: '008000' }, { token: 'comment.doc', foreground: '008000', fontStyle: 'bold' },
        { token: 'string', foreground: 'A31515' }, { token: 'string.escape', foreground: 'EE0000' },
        { token: 'variable', foreground: '001080' }, { token: 'constant', foreground: '0000FF' },
        { token: 'cmdlet', foreground: '795E26' }, { token: 'parameter', foreground: '5A5A5A' },
        { token: 'keyword', foreground: 'AF00DB' }, { token: 'operator.word', foreground: 'AF00DB' },
        { token: 'type', foreground: '267F99' }, { token: 'number', foreground: '098658' }
      ],
      colors: { 'editor.background': '#fbfbfc', 'editorGutter.background': '#fbfbfc', 'minimap.background': '#fbfbfc' }
    });

    // IntelliSense: Vorschläge kommen von PowerShell selbst (TabExpansion2), wie beim Tab im Terminal.
    const kinds = monaco.languages.CompletionItemKind;
    const kindOf = k => ({
      Command: kinds.Function, Parameter: kinds.Property, Variable: kinds.Variable, Property: kinds.Field, Method: kinds.Method,
      Type: kinds.Class, ParameterValue: kinds.EnumMember, ProviderContainer: kinds.Folder, ProviderItem: kinds.File,
      Keyword: kinds.Keyword, DynamicKeyword: kinds.Keyword, Namespace: kinds.Module, History: kinds.Text
    })[k] ?? kinds.Text;

    monaco.languages.registerCompletionItemProvider('ps', {
      triggerCharacters: ['-', '$', '.', ':', '\\', '[', '/'],
      async provideCompletionItems(model, position, context, token) {
        const res = await request({ t: 'complete', code: model.getValue(), offset: model.getOffsetAt(position) }, 30000);
        if (!res || !Array.isArray(res.items) || token.isCancellationRequested) return { suggestions: [] };
        const start = model.getPositionAt(res.i);
        const end = model.getPositionAt(res.i + res.n);
        const range = new monaco.Range(start.lineNumber, start.column, end.lineNumber, end.column);
        return {
          incomplete: !!res.more,
          suggestions: res.items.map((x, idx) => ({
            label: x.l || x.t,
            insertText: x.t,
            filterText: x.t,
            kind: kindOf(x.k),
            detail: x.k === 'Command' ? 'Cmdlet / Funktion' : x.k,
            documentation: x.d && x.d.trim() !== (x.l || x.t) ? { value: '```powershell\n' + x.d.trim() + '\n```' } : undefined,
            range,
            sortText: String(idx).padStart(5, '0')
          }))
        };
      }
    });
  }

  // ---------------------------------------------------------------- Tabs
  const isDirty = tab => tab.model.getAlternativeVersionId() !== tab.savedVersion;

  function createTab({ path = null, name = null, content = WELCOME, dirty = false } = {}) {
    const tab = {
      id: ++tabCounter,
      path,
      name: name || ('Unbenannt-' + untitledCounter++ + '.ps1'),
      model: monaco.editor.createModel(content, 'ps'),
      viewState: null,
      savedVersion: 0
    };
    tab.savedVersion = dirty ? -1 : tab.model.getAlternativeVersionId();
    tab.model.onDidChangeContent(() => { renderTabs(); scheduleSessionSave(); });
    tabs.push(tab);
    activate(tab);
    return tab;
  }

  function activate(tab) {
    if (active && active !== tab) active.viewState = editor.saveViewState();
    active = tab;
    editor.setModel(tab.model);
    if (tab.viewState) editor.restoreViewState(tab.viewState);
    renderTabs();
    updateStatus();
    editor.focus();
    scheduleSessionSave();
  }

  function closeTab(tab) {
    if (isDirty(tab) && !confirm('„' + tab.name + '“ hat ungespeicherte Änderungen. Trotzdem schließen?')) return;
    const index = tabs.indexOf(tab);
    tabs.splice(index, 1);
    tab.model.dispose();
    if (tabs.length === 0) { active = null; createTab(); return; }
    if (active === tab) { active = null; activate(tabs[Math.min(index, tabs.length - 1)]); }
    renderTabs();
    scheduleSessionSave();
  }

  function renderTabs() {
    const el = $('tabs');
    el.innerHTML = '';
    for (const tab of tabs) {
      const t = document.createElement('div');
      t.className = 'tab' + (tab === active ? ' active' : '') + (isDirty(tab) ? ' dirty' : '');
      t.title = tab.path || tab.name;
      const name = document.createElement('span');
      name.className = 'name';
      name.textContent = tab.name;
      const close = document.createElement('span');
      close.className = 'close';
      close.title = 'Schließen (Strg+W)';
      close.addEventListener('click', e => { e.stopPropagation(); closeTab(tab); });
      t.append(name, close);
      t.addEventListener('mousedown', e => { if (e.button === 1) { e.preventDefault(); closeTab(tab); } });
      t.addEventListener('click', () => activate(tab));
      el.append(t);
    }
    post({ t: 'dirty', count: tabs.filter(isDirty).length });
  }

  function updateStatus() {
    if (!active) return;
    const p = editor.getPosition() || { lineNumber: 1, column: 1 };
    $('stPos').textContent = 'Z ' + p.lineNumber + ', Sp ' + p.column;
    $('stFile').textContent = active.path || active.name + ' (nicht gespeichert)';
  }

  let hintTimer = 0;
  function hint(text) {
    $('stHint').textContent = text;
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => { $('stHint').textContent = ''; }, 4000);
  }

  // ---------------------------------------------------------------- Dateien
  async function save(tab, saveAs = false) {
    const res = await request({ t: 'save', path: saveAs ? null : tab.path, name: tab.name, content: tab.model.getValue() }, 10 * 60 * 1000);
    if (!res || !res.ok) { if (res && res.error) hint('Speichern fehlgeschlagen: ' + res.error); return false; }
    tab.path = res.path;
    tab.name = res.name;
    tab.savedVersion = tab.model.getAlternativeVersionId();
    renderTabs();
    updateStatus();
    scheduleSessionSave();
    hint('Gespeichert');
    return true;
  }

  function openFile(path, name, content) {
    const existing = tabs.find(t => t.path && t.path.toLowerCase() === path.toLowerCase());
    if (existing) { activate(existing); return; }
    // Unveränderten, leeren Willkommens-Tab ersetzen
    const replace = tabs.length === 1 && !tabs[0].path && !isDirty(tabs[0]) && tabs[0].model.getValue() === WELCOME ? tabs[0] : null;
    createTab({ path, name, content });
    if (replace) { tabs.splice(tabs.indexOf(replace), 1); replace.model.dispose(); renderTabs(); }
  }

  // ---------------------------------------------------------------- Ausführen
  async function run(mode) {
    if (!active) return;
    const tab = active;
    if (mode === 'selection') {
      const sel = editor.getSelection();
      const code = sel.isEmpty() ? tab.model.getLineContent(sel.startLineNumber) : tab.model.getValueInRange(sel);
      if (!code.trim()) return;
      post({ t: 'run', mode, code, name: tab.name });
      hint(sel.isEmpty() ? 'Zeile ' + sel.startLineNumber + ' wird ausgeführt …' : 'Auswahl wird ausgeführt …');
      return;
    }
    // Gespeicherte Datei: vorher sichern, dann die echte Datei ausführen ($PSScriptRoot stimmt)
    if (tab.path && isDirty(tab) && !(await save(tab))) return;
    post({ t: 'run', mode: 'all', code: tab.model.getValue(), path: tab.path && !isDirty(tab) ? tab.path : null, name: tab.name });
    hint('Skript wird ausgeführt …');
  }

  // ---------------------------------------------------------------- Sitzung merken (pro Profil)
  let sessionTimer = 0;
  function scheduleSessionSave() {
    clearTimeout(sessionTimer);
    sessionTimer = setTimeout(saveSession, 800);
  }
  function saveSession() {
    try {
      const data = {
        active: tabs.indexOf(active),
        untitled: untitledCounter,
        tabs: tabs.map(t => ({ path: t.path, name: t.name, dirty: isDirty(t), content: (!t.path || isDirty(t)) ? t.model.getValue() : null }))
      };
      localStorage.setItem('m365m.editor.' + profileId, JSON.stringify(data));
    } catch { }
  }
  async function restoreSession() {
    let data = null;
    try { data = JSON.parse(localStorage.getItem('m365m.editor.' + profileId) || 'null'); } catch { }
    if (!data || !Array.isArray(data.tabs) || data.tabs.length === 0) { createTab(); return; }
    untitledCounter = data.untitled || 1;
    for (const t of data.tabs) {
      if (t.path && t.content == null) {
        const res = await request({ t: 'read', path: t.path }, 10000);
        if (res && res.ok) createTab({ path: t.path, name: t.name, content: res.content });
      } else {
        createTab({ path: t.path, name: t.name, content: t.content ?? '', dirty: !!t.dirty });
      }
    }
    if (tabs.length === 0) createTab();
    else activate(tabs[Math.max(0, Math.min(data.active ?? 0, tabs.length - 1))]);
  }

  // ---------------------------------------------------------------- Start
  function setTheme(name) {
    document.documentElement.classList.toggle('light', name === 'light');
    if (window.monaco) monaco.editor.setTheme(name === 'light' ? 'm365-light' : 'm365-dark');
  }

  function start() {
    registerPowerShell();
    editor = monaco.editor.create($('editor'), {
      model: null,
      theme: 'm365-dark',
      automaticLayout: true,
      fontFamily: '"Cascadia Mono", "Cascadia Code", Consolas, monospace',
      fontSize: 13,
      lineHeight: 20,
      tabSize: 4,
      insertSpaces: true,
      minimap: { enabled: true, renderCharacters: false },
      stickyScroll: { enabled: true },
      bracketPairColorization: { enabled: true },
      guides: { bracketPairs: 'active', indentation: true },
      renderWhitespace: 'selection',
      smoothScrolling: true,
      cursorSmoothCaretAnimation: 'on',
      scrollBeyondLastLine: false,
      padding: { top: 8 },
      fixedOverflowWidgets: true,
      wordBasedSuggestions: 'off',
      quickSuggestions: { other: true, comments: false, strings: false },
      quickSuggestionsDelay: 150,
      suggestOnTriggerCharacters: true,
      tabCompletion: 'on',
      acceptSuggestionOnEnter: 'smart',
      snippetSuggestions: 'none',
      suggest: { showWords: false, preview: true, showStatusBar: true }
    });
    editor.onDidChangeCursorPosition(updateStatus);

    // Tastenkürzel – global abfangen, egal wo der Fokus gerade ist
    window.addEventListener('keydown', e => {
      const k = e.key.toLowerCase();
      const handled =
        (e.key === 'F5' && !e.ctrlKey) ? (run('all'), true) :
        (e.key === 'F8') ? (run('selection'), true) :
        (e.ctrlKey && (e.key === 'Pause' || e.key === 'Cancel')) ? (post({ t: 'stop' }), true) :
        (e.ctrlKey && e.shiftKey && k === 's') ? (active && save(active, true), true) :
        (e.ctrlKey && !e.shiftKey && k === 's') ? (active && save(active), true) :
        (e.ctrlKey && !e.shiftKey && k === 'n') ? (createTab(), true) :
        (e.ctrlKey && !e.shiftKey && k === 'o') ? (post({ t: 'open' }), true) :
        (e.ctrlKey && !e.shiftKey && k === 'w') ? (active && closeTab(active), true) :
        (e.ctrlKey && e.key === 'Tab' && tabs.length > 1) ? (activate(tabs[(tabs.indexOf(active) + (e.shiftKey ? -1 : 1) + tabs.length) % tabs.length]), true) :
        false;
      if (handled) { e.preventDefault(); e.stopPropagation(); }
    }, true);

    $('btnNew').onclick = () => createTab();
    $('btnOpen').onclick = () => post({ t: 'open' });
    $('btnSave').onclick = () => active && save(active);
    $('btnRun').onclick = () => run('all');
    $('btnRunSel').onclick = () => run('selection');
    $('btnStop').onclick = () => post({ t: 'stop' });

    if (!host) { createTab(); return; }   // ohne App (z. B. im Browser getestet)

    host.addEventListener('message', async e => {
      const m = e.data;
      switch (m.t) {
        case 'res': { const cb = pending.get(m.id); if (cb) { pending.delete(m.id); cb(m); } break; }
        case 'init': profileId = m.profileId || 'default'; setTheme(m.theme); await restoreSession(); break;
        case 'theme': setTheme(m.name); break;
        case 'opened': openFile(m.path, m.name, m.content); break;
        case 'focus': editor.focus(); break;
        case 'hint': hint(m.text); break;
      }
    });
    post({ t: 'ready' });
  }
})();