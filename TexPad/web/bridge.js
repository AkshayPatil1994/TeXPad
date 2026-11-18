// Bridge between Swift (callAsyncJavaScript) and the SwiftLaTeX pdfTeX worker.
(function () {
  let worker = null;
  let pending = null; // {cmd, resolve}

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
  function request(msg, waitCmd) {
    return new Promise((resolve) => {
      pending = { cmd: waitCmd, resolve };
      worker.postMessage(msg);
    });
  }

  window.tex = {
    async load() {
      await new Promise((resolve, reject) => {
        worker = new Worker("swiftlatexpdftex.js");
        worker.onerror = (e) => reject(new Error("worker error: " + (e.message || e)));
        worker.onmessage = (ev) => {
          if (ev.data.result === "ok" && !ev.data.cmd) {
            worker.onmessage = (e) => {
              const d = e.data;
              if (pending && d.cmd === pending.cmd) {
                const p = pending; pending = null; p.resolve(d);
              }
            };
            resolve();
          } else reject(new Error("engine init failed"));
        };
      });
      return "loaded";
    },
    // Full build. files: { "path/name.tex": base64 } (only changed files unless reset),
    // dirs: ["sub"], main: "main.tex", reset: wipe engine FS first, maxPasses: rerun cap.
    async build(files, dirs, main, reset, maxPasses) {
      if (reset) worker.postMessage({ cmd: "flushcache" });
      for (const d of dirs) await request({ cmd: "mkdir", url: d }, "mkdir");
      for (const [name, b64] of Object.entries(files))
        await request({ cmd: "writefile", url: name, src: b64ToBytes(b64) }, "writefile");
      worker.postMessage({ cmd: "setmainfile", url: main });
      const t0 = performance.now();
      let r = null, passes = 0, logs = [];
      const needRerun = (log) => /Rerun to get|Label\(s\) may have changed|Please \(re\)run/.test(log) ||
        (passes === 1 && /Citation `[^']*' on page \d+ undefined|There were undefined (citations|references)|Reference `[^']*' on page \d+ undefined/.test(log));
      do {
        r = await request({ cmd: "compilelatex" }, "compile");
        passes++;
        logs.push(r.log);
      } while (r.result === "ok" && passes < (maxPasses || 3) && needRerun(r.log));
      return {
        ok: r.result === "ok", status: r.status, log: r.log, passes,
        ms: Math.round(performance.now() - t0),
        pdf: r.result === "ok" ? bytesToB64(new Uint8Array(r.pdf)) : null,
      };
    },
    async compileFormat(files, dirs) {
      const r = await request({ cmd: "compileformat" }, "compile");
      return {
        ok: r.result === "ok", status: r.status, log: r.log,
        fmt: r.result === "ok" ? bytesToB64(new Uint8Array(r.pdf)) : null,
      };
    },
  };
})();
