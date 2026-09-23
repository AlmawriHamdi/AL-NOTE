// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only instrumentation around actual WASM calls. No production test hooks.
const pdfiumWasmUrl = new URL('pdfium.wasm', location.href).href;
importScripts('pdfium_worker.js');

functions.checkCleanup = async ({ baseUrl }) => {
  const actual = Pdfium.wasmExports;
  const live = new Set();
  const forms = new Map();
  const allocations = new Set();
  const buffers = new Map();
  const availDocs = new Map();
  const counts = { opens: 0, closes: 0, formOpens: 0, formCloses: 0,
    backingReleases: 0, mallocs: 0, frees: 0, rangeOpens: 0, rangeDestroys: 0 };
  const failures = [];
  let fault = '';
  const require = (condition, message) => {
    if (!condition) failures.push(message);
  };
  const opened = (handle, buffer) => {
    if (handle) {
      require(!live.has(handle), 'duplicate live document');
      live.add(handle);
      counts.opens++;
      if (buffer) buffers.set(handle, buffer);
    }
    return handle;
  };
  Pdfium.wasmExports = { ...actual,
    malloc: (size) => {
      if (fault === 'formMalloc' && size === 140) return 0;
      const ptr = actual.malloc(size);
      if (ptr) { allocations.add(ptr); counts.mallocs++; }
      return ptr;
    },
    free: (ptr) => {
      if (ptr) {
        require(![...buffers.values()].includes(ptr), 'backing freed before close');
        require(![...forms.values()].some((v) => v.ptr === ptr), 'form info freed before exit');
        require(allocations.delete(ptr), 'unbalanced/double JS free');
        counts.frees++;
      }
      return actual.free(ptr);
    },
    FPDF_LoadMemDocument: (...args) => opened(actual.FPDF_LoadMemDocument(...args), args[0]),
    FPDF_LoadDocument: (...args) => opened(actual.FPDF_LoadDocument(...args)),
    FPDFAvail_GetDocument: (...args) => {
      const doc = opened(actual.FPDFAvail_GetDocument(...args));
      if (doc) { availDocs.set(args[0], doc); counts.rangeOpens++; }
      return doc;
    },
    FPDFAvail_Destroy: (avail) => {
      require(!live.has(availDocs.get(avail)), 'range backing released before close');
      if (availDocs.delete(avail)) counts.rangeDestroys++;
      return actual.FPDFAvail_Destroy(avail);
    },
    FPDF_GetPageCount: (...args) => {
      if (fault === 'pageCount') throw new Error('injected page count');
      return actual.FPDF_GetPageCount(...args);
    },
    FPDFDOC_InitFormFillEnvironment: (doc, ptr) => {
      if (fault === 'formInit') throw new Error('injected form init');
      const form = actual.FPDFDOC_InitFormFillEnvironment(doc, ptr);
      if (form) { forms.set(form, { doc, ptr }); counts.formOpens++; }
      return form;
    },
    FPDFDOC_ExitFormFillEnvironment: (form) => {
      require(live.has(forms.get(form)?.doc), 'form exited after document close');
      require(forms.delete(form), 'double/unknown form exit');
      counts.formCloses++;
      actual.FPDFDOC_ExitFormFillEnvironment(form);
      if (fault === 'formExit') throw new Error('injected post-exit exception');
    },
    FPDF_LoadPage: (...args) => fault === 'pageLoad' ? 0 : actual.FPDF_LoadPage(...args),
    FPDF_GetPageBoundingBox: (...args) => fault === 'bounds' ? 0 : actual.FPDF_GetPageBoundingBox(...args),
    FPDF_CloseDocument: (doc) => {
      require(![...forms.values()].some((v) => v.doc === doc), 'document closed before form');
      require(live.delete(doc), 'double/unknown document close');
      buffers.delete(doc);
      counts.closes++;
      return actual.FPDF_CloseDocument(doc);
    },
  };
  const originalLoad = _loadDocument;
  _loadDocument = (doc, progressive, release) => {
    let released = false;
    return originalLoad(doc, progressive, () => {
      require(!released, 'double backing release');
      require(!live.has(doc), 'backing released with live document');
      require(!missingFonts[doc] && !disposers[doc], 'document maps retained at release');
      released = true;
      counts.backingReleases++;
      release();
    });
  };
  const originalUpdate = _updateMissingFonts;
  _updateMissingFonts = (doc) => {
    if (fault === 'fonts') throw new Error('injected font update');
    return originalUpdate(doc);
  };
  const valid = await (await fetch(`${baseUrl}/valid.pdf`)).arrayBuffer();
  const disjoint = await (await fetch(`${baseUrl}/disjoint.pdf`)).arrayBuffer();
  const rows = [];
  const load = async (mode, data, name) => {
    if (mode === 'range') return loadDocumentFromUrlWithRangeAccess({
      url: `${baseUrl}/${name}.pdf`, password: '', useProgressiveLoading: false,
      headers: {}, withCredentials: false,
    });
    if (mode === 'file') {
      const padded = new Uint8Array(1024 * 1024 + 1).fill(32);
      padded.set(new Uint8Array(data));
      data = padded.buffer;
    }
    return loadDocumentFromData({ data, useProgressiveLoading: false });
  };
  // Keep a successful document alive while other initialization attempts fail.
  const keeper = await load('memory', valid, 'valid');
  missingFonts[keeper.docHandle] = { controlled: { face: 'fixture' } };
  for (const mode of ['memory', 'file', 'range']) {
    for (let repeat = 0; repeat < 3; repeat++) {
      for (const stage of ['disjoint', 'pageCount', 'formMalloc', 'formInit', 'pageLoad', 'bounds', 'fonts', 'formExit']) {
        fault = stage === 'disjoint' ? '' : stage;
        let rejected = false;
        const before = { ...counts };
        try {
          const result = await load(mode,
            stage === 'disjoint' || stage === 'formExit' ? disjoint : valid,
            stage === 'disjoint' || stage === 'formExit' ? 'disjoint' : 'valid');
          if (result?.docHandle) closeDocument(result);
        } catch (_) { rejected = true; }
        require(rejected, `${mode}/${stage}: expected initialization failure`);
        require(counts.opens - before.opens === 1, `${mode}/${stage}: one actual open`);
        require(counts.closes - before.closes === 1, `${mode}/${stage}: one close`);
        require(live.size === 1 && live.has(keeper.docHandle), `${mode}/${stage}: leaked document`);
        require(missingFonts[keeper.docHandle]?.controlled, 'other document fonts erased');
        require(Object.keys(disposers).length === 1, 'disposer map leak');
        require(Object.keys(missingFonts).length === 1, 'font map leak');
        require(Object.keys(rangeDocumentAvailabilities).length === 0, 'range map leak');
        rows.push({ mode, stage, repeat, rejected });
      }
    }
  }
  fault = '';
  // Null document errors still release backing; they must not close handle 0.
  for (const mode of ['memory', 'file']) {
    const before = counts.closes;
    const result = await load(mode, new Uint8Array([1, 2, 3]).buffer, 'invalid');
    require(!result.docHandle && result.errorCode, 'invalid bytes must return error');
    require(counts.closes === before, 'null handle closed');
  }
  for (const mode of ['memory', 'file', 'range']) {
    const doc = await load(mode, valid, 'valid');
    require(doc?.docHandle, `${mode}: success`);
    closeDocument(doc);
    closeDocument(doc); // Ownership was consumed; no WASM double disposal.
  }
  closeDocument(keeper);
  closeDocument(keeper);
  require(live.size === 0 && forms.size === 0 && allocations.size === 0, 'final resources leaked');
  require(Object.keys(disposers).length === 0 && Object.keys(missingFonts).length === 0 &&
    Object.keys(rangeDocumentAvailabilities).length === 0, 'final maps leaked');
  require(counts.opens === counts.closes && counts.formOpens === counts.formCloses &&
    counts.mallocs === counts.frees && counts.rangeOpens === counts.rangeDestroys, 'unbalanced totals');
  return { pass: failures.length === 0, counts, failures, rows };
};
