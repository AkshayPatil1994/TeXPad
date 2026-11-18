// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import { build } from "esbuild";
import { readdirSync, writeFileSync, copyFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const out = "../TexPad/web/editor";
mkdirSync(out, { recursive: true });
await build({
  entryPoints: ["src/main.js"], bundle: true, minify: true, sourcemap: false, format: "iife",
  target: ["safari16"], outfile: join(out, "editor.bundle.js"), loader: { ".txt": "text" },
});
copyFileSync("editor.html", join(out, "editor.html"));

// Package / class lists come from the bundled TeX tree so completion matches what can actually compile.
const tl = "../texlive";
if (existsSync(tl)) {
  const files = readdirSync(tl);
  const pk = files.filter((f) => f.endsWith(".sty")).map((f) => f.slice(0, -4)).filter((n) => !n.startsWith("l3") || n === "l3draft").sort();
  const cl = files.filter((f) => f.endsWith(".cls")).map((f) => f.slice(0, -4)).sort();
  writeFileSync(join(out, "packages.json"), JSON.stringify({ packages: pk, classes: cl }));
  console.log(`packages: ${pk.length}, classes: ${cl.length}`);
}
console.log("built editor bundle");
