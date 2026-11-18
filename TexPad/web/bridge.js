// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors
//
// Bridge between Swift (callAsyncJavaScript) and the SwiftLaTeX WebAssembly workers.
// Swift decides *what* to run (see RecipeRunner); this file only runs one step at a time.
(function () {
  const SCRIPTS = { pdftex: "swiftlatexpdftex.js" };
  const workers = {};   // engine name -> { worker, pending }

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
      if (spec.reset) e.worker.postMessage({ cmd: "flushcache" });
      for (const d of spec.dirs || []) await request(e, { cmd: "mkdir", url: d }, "mkdir");
      for (const [name, b64] of Object.entries(spec.files || {}))
        await request(e, { cmd: "writefile", url: name, src: b64ToBytes(b64) }, "writefile");
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
      const ok = r.result === "ok";
      return {
        ok, status: r.status, log: r.log, ms: Math.round(performance.now() - t0),
        pdf: ok && r.pdf && spec.op === "latex" ? bytesToB64(new Uint8Array(r.pdf)) : null,
        fmt: ok && r.pdf && spec.op === "format" ? bytesToB64(new Uint8Array(r.pdf)) : null,
      };
    },
  };
})();
