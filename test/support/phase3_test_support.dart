// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';

import 'document_model_test_support.dart';
import 'uuid_sequence_generator.dart';

/// Unwraps a successful command-contract construction result.
T commandValue<T>(Result<T, StructuredFailure> result) =>
    (result as Ok<T, StructuredFailure>).value;

/// Standard fully editable Phase 3 test Registry.
ObjectRegistry editableTestRegistry() => testRegistry([
  TestObjectTypeDefinition(
    capabilities: const ObjectTypeCapabilities(
      hasIntrinsicGeometry: true,
      discoversResourceReferences: false,
      supportsScopedDuplication: true,
      selectable: true,
      movable: true,
      resizable: true,
      rotatable: true,
    ),
  ),
]);

/// Creates a one-Page Notebook with two editable test Objects.
NotebookDocument phase3Notebook({
  ObjectEnvelope? first,
  ObjectEnvelope? second,
  ResourceCatalog? resources,
  bool layerVisible = true,
  bool layerLocked = false,
}) => testNotebook(
  resources: resources,
  sections: [
    testSection(
      pages: [
        testPage(
          layers: [
            testContentLayer(
              visible: layerVisible,
              locked: layerLocked,
              objects: [first ?? testObject(), second ?? testObject(id: 2)],
            ),
          ],
        ),
      ],
    ),
  ],
);

/// Deterministic estimator returning [bytes] for every entry.
final class FixedHistoryCostEstimator implements HistoryRetainedCostEstimator {
  /// Creates a fixed estimator.
  FixedHistoryCostEstimator(this.bytes);

  /// Returned byte count.
  final int bytes;
  @override
  Result<HistoryRetainedCost, StructuredFailure> estimate(
    HistoryCostEstimateInput input,
  ) => HistoryRetainedCost.create(bytes);
}

/// Creates a coordinator with enough deterministic content identities.
DocumentMutationCoordinator phase3Coordinator({
  NotebookDocument? root,
  ObjectRegistry? registry,
  int historyCount = 10,
  int historyBytes = 10000,
  int estimatedEntryBytes = 100,
}) {
  final validator = DocumentValidator(registry ?? editableTestRegistry());
  final generator = UuidSequenceGenerator.fromValues([
    for (var value = 100; value < 140; value += 1) testUuid(value),
  ]);
  return (DocumentMutationCoordinator.create(
            initialRoot: root ?? phase3Notebook(),
            validator: validator,
            uuidGenerator: generator,
            historyLimits: commandValue(
              HistoryLimits.create(
                maximumRetainedCommandCount: historyCount,
                maximumEstimatedRetainedBytes: historyBytes,
              ),
            ),
            retainedCostEstimator: FixedHistoryCostEstimator(
              estimatedEntryBytes,
            ),
          )
          as Ok<DocumentMutationCoordinator, CommandFailure>)
      .value;
}

/// Standard deterministic command metadata.
CommandMetadata phase3Metadata({
  String family = 'alnote.commands.object.replace',
  int correlation = 200,
  String description = 'Sensitive description',
  CommandCoalescing? coalescing,
}) => CommandMetadata(
  family: commandValue(CommandFamily.parse(family)),
  correlationId: CommandCorrelationId.fromUuid(testUuid(correlation)),
  description: description,
  coalescing: coalescing,
);

/// Scoped preconditions for one Object using the current snapshot.
RevisionPreconditions objectPreconditions(
  DocumentCoordinatorSnapshot snapshot,
  ObjectId objectId,
) {
  final layer = snapshot.root.pages
      .expand((page) => page.layers)
      .singleWhere(
        (layer) => layer.objects.any((object) => object.id == objectId),
      );
  return RevisionPreconditions(
    objects: {objectId: snapshot.revisions.objects[objectId]!},
    layerMembership: {layer.id: snapshot.revisions.layerMembership[layer.id]!},
  );
}

/// Builds a same-ID replacement with a new preserved string payload.
ObjectEnvelope replacementObject(ObjectEnvelope source, String payload) =>
    modelValue(
      ObjectEnvelope.create(
        id: source.id,
        typeKey: source.typeKey,
        envelopeVersion: source.envelopeVersion,
        typeSchemaVersion: source.typeSchemaVersion,
        transform: source.transform,
        visible: source.visible,
        locked: source.locked,
        payload: PreservedString(payload),
        extensionData: source.extensionData,
      ),
    );
