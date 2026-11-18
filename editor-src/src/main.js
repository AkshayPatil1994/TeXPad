// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, dropCursor,
  rectangularSelection, crosshairCursor, highlightSpecialChars, placeholder } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab, toggleComment, undo, redo } from "@codemirror/commands";
import { StreamLanguage, syntaxHighlighting, HighlightStyle, bracketMatching, foldGutter, foldKeymap, foldService,
  indentOnInput } from "@codemirror/language";
import { stex } from "@codemirror/legacy-modes/mode/stex";
import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap, startCompletion } from "@codemirror/autocomplete";
import { searchKeymap, highlightSelectionMatches, openSearchPanel } from "@codemirror/search";
import { linter, lintGutter, setDiagnostics } from "@codemirror/lint";
import { tags as t } from "@lezer/highlight";
import { latexCompletions, setProjectData } from "./completion.js";

const post = (msg) => { try { window.webkit.messageHandlers.editor.postMessage(msg); } catch (e) { /* not in WKWebView */ } };

// ---- language ---------------------------------------------------------------------------
const latex = StreamLanguage.define(stex);
const latexData = EditorState.languageData.of(() => [{
  commentTokens: { line: "%" },
  closeBrackets: { brackets: ["(", "[", "{", "$", "`"] },
}]);

const foldLaTeX = foldService.of((state, from) => {
  const line = state.doc.lineAt(from);
  const m = /^\s*\\begin\{([^}]+)\}/.exec(line.text);
  if (m) {
    const open = new RegExp("\\\\begin\\{" + m[1].replace(/[*]/g, "\\*") + "\\}", "g");
    const close = new RegExp("\\\\end\\{" + m[1].replace(/[*]/g, "\\*") + "\\}", "g");
    let depth = 1;
    for (let n = line.number + 1; n <= state.doc.lines; n++) {
      const l = state.doc.line(n);
      depth += (l.text.match(open) || []).length - (l.text.match(close) || []).length;
      if (depth <= 0) return { from: line.to, to: l.from - 1 > line.to ? l.from - 1 : l.to };
    }
    return null;
  }
  const s = /^\s*\\(part|chapter|section|subsection|subsubsection)\*?\{/.exec(line.text);
  if (s) {
    const order = ["part", "chapter", "section", "subsection", "subsubsection"];
    const lvl = order.indexOf(s[1]);
    let end = state.doc.length;
    for (let n = line.number + 1; n <= state.doc.lines; n++) {
      const l = state.doc.line(n);
      const m2 = /^\s*\\(part|chapter|section|subsection|subsubsection)\*?\{/.exec(l.text);
      if ((m2 && order.indexOf(m2[1]) <= lvl) || /\\end\{document\}/.test(l.text)) { end = l.from - 1; break; }
    }
    return end > line.to ? { from: line.to, to: end } : null;
  }
  return null;
});

const highlight = HighlightStyle.define([
  { tag: t.comment, color: "var(--c-comment)", fontStyle: "italic" },
  { tag: [t.tagName, t.keyword], color: "var(--c-command)" },
  { tag: [t.standard(t.variableName), t.atom], color: "var(--c-env)" },
  { tag: t.bracket, color: "var(--c-bracket)" },
  { tag: [t.string, t.number], color: "var(--c-math)" },
  { tag: t.meta, color: "var(--c-meta)" },
  { tag: t.invalid, color: "var(--c-error)" },
]);

// ---- theme ------------------------------------------------------------------------------
const theme = EditorView.theme({
  "&": { height: "100%", backgroundColor: "var(--bg)", color: "var(--fg)" },
  ".cm-scroller": { fontFamily: "var(--font)", fontSize: "var(--fs)", lineHeight: "1.55", overflow: "auto" },
  ".cm-content": { caretColor: "var(--fg)", padding: "8px 0 40vh" },
  ".cm-gutters": { backgroundColor: "var(--bg)", color: "var(--gutter)", border: "none" },
  ".cm-activeLine": { backgroundColor: "var(--active-line)" },
  ".cm-activeLineGutter": { backgroundColor: "var(--active-line)", color: "var(--fg)" },
  "&.cm-focused .cm-cursor": { borderLeftColor: "var(--fg)", borderLeftWidth: "2px" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": { backgroundColor: "var(--selection)" },
  ".cm-matchingBracket": { backgroundColor: "var(--selection)", outline: "1px solid var(--gutter)" },
  ".cm-tooltip": { backgroundColor: "var(--panel)", border: "1px solid var(--border)", color: "var(--fg)", borderRadius: "8px" },
  ".cm-tooltip-autocomplete ul li[aria-selected]": { backgroundColor: "var(--accent)", color: "#fff" },
  ".cm-completionDetail": { opacity: 0.7, marginLeft: "1em" },
  ".cm-panels": { backgroundColor: "var(--panel)", color: "var(--fg)" },
  ".cm-searchMatch": { backgroundColor: "var(--search)" },
  ".cm-lintRange-error": { backgroundImage: "none", textDecoration: "underline wavy var(--c-error)" },
  ".cm-lintRange-warning": { backgroundImage: "none", textDecoration: "underline wavy #d9a400" },
  ".cm-foldPlaceholder": { backgroundColor: "var(--panel)", border: "1px solid var(--border)", color: "var(--gutter)" },
});

// ---- state management -------------------------------------------------------------------
const wrapC = new Compartment();
let view, current = null;
const states = new Map();       // path -> EditorState (keeps undo history per tab)
const diagnostics = new Map();  // path -> [{line,severity,message}]
let opts = { wrap: true, lineNumbers: true };

function lineDiagnostics(state, list) {
  return (list || []).filter((d) => d.line >= 1 && d.line <= state.doc.lines).map((d) => {
    const l = state.doc.line(d.line);
    return { from: l.from, to: Math.max(l.to, l.from + 1 > state.doc.length ? l.from : l.from + 1), severity: d.severity, message: d.message };
  });
}

let changeTimer = null;
function schedulePost(path) {
  clearTimeout(changeTimer);
  changeTimer = setTimeout(() => post({ type: "change", path, text: view.state.doc.toString() }), 350);
}

function extensions() {
  return [
    lineNumbers(), foldGutter(), highlightActiveLineGutter(), lintGutter(), highlightSpecialChars(), history(), drawSelection(), dropCursor(),
    EditorState.allowMultipleSelections.of(true), indentOnInput(), latex, latexData, foldLaTeX,
    syntaxHighlighting(highlight), bracketMatching(), closeBrackets(),
    autocompletion({ override: [latexCompletions], activateOnTyping: true, icons: true }),
    rectangularSelection(), crosshairCursor(), highlightActiveLine(), highlightSelectionMatches(),
    linter(null), // diagnostics are pushed from Swift via setDiagnostics
    wrapC.of(opts.wrap ? EditorView.lineWrapping : []),
    theme,
    keymap.of([
      { key: "Mod-s", run: () => { post({ type: "save", path: current }); return true; }, preventDefault: true },
      { key: "Mod-b", run: () => { post({ type: "build" }); return true; }, preventDefault: true },
      { key: "Mod-Enter", run: () => { post({ type: "build" }); return true; }, preventDefault: true },
      { key: "Mod-/", run: toggleComment },
      { key: "Mod-Space", run: startCompletion },
      { key: "Mod-Shift-p", run: () => { post({ type: "palette" }); return true; }, preventDefault: true },
      { key: "Mod-p", run: () => { post({ type: "quickOpen" }); return true; }, preventDefault: true },
      { key: "Mod-Shift-f", run: () => { post({ type: "searchProject" }); return true; }, preventDefault: true },
      ...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...foldKeymap, ...completionKeymap, indentWithTab,
    ]),
    EditorView.updateListener.of((u) => {
      if (u.docChanged) { schedulePost(current); post({ type: "dirty", path: current }); }
      if (u.selectionSet || u.docChanged) {
        const sel = u.state.selection.main, line = u.state.doc.lineAt(sel.head);
        post({ type: "cursor", path: current, line: line.number, col: sel.head - line.from + 1,
               selected: sel.empty ? "" : u.state.sliceDoc(sel.from, Math.min(sel.to, sel.from + 200)) });
      }
    }),
  ];
}

function makeState(text) { return EditorState.create({ doc: text, extensions: extensions() }); }

function applyDiagnostics() {
  if (!view || current == null) return;
  view.dispatch(setDiagnostics(view.state, lineDiagnostics(view.state, diagnostics.get(current))));
}

window.editor = {
  init() {
    view = new EditorView({ state: makeState(""), parent: document.getElementById("editor") });
    post({ type: "ready" });
  },
  openDoc(path, text, line, col) {
    if (current != null && view) states.set(current, view.state);
    current = path;
    let st = states.get(path);
    if (!st || (text != null && st.doc.toString() !== text)) st = makeState(text ?? "");
    view.setState(st);
    applyDiagnostics();
    if (line) this.gotoLine(line, col || 1);
  },
  closeDoc(path) { states.delete(path); diagnostics.delete(path); if (current === path) current = null; },
  renameDoc(from, to) { if (states.has(from)) { states.set(to, states.get(from)); states.delete(from); } if (current === from) current = to; },
  /** External change (e.g. file edited elsewhere): replace text, keep cursor if possible. */
  reload(path, text) {
    if (path === current) {
      const head = Math.min(view.state.selection.main.head, text.length);
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: { anchor: head } });
    } else states.delete(path);
  },
  gotoLine(line, col = 1, select = false) {
    const l = view.state.doc.line(Math.max(1, Math.min(line, view.state.doc.lines)));
    const pos = Math.min(l.from + Math.max(0, col - 1), l.to);
    view.dispatch({ selection: select ? { anchor: l.from, head: l.to } : { anchor: pos }, scrollIntoView: true,
      effects: EditorView.scrollIntoView(pos, { y: "center" }) });
    view.focus();
  },
  setDiagnostics(path, list) { diagnostics.set(path, list); if (path === current) applyDiagnostics(); },
  clearDiagnostics() { diagnostics.clear(); applyDiagnostics(); },
  setProjectData,
  insertText(text) { const r = view.state.replaceSelection(text); view.dispatch(r, { scrollIntoView: true, userEvent: "input" }); view.focus(); },
  /** Insert a snippet with ${1} stops using CodeMirror's snippet engine. */
  async insertSnippet(tpl) {
    const { snippet } = await import("@codemirror/autocomplete");
    const sel = view.state.selection.main;
    snippet(tpl)(view, null, sel.from, sel.to);
    view.focus();
  },
  getText() { return view.state.doc.toString(); },
  getSelection() { const s = view.state.selection.main; return view.state.sliceDoc(s.from, s.to); },
  find() { openSearchPanel(view); },
  complete() { view.focus(); startCompletion(view); },
  undo() { undo(view); }, redo() { redo(view); },
  setTheme(name) { document.documentElement.dataset.theme = name; },
  setFontSize(px) { document.documentElement.style.setProperty("--fs", px + "px"); },
  setWrap(on) { opts.wrap = on; view.dispatch({ effects: wrapC.reconfigure(on ? EditorView.lineWrapping : []) }); },
  focus() { view.focus(); },
};

// ---- key bar above the soft keyboard ----------------------------------------------------
const keys = [["Tab", "\t"], ["\\", "\\"], ["{", "{}"], ["}", "}"], ["[", "[]"], ["]", "]"], ["$", "$$"], ["&", "&"], ["^", "^{}"], ["_", "_{}"], ["%", "%"], ["~", "~"], ["\\\\", "\\\\\n"]];
function buildKeyBar() {
  const bar = document.getElementById("keybar");
  for (const [label, text] of keys) {
    const b = document.createElement("button");
    b.textContent = label === "Tab" ? "⇥" : label;
    b.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      const back = text.endsWith("}") && text.length === 2 || text === "$$" || text === "[]" || text === "^{}" || text === "_{}";
      window.editor.insertText(text);
      if (back) { const h = view.state.selection.main.head; view.dispatch({ selection: { anchor: h - (text === "^{}" || text === "_{}" ? 1 : 1) } }); }
    });
    bar.appendChild(b);
  }
  const mk = (label, fn) => { const b = document.createElement("button"); b.textContent = label; b.addEventListener("pointerdown", (e) => { e.preventDefault(); fn(); }); bar.appendChild(b); };
  mk("↶", () => undo(view)); mk("↷", () => redo(view)); mk("▶︎", () => post({ type: "build" }));
  const vv = window.visualViewport;
  const place = () => {
    const kb = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
    bar.style.bottom = kb + "px";
    bar.style.display = kb > 80 ? "flex" : "none";
  };
  vv.addEventListener("resize", place); vv.addEventListener("scroll", place); place();
}

window.addEventListener("DOMContentLoaded", () => { window.editor.init(); });
