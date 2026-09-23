// SPDX-License-Identifier: GPL-3.0-or-later
part of '../widget_test.dart';

void _pdfSourceStyleChecks() {
  for (final unavailable in [false, true]) {
    testWidgets(
      'PDF source style Save/Reopen cache and annotation pixels unavailable=$unavailable',
      (tester) async {
        final gateway = _PdfStyleGateway();
        final backend = _WidgetPdfBackend(
          _widgetPdfModelLimits(),
          failRender: unavailable,
          rgbaColor: const [255, 0, 0, 255],
        );
        final runtime = _runtime(
          reopenGateway: gateway,
          pdfBackend: backend,
          pdfProcessingLimits: _widgetPdfProcessingLimits(),
          localPdfOpenWorkflow: LocalPdfOpenWorkflow(
            selector: LocalPdfFileSelector(
              host: _WidgetPdfPicker(
                File('test/fixtures/phase8/admitted/blank-workflow.pdf')
                    .readAsBytesSync(),
              ),
            ),
            backend: backend,
            modelLimits: _widgetPdfModelLimits(),
            processingLimits: _widgetPdfProcessingLimits(),
          ),
        );
        gateway.runtime = runtime;
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        await tester.ensureVisible(find.byKey(const Key('open-pdf')));
        await tester.tap(find.byKey(const Key('open-pdf')));
        await _waitPdf(
          tester,
          () => unavailable
              ? _documentPainter(tester).displaysPdfPlaceholder
              : _documentPainter(tester).hasRenderedPdfPage,
        );
        final clip = _documentPainter(tester).pageClip!;
        final origin = tester.getTopLeft(
          find.byKey(const Key('phase6-canvas-listener')),
        );
        final center =
            origin +
            Offset((clip.left + clip.right) / 2, (clip.top + clip.bottom) / 2);
        final gesture = await tester.startGesture(
          center - const Offset(20, 0),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(center + const Offset(20, 0));
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save in memory'));
        await tester.pumpAndSettle();
        final before = await _canvasImage(tester);
        final sample = Offset(
          clip.left + (clip.right - clip.left) * 0.2,
          clip.top + (clip.bottom - clip.top) * 0.4,
        );
        List<int> pixel(_CanvasImageEvidence image, Offset point) {
          final p = origin + point - image.origin;
          final i = (p.dy.floor() * image.width + p.dx.floor()) * 4;
          return image.bytes.sublist(i, i + 3);
        }

        final base = pixel(before, sample);
        final annotationPoint = center - origin;
        final annotation = pixel(before, annotationPoint);
        expect(annotation, isNot(base));
        for (final style in [
          (true, 0.5),
          (true, 0.0),
          (false, 1.0),
          (true, 1.0),
        ]) {
          gateway.style = style;
          final calls = backend.renderedPageIndexes.length;
          await tester.tap(find.text('Reopen saved'));
          await tester.pumpAndSettle();
          await _waitPdf(
            tester,
            () => unavailable
                ? _documentPainter(tester).displaysPdfPlaceholder
                : _documentPainter(tester).hasRenderedPdfPage,
          );
          final styled = await _canvasImage(tester);
          final alpha = style.$1 ? (style.$2 * 255).round() / 255 : 0.0;
          for (var c = 0; c < 3; c++) {
            expect(
              pixel(styled, sample)[c],
              closeTo(255 + (base[c] - 255) * alpha, 1),
            );
          }
          expect(pixel(styled, annotationPoint), annotation);
          if (!unavailable)
            expect(
              backend.renderedPageIndexes.length,
              greaterThan(calls),
              reason: 'Replacement invalidates the old image cache',
            );
          await tester.tap(find.text('Save in memory'));
          await tester.pumpAndSettle();
          gateway.style = null;
          await tester.tap(find.text('Reopen saved'));
          await tester.pumpAndSettle();
          await _waitPdf(
            tester,
            () => unavailable
                ? _documentPainter(tester).displaysPdfPlaceholder
                : _documentPainter(tester).hasRenderedPdfPage,
          );
          final root =
              _documentPainter(tester).currentRoot as StandalonePdfDocument;
          final source = root.pages.first.layers.first as PdfSourceLayer;
          expect(source.visible, style.$1);
          expect(source.opacity, style.$2);
          expect((await _canvasImage(tester)).bytes, styled.bytes);
        }
      },
    );
  }
}

final class _PdfStyleGateway implements Phase6ReopenGateway {
  late Phase6CanvasRuntime runtime;
  final delegate = _runtime().reopenGateway;
  (bool, double)? style;
  @override
  Phase6ReopenOutcome reopen({
    required List<int> bytes,
    required DocumentRoot savedRoot,
  }) {
    final opened = delegate.reopen(
      bytes: bytes,
      savedRoot: savedRoot,
    ) as Phase6ReopenSuccess;
    final change = style;
    if (change == null) return opened;
    final root = opened.root as StandalonePdfDocument;
    final page = root.pages.first;
    final source = page.layers.first as PdfSourceLayer;
    final updated = _ok(
      PdfSourceLayer.create(
        id: source.id,
        envelopeVersion: source.envelopeVersion,
        name: source.name,
        visible: change.$1,
        opacity: change.$2,
        reference: source.reference,
        limits: _widgetPdfModelLimits(),
        extensionData: source.extensionData,
      ),
    );
    final replacement = _ok(
      DocumentPage.create(
        id: page.id,
        name: page.name,
        size: page.size,
        layers: [updated, ...page.layers.skip(1)],
        extensionData: page.extensionData,
      ),
    );
    final document = _ok(
      StandalonePdfDocument.create(
        id: root.id,
        schemaVersion: root.schemaVersion,
        title: root.title,
        resources: root.resources,
        extensionData: root.extensionData,
        pages: [replacement, ...root.pages.skip(1)],
        source: root.source,
      ),
    );
    final snapshot = _ok(
      AlnotePackageSnapshot.create(
        document: document,
        resources: opened.coordinator.snapshot.resources,
      ),
    );
    final coordinator = runtime.createCoordinator(
      snapshot.document,
      resources: snapshot.resources,
    ) as Ok<DocumentMutationCoordinator, CommandFailure>;
    return Phase6ReopenSuccess(root: document, coordinator: coordinator.value);
  }
}
