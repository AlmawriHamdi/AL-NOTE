// SPDX-License-Identifier: GPL-3.0-or-later
import '../pdf_backend.dart';
import 'pdfrx_pdf_backend_adapter.dart';
import 'platform_pdf_backend_stub.dart'
    if (dart.library.io) 'platform_pdf_backend_io.dart';

/// Linux always uses isolation, including when its resources/support are absent.
/// Other platforms retain their existing exact-fixture-only adapter.
PdfBackend createApplicationPdfBackend() =>
    createIsolatedPlatformPdfBackend() ?? createTrustedDevelopmentPdfBackend();
