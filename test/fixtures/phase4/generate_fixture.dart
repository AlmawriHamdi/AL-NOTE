// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/files.dart';

import '../../support/document_model_test_support.dart';
import '../../support/phase4_test_support.dart';

/// Regenerates the reviewed canonical Notebook package fixture.
void main() {
  final snapshot =
      (AlnotePackageSnapshot.create(
                document: testNotebook(),
                resources: const <DocumentResourceSnapshot>[],
              )
              as Ok<AlnotePackageSnapshot, StructuredFailure>)
          .value;
  final bytes =
      (AlnotePackageCodec(
                objectRegistry: testRegistry(),
              ).encode(snapshot, limits: phase4Limits())
              as Ok<List<int>, StructuredFailure>)
          .value;
  File(
    'test/fixtures/phase4/canonical_notebook.alnote',
  ).writeAsBytesSync(bytes, flush: true);
}
