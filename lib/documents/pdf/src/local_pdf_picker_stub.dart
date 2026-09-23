// SPDX-License-Identifier: GPL-3.0-or-later
import '../../../core/outcomes/cancellation.dart';
import '../pdf_file_selection.dart';

LocalPdfPickerHost createHost() => _UnavailablePicker();

final class _UnavailablePicker implements LocalPdfPickerHost {
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async => throw const LocalPdfRouteUnavailableException();
}
