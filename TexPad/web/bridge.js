// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors
//
// Bridge between Swift (callAsyncJavaScript) and the SwiftLaTeX WebAssembly workers.
// Swift decides *what* to run (see RecipeRunner); this file only runs one step at a time.
(function () {
  const SCRIPTS = { pdftex: "swiftlatexpdftex.js", xetex: "swiftlatexxetex.js", dvipdfm: "swiftlatexdvipdfm.js" };
  const workers = {};   // engine name -> { worker, pending }
  // XeTeX writes .xdv; a second worker (dvipdfmx) turns it into PDF and needs the project's images, so we remember
  // the files sent to xetex and forward them to dvipdfm lazily.
  const xe = { files: {}, dirs: new Set(), written: new Set(), reset: false };

  function b64ToBytes(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  function bytesToB64(bytes) {
    let s = "";
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk)
      s += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    return btoa(s);
  }

  function startWorker(name) {
    return new Promise((resolve, reject) => {
      const script = SCRIPTS[name];
      if (!script) return reject(new Error("unknown engine " + name));
      const w = new Worker(script);
      const entry = { worker: w, pending: null };
      w.onerror = (e) => reject(new Error("worker error: " + (e.message || e)));
      w.onmessage = (ev) => {
        if (ev.data.result === "ok" && !ev.data.cmd) {
          w.onmessage = (e) => {
            const d = e.data;
            if (entry.pending && d.cmd === entry.pending.cmd) {
              const p = entry.pending; entry.pending = null; p.resolve(d);
            }
          };
          workers[name] = entry;
          resolve(entry);
        } else reject(new Error("engine init failed"));
      };
    });
  }

  async function engine(name) { return workers[name] || startWorker(name); }

  function request(entry, msg, waitCmd) {
    return new Promise((resolve) => {
      entry.pending = { cmd: waitCmd, resolve };
      entry.worker.postMessage(msg);
    });
  }

  window.tex = {
    async load() { await engine("pdftex"); return "loaded"; },

    /**
     * Runs one build step.
     * spec: { engine: "pdftex", op: "latex" | "bibtex" | "format", main: "main.tex",
     *         files: {path: base64}, dirs: [..], reset: bool, produce: bool }
     * `files`/`dirs` are only sent on the first step that uses an engine; `reset` wipes that engine's file system first.
     */
    async run(spec) {
      const e = await engine(spec.engine);
      const t0 = performance.now();
      if (spec.reset) {
        e.worker.postMessage({ cmd: "flushcache" });
        if (spec.engine === "xetex") { xe.files = {}; xe.dirs = new Set(); xe.written = new Set(); xe.reset = true; }
      }
      for (const d of spec.dirs || []) {
        await request(e, { cmd: "mkdir", url: d }, "mkdir");
        if (spec.engine === "xetex") xe.dirs.add(d);
      }
      for (const [name, b64] of Object.entries(spec.files || {})) {
        await request(e, { cmd: "writefile", url: name, src: b64ToBytes(b64) }, "writefile");
        if (spec.engine === "xetex") { xe.files[name] = b64; xe.written.delete(name); }
      }
      if (spec.main) e.worker.postMessage({ cmd: "setmainfile", url: spec.main });

      let r;
      if (spec.op === "latex") {
        r = await request(e, { cmd: "compilelatex", skipBibtex: true, produce: !!spec.produce }, "compile");
      } else if (spec.op === "bibtex") {
        r = await request(e, { cmd: "compilebibtex" }, "compile");
      } else if (spec.op === "format") {
        r = await request(e, { cmd: "compileformat" }, "compile");
      } else {
        throw new Error("unknown op " + spec.op);
      }
      let ok = r.result === "ok", log = r.log, pdf = null, fmt = null;
      if (ok && r.pdf && spec.op === "format") fmt = bytesToB64(new Uint8Array(r.pdf));
      if (ok && r.pdf && spec.op === "latex") {
        if (spec.engine === "xetex") {
          // .xdv -> .pdf in the dvipdfmx worker
          const d = await engine("dvipdfm");
          if (xe.reset) { d.worker.postMessage({ cmd: "flushcache" }); xe.written = new Set(); xe.reset = false; }
          for (const dir of xe.dirs) await request(d, { cmd: "mkdir", url: dir }, "mkdir");
          for (const [name, b64] of Object.entries(xe.files)) {
            if (xe.written.has(name)) continue;
            await request(d, { cmd: "writefile", url: name, src: b64ToBytes(b64) }, "writefile");
            xe.written.add(name);
          }
          const xdv = spec.main.replace(/\.tex$/, "") + ".xdv";
          await request(d, { cmd: "writefile", url: xdv, src: new Uint8Array(r.pdf) }, "writefile");
          d.worker.postMessage({ cmd: "setmainfile", url: spec.main });
          const r2 = await request(d, { cmd: "compilepdf" }, "compile");
          ok = r2.result === "ok";
          log = r.log + "\n--- dvipdfmx ---\n" + r2.log;
          if (ok && r2.pdf) pdf = bytesToB64(new Uint8Array(r2.pdf));
        } else {
          pdf = bytesToB64(new Uint8Array(r.pdf));
        }
      }
      return { ok, status: r.status, log, ms: Math.round(performance.now() - t0), pdf, fmt };
    },
  };
})();
