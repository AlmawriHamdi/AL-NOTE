// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

// Explicit opt-in test build, Linux only, never product/release admission.
bool get linuxIntegrationTestEnabled =>
    Platform.isLinux &&
    !const bool.fromEnvironment('dart.vm.product') &&
    const bool.fromEnvironment('ALNOTE_LINUX_INTEGRATION_TEST');
