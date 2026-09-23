// SPDX-License-Identifier: GPL-3.0-or-later
// Instrument standard browser APIs while driving the production host adapter.
(() => {
  const click = HTMLInputElement.prototype.click;
  const slice = Blob.prototype.slice;
  const size = Object.getOwnPropertyDescriptor(Blob.prototype, 'size').get;
  const read = FileReader.prototype.readAsArrayBuffer;
  const abort = FileReader.prototype.abort;
  const createUrl = URL.createObjectURL;
  let mode = '';
  let file;
  let stats;
  globalThis.configureHostCase = (name, length, reported) => {
    mode = name;
    file = new File([new Uint8Array(length).fill(37)], 'private-fixture.pdf');
    if (reported >= 0) Object.defineProperty(file, 'size', { value: reported });
    stats = { slices: [], reads: [], aborts: 0, urls: 0, picks: 0, multiple: false };
  };
  globalThis.registerHostCancellation = (callback) => { globalThis.cancelHostRead = callback; };
  globalThis.hostCaseStats = () => JSON.stringify({ ...stats,
    remainingInputs: document.querySelectorAll('input[type=file]').length });
  HTMLInputElement.prototype.click = function () {
    if (this.type !== 'file') return click.call(this);
    stats.picks++;
    stats.multiple = this.multiple;
    if (mode === 'pickerCancel') {
      this.dispatchEvent(new Event('cancel'));
    } else if (mode === 'tokenPickerCancel') {
      globalThis.cancelHostRead();
    } else {
      const transfer = new DataTransfer();
      transfer.items.add(file);
      this.files = transfer.files;
      this.dispatchEvent(new Event('change'));
    }
  };
  Blob.prototype.slice = function (start, end, ...args) {
    if (mode === 'throwing') throw new Error('private path/content');
    stats.slices.push([start, end]);
    // Simulate a host delivering short chunks. Next offset must use actual
    // delivered bytes; a declared length must not authorize/truncate capture.
    if (mode === 'short') end = Math.min(end, start + 3);
    return slice.call(this, start, end, ...args);
  };
  FileReader.prototype.readAsArrayBuffer = function (blob) {
    const bytes = size.call(blob);
    stats.reads.push(bytes);
    if (blob === file || bytes > 65536) throw new Error('unbounded materialization');
    read.call(this, blob);
    if (mode === 'cancelRead') globalThis.cancelHostRead();
  };
  FileReader.prototype.abort = function () { stats.aborts++; return abort.call(this); };
  URL.createObjectURL = function (blob) {
    if (blob === file) stats.urls++;
    return createUrl.call(this, blob);
  };
  globalThis.reportHostReading = (result) =>
    fetch('/result', { method: 'POST', body: result });
})();
