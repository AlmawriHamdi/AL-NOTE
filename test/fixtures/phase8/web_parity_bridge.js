// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only bridge fault injection, after successful real worker initialization.
globalThis.beginPdfBridgeFailures = () => {
  const communicator = globalThis.PdfiumWasmCommunicator;
  const send = communicator.sendCommand.bind(communicator);
  const counts = { opens: 0, closes: 0 };
  communicator.sendCommand = async (command, ...args) => {
    const result = await send(command, ...args);
    if (command === 'loadDocumentFromData' && result.docHandle) {
      counts.opens++;
      // The worker returned a real document; force Dart evidence decoding to
      // reject it, testing ownership beyond the worker's own init catch.
      result.pages[0].width = 0;
    }
    if (command === 'closeDocument') counts.closes++;
    return result;
  };
  globalThis.endPdfBridgeFailures = () => {
    communicator.sendCommand = send;
    return JSON.stringify(counts);
  };
};
globalThis.reportPdfParity = (result) =>
  fetch('/result/parity', { method: 'POST', body: result });
