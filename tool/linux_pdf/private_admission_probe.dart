// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone conditional-composition negative check. No parser work is invoked.
import '../../lib/core/outcomes/cancellation.dart';
import '../../lib/documents/pdf/pdf_admission_policy.dart';
import '../../lib/documents/pdf/src/platform_pdf_backend_stub.dart'
    if (dart.library.io) '../../lib/documents/pdf/src/platform_pdf_backend_io.dart';

void main() {
  final backend = createIsolatedPlatformPdfBackend();
  final policy = backend == null
      ? const FixturePdfAdmissionPolicy()
      : pdfAdmissionFor(backend);
  final actual = policy.ordinaryInputEnabled;
  const expected = bool.fromEnvironment('EXPECT_PRIVATE_ADMISSION');
  if (actual != expected ||
      policy.permits(
            '%PDF-unregistered'.codeUnits,
            CancellationController().token,
          ) !=
          expected) {
    throw StateError('Private admission gate mismatch');
  }
  // ignore: avoid_print
  print(
    'PRIVATE_ADMISSION enabled=$actual product=${const bool.fromEnvironment('dart.vm.product')} profile=${const bool.fromEnvironment('dart.vm.profile')}',
  );
}
