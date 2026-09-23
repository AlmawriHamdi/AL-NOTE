// SPDX-License-Identifier: GPL-3.0-or-later

/// Backend-neutral persistent and derived PDF System contracts.
library;

export 'pdf/pdf_backend.dart';
export 'pdf/pdf_file_selection.dart';
export 'pdf/pdf_fixture_admission.dart';
export 'pdf/pdf_model.dart';
export 'pdf/pdf_open_workflow.dart';
export 'pdf/src/application_pdf_backend.dart' show createApplicationPdfBackend;
export 'pdf/src/file_selector_local_pdf_adapter.dart'
    show
        createPlatformLocalPdfPickerHost,
        platformLocalPdfOpeningAvailable,
        platformLocalPdfOpeningStatus;
export 'pdf/src/pdfrx_pdf_backend_adapter.dart'
    show createTrustedDevelopmentPdfBackend;
