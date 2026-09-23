// SPDX-License-Identifier: GPL-3.0-or-later
import '../../core/outcomes/cancellation.dart';
import 'pdf_backend.dart';
import 'pdf_fixture_admission.dart';

/// Application composition authority. Never reconstructed from document data.
abstract interface class PdfAdmissionPolicy {
  PdfInputTrust get trust;
  bool get ordinaryInputEnabled;
  bool permits(List<int> immutableBytes, CancellationToken token);
}

/// Optional capability supplied only by a composed backend, not request data.
abstract interface class PdfAdmissionProvider {
  PdfAdmissionPolicy get admissionPolicy;
}

PdfAdmissionPolicy pdfAdmissionFor(PdfBackend backend) =>
    backend is PdfAdmissionProvider
    ? (backend as PdfAdmissionProvider).admissionPolicy
    : const FixturePdfAdmissionPolicy();

final class FixturePdfAdmissionPolicy implements PdfAdmissionPolicy {
  const FixturePdfAdmissionPolicy();
  @override
  PdfInputTrust get trust => PdfInputTrust.trustedDevelopmentFixture;
  @override
  bool get ordinaryInputEnabled => false;
  @override
  bool permits(List<int> bytes, CancellationToken token) =>
      PdfFixtureAdmission.permits(bytes, token);
}

/// Process lifecycle evidence is independent of selected/document bytes.
enum PdfBackendAvailability { available, busy, cleanupPending, unavailable }

final class PdfBackendLifecycle {
  PdfBackendAvailability get availability => _availability;
  PdfBackendAvailability _availability = PdfBackendAvailability.available;
  final _listeners = <void Function()>{};
  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void update(PdfBackendAvailability value) {
    if (_availability == value) return;
    _availability = value;
    for (final listener in List<void Function()>.of(_listeners)) {
      if (!_listeners.contains(listener)) continue;
      try {
        listener();
      } on Object {
        /* Observers cannot release ownership. */
      }
    }
  }
}

abstract interface class PdfLifecycleProvider {
  PdfBackendLifecycle get lifecycle;
}
