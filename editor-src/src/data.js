// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import commandsText from "./commands.txt";
// Command entries: "name|snippet|detail". In snippets ${1} are tab stops; ⏎ = newline, ⇥ = tab.
export const commands = commandsText.trim().split("\n").map((l) => {
  const [n, t, d] = l.split("|");
  const snippet = (t || "\\" + n).replace(/⏎/g, "\n").replace(/⇥/g, "\t");
  return { name: n, snippet, detail: d || "" };
});


export const environments = String.raw`document abstract itemize enumerate description equation equation* align align* gather gather* multline multline* split cases array matrix pmatrix bmatrix Bmatrix vmatrix Vmatrix smallmatrix figure figure* table table* tabular tabular* tabularx longtable center flushleft flushright minipage verbatim verbatim* quote quotation verse theorem lemma proposition corollary definition proof remark example tikzpicture lstlisting frame block columns appendix thebibliography subequations eqnarray eqnarray* wrapfigure subfigure sidewaystable sidewaysfigure titlepage`.split(" ");

export const mathSymbols = [
  ["alpha","α"],["beta","β"],["gamma","γ"],["delta","δ"],["epsilon","ϵ"],["varepsilon","ε"],["zeta","ζ"],["eta","η"],["theta","θ"],["vartheta","ϑ"],["iota","ι"],["kappa","κ"],["lambda","λ"],["mu","μ"],["nu","ν"],["xi","ξ"],["pi","π"],["varpi","ϖ"],["rho","ρ"],["varrho","ϱ"],["sigma","σ"],["varsigma","ς"],["tau","τ"],["upsilon","υ"],["phi","ϕ"],["varphi","φ"],["chi","χ"],["psi","ψ"],["omega","ω"],
  ["Gamma","Γ"],["Delta","Δ"],["Theta","Θ"],["Lambda","Λ"],["Xi","Ξ"],["Pi","Π"],["Sigma","Σ"],["Upsilon","Υ"],["Phi","Φ"],["Psi","Ψ"],["Omega","Ω"],
  ["leq","≤"],["geq","≥"],["neq","≠"],["approx","≈"],["equiv","≡"],["sim","∼"],["simeq","≃"],["cong","≅"],["propto","∝"],["ll","≪"],["gg","≫"],["subset","⊂"],["supset","⊃"],["subseteq","⊆"],["supseteq","⊇"],["in","∈"],["notin","∉"],["ni","∋"],["cup","∪"],["cap","∩"],["setminus","∖"],["emptyset","∅"],["varnothing","∅"],
  ["times","×"],["cdot","·"],["div","÷"],["pm","±"],["mp","∓"],["ast","∗"],["star","⋆"],["circ","∘"],["bullet","∙"],["oplus","⊕"],["otimes","⊗"],["odot","⊙"],["wedge","∧"],["vee","∨"],["neg","¬"],["forall","∀"],["exists","∃"],["nexists","∄"],
  ["infty","∞"],["partial","∂"],["nabla","∇"],["hbar","ℏ"],["ell","ℓ"],["Re","ℜ"],["Im","ℑ"],["aleph","ℵ"],["angle","∠"],["perp","⊥"],["parallel","∥"],["prime","′"],["degree","°"],
  ["to","→"],["rightarrow","→"],["leftarrow","←"],["leftrightarrow","↔"],["Rightarrow","⇒"],["Leftarrow","⇐"],["Leftrightarrow","⇔"],["mapsto","↦"],["longrightarrow","⟶"],["longleftarrow","⟵"],["implies","⟹"],["iff","⟺"],["uparrow","↑"],["downarrow","↓"],["hookrightarrow","↪"],["rightharpoonup","⇀"],
  ["ldots","…"],["cdots","⋯"],["vdots","⋮"],["ddots","⋱"],["langle","⟨"],["rangle","⟩"],["lceil","⌈"],["rceil","⌉"],["lfloor","⌊"],["rfloor","⌋"],["lbrace","{"],["rbrace","}"],["mid","∣"],["vert","|"],["Vert","‖"],
  ["bigcup","⋃"],["bigcap","⋂"],["bigoplus","⨁"],["bigotimes","⨂"],["bigvee","⋁"],["bigwedge","⋀"],["coprod","∐"],["triangle","△"],["square","□"],["blacksquare","■"],["checkmark","✓"],["dagger","†"],["ddagger","‡"],["S","§"],["P","¶"],["copyright","©"],
];

export const bibStyles = ["plain", "unsrt", "abbrv", "alpha", "acm", "ieeetr", "siam", "apalike"];
export const tikzLibraries = "arrows arrows.meta automata backgrounds calc decorations.pathmorphing decorations.markings fit matrix patterns positioning shapes shapes.geometric shapes.misc trees through intersections quotes angles mindmap shadows chains petri".split(" ");
export const classes = "article report book letter beamer amsart amsbook memoir scrartcl scrreprt scrbook standalone IEEEtran revtex4-2 llncs elsarticle".split(" ");
