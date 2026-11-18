#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 TexPad contributors
"""Vendors the SwiftLaTeX WebAssembly engines into TexPad/web, applying TexPad's patches.

Downloads the pinned upstream release, verifies its SHA-256, then writes
  swiftlatex{pdftex,xetex,dvipdfm}.{js,wasm}
with the patches documented in docs/ENGINE_PROVENANCE.md. Prints the resulting hashes.
"""
import hashlib, io, os, sys, urllib.request, zipfile

URL = "https://github.com/SwiftLaTeX/SwiftLaTeX/releases/download/v20022022/20-02-2022.zip"
ZIP_SHA256 = "cf5535ffe9cdf42f7c4522e96bba4d33db10c418a7ceb24e5d80504be7de7150"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "TexPad", "web")


def sha(b): return hashlib.sha256(b).hexdigest()


def sub(s, old, new, label, count=1):
    n = s.count(old)
    if n != count:
        sys.exit(f"patch '{label}': expected {count} match(es), found {n}")
    return s.replace(old, new)


def common(s, name):
    # 1. files come from the app bundle, not a remote server
    s = sub(s, "https://texlive2.swiftlatex.com/", "tex://app/tl/", f"{name}: endpoint")
    # 2. our scheme handler answers 404 for missing files
    return sub(s, "status===301", "status===404", f"{name}: 404", count=s.count("status===301"))


def latex_routine(s, name, reads_after_bibtex):
    """compileLaTeXRoutine(opts): optional BibTeX, optional output read; plus a standalone compilebibtex message."""
    s = sub(s, "function compileLaTeXRoutine(){", "function compileLaTeXRoutine(opts){", f"{name}: routine signature")
    skip = 'if(!(opts&&opts.skipBibtex)){_compileBibtex()}if(opts&&opts.produce===false){self.postMessage({"result":"ok","status":status,"log":self.memlog,"cmd":"compile"});return}'
    s = sub(s, reads_after_bibtex[0], reads_after_bibtex[1].replace("@SKIP@", skip), f"{name}: bibtex/produce")
    bib = ('function compileBibtexRoutine(){prepareExecutionContext();const setMainFunction=cwrap("setMainEntry","number",["string"]);'
           'setMainFunction(self.mainfile);let status=_compileBibtex();'
           'self.postMessage({"result":status<=1?"ok":"failed","status":status,"log":self.memlog,"cmd":"compile"})}')
    return sub(s, 'self["onmessage"]=function(ev){let data=ev["data"];let cmd=data["cmd"];if(cmd==="compilelatex"){compileLaTeXRoutine()}',
               bib + 'self["onmessage"]=function(ev){let data=ev["data"];let cmd=data["cmd"];if(cmd==="compilelatex"){compileLaTeXRoutine(data)}else if(cmd==="compilebibtex"){compileBibtexRoutine()}',
               f"{name}: messages")


def mount_fonts(s):
    """The 2022 XeTeX build opens fonts with FT_New_Face on the virtual file system. Mount every bundled font as an
    Emscripten *lazy* file (downloaded from the app on first read) under /fonts; the app generates xetexfontlist.txt
    with matching /fonts/<file> paths."""
    old = 'Module["preRun"]=function(){FS.mkdir(TEXCACHEROOT);FS.mkdir(WORKROOT)}'
    new = ('Module["preRun"]=function(){FS.mkdir(TEXCACHEROOT);FS.mkdir(WORKROOT);FS.mkdir("/fonts");'
           'try{const x=new XMLHttpRequest;x.open("GET","tex://app/tl/fontlist.json",false);x.send();'
           'if(x.status===200){for(const f of JSON.parse(x.responseText)){'
           'try{FS.createLazyFile("/fonts",f,"tex://app/tl/fontfile/"+encodeURIComponent(f),true,false)}catch(e){}}}}catch(e){console.log("font mount failed")}}')
    return sub(s, old, new, "xetex: font mount")


def main():
    zdata = urllib.request.urlopen(URL, timeout=60).read()
    if sha(zdata) != ZIP_SHA256:
        sys.exit(f"release zip hash mismatch: {sha(zdata)}")
    z = zipfile.ZipFile(io.BytesIO(zdata))
    os.makedirs(OUT, exist_ok=True)
    for eng in ("pdftex", "xetex", "dvipdfm"):
        wasm = z.read(f"swiftlatex{eng}.wasm")
        js = z.read(f"swiftlatex{eng}.js").decode()
        js = common(js, eng)
        if eng == "pdftex":
            js = latex_routine(js, eng, ("let pdfArrayBuffer=null;_compileBibtex();try{", "let pdfArrayBuffer=null;@SKIP@try{"))
        elif eng == "xetex":
            js = latex_routine(js, eng, ("let pdfArrayBuffer=null;_compileBibtex();let pdfurl=", "let pdfArrayBuffer=null;@SKIP@let pdfurl="))
            js = mount_fonts(js)
        elif eng == "dvipdfm":
            js = mount_fonts(js)    # xdv files reference /fonts/<file>
        open(os.path.join(OUT, f"swiftlatex{eng}.wasm"), "wb").write(wasm)
        open(os.path.join(OUT, f"swiftlatex{eng}.js"), "w").write(js)
        print(f"{eng:8s} wasm {sha(wasm)}  js {sha(js.encode())}")


if __name__ == "__main__":
    main()
