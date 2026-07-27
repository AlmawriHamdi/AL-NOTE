// SPDX-License-Identifier: GPL-3.0-or-later

import 'document_root.dart';
import 'identifiers.dart';

/// An immutable deterministic index of typed identities in a destination.
///
/// Duplication callers supply a complete destination scope so generated
/// identities can be proven fresh before any candidate is returned.
final class DocumentIdentityScope {
  /// Creates a scope by defensively copying and ordering every identity input.
  DocumentIdentityScope({
    Iterable<DocumentId> documentIds = const <DocumentId>[],
    Iterable<SectionId> sectionIds = const <SectionId>[],
    Iterable<PageId> pageIds = const <PageId>[],
    Iterable<LayerId> layerIds = const <LayerId>[],
    Iterable<ObjectId> objectIds = const <ObjectId>[],
  }) : documentIds = _orderedSet(
         documentIds,
         (left, right) => left.uuid.value.compareTo(right.uuid.value),
       ),
       sectionIds = _orderedSet(
         sectionIds,
         (left, right) => left.uuid.value.compareTo(right.uuid.value),
       ),
       pageIds = _orderedSet(
         pageIds,
         (left, right) => left.uuid.value.compareTo(right.uuid.value),
       ),
       layerIds = _orderedSet(
         layerIds,
         (left, right) => left.uuid.value.compareTo(right.uuid.value),
       ),
       objectIds = _orderedSet(
         objectIds,
         (left, right) => left.uuid.value.compareTo(right.uuid.value),
       );

  /// Creates a complete typed identity index from [document].
  factory DocumentIdentityScope.fromDocument(DocumentRoot document) {
    final sectionIds = <SectionId>[];
    final pageIds = <PageId>[];
    final layerIds = <LayerId>[];
    final objectIds = <ObjectId>[];
    if (document is NotebookDocument) {
      sectionIds.addAll(document.sections.map((section) => section.id));
    }
    for (final page in document.pages) {
      pageIds.add(page.id);
      for (final layer in page.layers) {
        layerIds.add(layer.id);
        objectIds.addAll(layer.objects.map((object) => object.id));
      }
    }
    return DocumentIdentityScope(
      documentIds: <DocumentId>[document.id],
      sectionIds: sectionIds,
      pageIds: pageIds,
      layerIds: layerIds,
      objectIds: objectIds,
    );
  }

  /// Document identities in deterministic order.
  final Set<DocumentId> documentIds;

  /// Section identities in deterministic order.
  final Set<SectionId> sectionIds;

  /// Page identities in deterministic order.
  final Set<PageId> pageIds;

  /// Layer identities in deterministic order.
  final Set<LayerId> layerIds;

  /// Object identities in deterministic order.
  final Set<ObjectId> objectIds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocumentIdentityScope &&
          _setsEqual(documentIds, other.documentIds) &&
          _setsEqual(sectionIds, other.sectionIds) &&
          _setsEqual(pageIds, other.pageIds) &&
          _setsEqual(layerIds, other.layerIds) &&
          _setsEqual(objectIds, other.objectIds);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(documentIds),
    Object.hashAll(sectionIds),
    Object.hashAll(pageIds),
    Object.hashAll(layerIds),
    Object.hashAll(objectIds),
  );

  @override
  String toString() =>
      'DocumentIdentityScope(documents: ${documentIds.length}, '
      'sections: ${sectionIds.length}, pages: ${pageIds.length}, '
      'layers: ${layerIds.length}, objects: ${objectIds.length})';
}

Set<T> _orderedSet<T>(
  Iterable<T> source,
  int Function(T left, T right) compare,
) {
  final copied = Set<T>.of(source).toList()..sort(compare);
  return Set<T>.unmodifiable(copied);
}

bool _setsEqual<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);
