// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import { snippetCompletion } from "@codemirror/autocomplete";
import { commands, environments, mathSymbols, bibStyles, tikzLibraries, classes } from "./data.js";

// Project data pushed from Swift: { labels:[{key,detail}], cites:[{key,detail,info}], files:[...], images:[...], packages:[...], bibs:[...] }
export const project = { labels: [], cites: [], files: [], images: [], packages: [], bibs: [], classes: [] };
export function setProjectData(d) { Object.assign(project, d); }

const cmdOptions = commands.map((c) =>
  snippetCompletion(c.snippet, { label: "\\" + c.name, detail: c.detail, type: "function", boost: 0 }));
const mathOptions = mathSymbols.map(([n, g]) => ({ label: "\\" + n, detail: g, type: "constant", apply: "\\" + n, boost: -1 }));
const envOptions = environments.map((e) => ({ label: e, type: "class", apply: envApply(e) }));

function envApply(name) {
  return (view, completion, from, to) => {
    // `to` is end of the typed prefix; consume an already-present closing brace.
    const after = view.state.sliceDoc(to, to + 1);
    const end = after === "}" ? to + 1 : to;
    const indent = /^\s*/.exec(view.state.doc.lineAt(from).text)[0];
    const body = `${name}}\n${indent}\t\n${indent}\\end{${name}}`;
    view.dispatch({
      changes: { from, to: end, insert: body },
      selection: { anchor: from + name.length + 2 + indent.length + 1 },
      userEvent: "input.complete",
    });
  };
}

function list(opts, re, ctx) {
  const m = ctx.matchBefore(re);
  if (!m) return null;
  return m;
}

// Returns text typed so far inside the braces after the last comma.
function argContext(ctx, cmdRe) {
  const line = ctx.state.doc.lineAt(ctx.pos);
  const before = line.text.slice(0, ctx.pos - line.from);
  const m = new RegExp(cmdRe.source + "([^}]*)$").exec(before);
  if (!m) return null;
  const typed = m[m.length - 1];
  const lastComma = typed.lastIndexOf(",");
  const prefix = typed.slice(lastComma + 1).trimStart();
  return { from: ctx.pos - prefix.length, prefix };
}

export function latexCompletions(ctx) {
  // 1. \begin{<env>
  let a = argContext(ctx, /\\(?:begin|end)\{/);
  if (a) return { from: a.from, options: envOptions, validFor: /^[\w*]*$/ };

  // 2. citations
  a = argContext(ctx, /\\[a-zA-Z]*cite[a-zA-Z]*\*?(?:\[[^\]]*\])*\{/);
  if (a) return {
    from: a.from, validFor: /^[^,}\s]*$/,
    options: project.cites.map((c) => ({ label: c.key, detail: c.detail, info: c.info, type: "text" })),
  };

  // 3. references
  a = argContext(ctx, /\\(?:[a-zA-Z]*ref|eqref|autoref|cref|Cref|nameref|vref)\*?\{/);
  if (a) return {
    from: a.from, validFor: /^[^,}\s]*$/,
    options: project.labels.map((l) => ({ label: l.key, detail: l.detail, type: "variable" })),
  };

  // 4. files
  a = argContext(ctx, /\\(?:input|include|subfile|subimport)\{/);
  if (a) return { from: a.from, options: project.files.map((f) => ({ label: f.replace(/\.tex$/, ""), type: "file" })) };
  a = argContext(ctx, /\\includegraphics(?:\[[^\]]*\])?\{/);
  if (a) return { from: a.from, options: project.images.map((f) => ({ label: f, type: "file" })) };
  a = argContext(ctx, /\\(?:bibliography|addbibresource)\{/);
  if (a) return { from: a.from, options: project.bibs.map((f) => ({ label: f.replace(/\.bib$/, ""), type: "file" })) };

  // 5. packages / classes / styles / tikz libraries
  a = argContext(ctx, /\\(?:usepackage|RequirePackage)(?:\[[^\]]*\])?\{/);
  if (a) return { from: a.from, options: project.packages.map((p) => ({ label: p, type: "namespace" })) };
  a = argContext(ctx, /\\documentclass(?:\[[^\]]*\])?\{/);
  if (a) return { from: a.from, options: [...new Set([...classes, ...project.classes])].map((p) => ({ label: p, type: "namespace" })) };
  a = argContext(ctx, /\\bibliographystyle\{/);
  if (a) return { from: a.from, options: bibStyles.map((p) => ({ label: p, type: "namespace" })) };
  a = argContext(ctx, /\\usetikzlibrary\{/);
  if (a) return { from: a.from, options: tikzLibraries.map((p) => ({ label: p, type: "namespace" })) };

  // 6. commands and math symbols
  const w = ctx.matchBefore(/\\[a-zA-Z@]*/);
  if (w && (w.to - w.from >= 2 || ctx.explicit)) {
    return { from: w.from, options: [...cmdOptions, ...mathOptions], validFor: /^\\[a-zA-Z@]*$/ };
  }
  return null;
}
