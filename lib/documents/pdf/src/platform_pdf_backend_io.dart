// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import '../pdf_backend.dart';
import 'linux/linux_pdf_backend.dart';

PdfBackend? createIsolatedPlatformPdfBackend() =>
    Platform.isLinux ? createLinuxIsolatedPdfBackend() : null;
