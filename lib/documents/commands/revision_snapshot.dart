// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import '../model/document_root.dart';
import '../model/identifiers.dart';

/// A closed typed subject of session-only revision evidence.
sealed class RevisionSubject implements Comparable<RevisionSubject> {
  const RevisionSubject._();
  int get _kind;
  String get _uuid;
  @override
  int compareTo(RevisionSubject other) {
    final kind = _kind.compareTo(other._kind);
    return kind != 0 ? kind : _uuid.compareTo(other._uuid);
  }
}

/// The complete Document revision subject.
final class DocumentRevisionSubject extends RevisionSubject {
  /// Creates a typed Document subject.
  const DocumentRevisionSubject(this.id) : super._();

  /// Document identity.
  final DocumentId id;
  @override
  int get _kind => 0;
  @override
  String get _uuid => id.uuid.value;
  @override
  bool operator ==(Object other) =>
      other is DocumentRevisionSubject && other.id == id;
  @override
  int get hashCode => Object.hash(DocumentRevisionSubject, id);
}

/// A Section revision subject.
final class SectionRevisionSubject extends RevisionSubject {
  /// Creates a typed Section subject.
  const SectionRevisionSubject(this.id) : super._();

  /// Section identity.
  final SectionId id;
  @override
  int get _kind => 1;
  @override
  String get _uuid => id.uuid.value;
  @override
  bool operator ==(Object other) =>
      other is SectionRevisionSubject && other.id == id;
  @override
  int get hashCode => Object.hash(SectionRevisionSubject, id);
}

/// A Page revision subject.
final class PageRevisionSubject extends RevisionSubject {
  /// Creates a typed Page subject.
  const PageRevisionSubject(this.id) : super._();

  /// Page identity.
  final PageId id;
  @override
  int get _kind => 2;
  @override
  String get _uuid => id.uuid.value;
  @override
  bool operator ==(Object other) =>
      other is PageRevisionSubject && other.id == id;
  @override
  int get hashCode => Object.hash(PageRevisionSubject, id);
}

/// A Layer-value revision subject.
final class LayerRevisionSubject extends RevisionSubject {
  /// Creates a typed Layer subject.
  const LayerRevisionSubject(this.id) : super._();

  /// Layer identity.
  final LayerId id;
  @override
  int get _kind => 3;
  @override
  String get _uuid => id.uuid.value;
  @override
  bool operator ==(Object other) =>
      other is LayerRevisionSubject && other.id == id;
  @override
  int get hashCode => Object.hash(LayerRevisionSubject, id);
}

/// A Layer membership/order revision subject.
final class LayerMembershipRevisionSubject extends RevisionSubject {
  /// Creates a typed Layer membership subject.
  const LayerMembershipRevisionSubject(this.id) : super._();

  /// Layer identity.
  final LayerId id;
  @override
  int get _kind => 4;
  @override
  String get _uuid => id.uuid.value;
  @override
  bool operator ==(Object other) =>
      other is LayerMembershipRevisionSubject && other.id == id;
  @override
  int get hashCode => Object.hash(LayerMembershipRevisionSubject, id);
}

/// An Object revision subject.
final class ObjectRevisionSubject extends RevisionSubject {
  /// Creates a typed Object subject.
  const ObjectRevisionSubject(this.id) : super._();

  /// Object identity.
  final ObjectId id;
  @override
  int get _kind => 5;
  @override
  String get _uuid => id.uuid.value;
  @override
  bool operator ==(Object other) =>
      other is ObjectRevisionSubject && other.id == id;
  @override
  int get hashCode => Object.hash(ObjectRevisionSubject, id);
}

/// A resource-catalog revision subject.
final class ResourceCatalogRevisionSubject extends RevisionSubject {
  /// Creates a typed resource-catalog subject.
  const ResourceCatalogRevisionSubject(this.documentId) : super._();

  /// Owning Document identity.
  final DocumentId documentId;
  @override
  int get _kind => 6;
  @override
  String get _uuid => documentId.uuid.value;
  @override
  bool operator ==(Object other) =>
      other is ResourceCatalogRevisionSubject && other.documentId == documentId;
  @override
  int get hashCode => Object.hash(ResourceCatalogRevisionSubject, documentId);
}

/// Typed evidence for one stale or absent scoped revision.
final class StaleRevisionEvidence implements Comparable<StaleRevisionEvidence> {
  /// Creates immutable stale evidence.
  const StaleRevisionEvidence({
    required this.subject,
    required this.expected,
    required this.actual,
  });

  /// Closed typed subject.
  final RevisionSubject subject;

  /// Requested revision.
  final Revision expected;

  /// Latest revision, or null when the subject is absent.
  final Revision? actual;
  @override
  int compareTo(StaleRevisionEvidence other) =>
      subject.compareTo(other.subject);
  @override
  bool operator ==(Object other) =>
      other is StaleRevisionEvidence &&
      other.subject == subject &&
      other.expected == expected &&
      other.actual == actual;
  @override
  int get hashCode => Object.hash(subject, expected, actual);
  @override
  String toString() => 'StaleRevisionEvidence(${subject.runtimeType})';
}

/// Immutable scoped preconditions declared by a request.
final class RevisionPreconditions {
  /// Defensively copies and deterministically orders all preconditions.
  RevisionPreconditions({
    this.document,
    Map<SectionId, Revision> sections = const {},
    Map<PageId, Revision> pages = const {},
    Map<LayerId, Revision> layers = const {},
    Map<LayerId, Revision> layerMembership = const {},
    Map<ObjectId, Revision> objects = const {},
    this.resourceCatalog,
  }) : sections = _sortedMap(sections),
       pages = _sortedMap(pages),
       layers = _sortedMap(layers),
       layerMembership = _sortedMap(layerMembership),
       objects = _sortedMap(objects);

  /// Optional document-wide dependency.
  final Revision? document;

  /// Section dependencies.
  final Map<SectionId, Revision> sections;

  /// Page dependencies.
  final Map<PageId, Revision> pages;

  /// Layer-value dependencies.
  final Map<LayerId, Revision> layers;

  /// Layer membership/order dependencies.
  final Map<LayerId, Revision> layerMembership;

  /// Object dependencies.
  final Map<ObjectId, Revision> objects;

  /// Optional resource-catalog dependency.
  final Revision? resourceCatalog;
  @override
  bool operator ==(Object other) =>
      other is RevisionPreconditions &&
      other.document == document &&
      _mapEquals(other.sections, sections) &&
      _mapEquals(other.pages, pages) &&
      _mapEquals(other.layers, layers) &&
      _mapEquals(other.layerMembership, layerMembership) &&
      _mapEquals(other.objects, objects) &&
      other.resourceCatalog == resourceCatalog;
  @override
  int get hashCode => Object.hash(
    document,
    Object.hashAll(sections.entries),
    Object.hashAll(pages.entries),
    Object.hashAll(layers.entries),
    Object.hashAll(layerMembership.entries),
    Object.hashAll(objects.entries),
    resourceCatalog,
  );
  @override
  String toString() =>
      'RevisionPreconditions(scoped: ${sections.length + pages.length + layers.length + layerMembership.length + objects.length})';
}

/// Immutable document-scoped session revision state.
final class DocumentRevisionSnapshot {
  DocumentRevisionSnapshot._({
    required this.documentId,
    required this.document,
    required this.sections,
    required this.pages,
    required this.layers,
    required this.layerMembership,
    required this.objects,
    required this.resourceCatalog,
  });

  /// Creates the zero baseline for every entity in [root].
  factory DocumentRevisionSnapshot.initial(DocumentRoot root) {
    final zero = Revision.create(0).fold(
      onOk: (value) => value,
      onErr: (_) => throw StateError('Zero Revision must be valid.'),
    );
    final sections = <SectionId, Revision>{};
    if (root is NotebookDocument)
      for (final section in root.sections) sections[section.id] = zero;
    final pages = <PageId, Revision>{};
    final layers = <LayerId, Revision>{};
    final membership = <LayerId, Revision>{};
    final objects = <ObjectId, Revision>{};
    for (final page in root.pages) {
      pages[page.id] = zero;
      for (final layer in page.layers) {
        layers[layer.id] = zero;
        membership[layer.id] = zero;
        for (final object in layer.objects) objects[object.id] = zero;
      }
    }
    return DocumentRevisionSnapshot._(
      documentId: root.id,
      document: zero,
      sections: _sortedMap(sections),
      pages: _sortedMap(pages),
      layers: _sortedMap(layers),
      layerMembership: _sortedMap(membership),
      objects: _sortedMap(objects),
      resourceCatalog: zero,
    );
  }

  /// Creates an explicit immutable snapshot for restoration and tests.
  factory DocumentRevisionSnapshot.fromValues({
    required DocumentId documentId,
    required Revision document,
    Map<SectionId, Revision> sections = const {},
    Map<PageId, Revision> pages = const {},
    Map<LayerId, Revision> layers = const {},
    Map<LayerId, Revision> layerMembership = const {},
    Map<ObjectId, Revision> objects = const {},
    required Revision resourceCatalog,
  }) => DocumentRevisionSnapshot._(
    documentId: documentId,
    document: document,
    sections: _sortedMap(sections),
    pages: _sortedMap(pages),
    layers: _sortedMap(layers),
    layerMembership: _sortedMap(layerMembership),
    objects: _sortedMap(objects),
    resourceCatalog: resourceCatalog,
  );

  /// Owning Document identity.
  final DocumentId documentId;

  /// Global document sequence revision.
  final Revision document;

  /// Section revisions.
  final Map<SectionId, Revision> sections;

  /// Page revisions.
  final Map<PageId, Revision> pages;

  /// Layer revisions.
  final Map<LayerId, Revision> layers;

  /// Layer membership/order revisions.
  final Map<LayerId, Revision> layerMembership;

  /// Object revisions.
  final Map<ObjectId, Revision> objects;

  /// Resource-catalog revision.
  final Revision resourceCatalog;

  /// Advances the global revision and each specified Object revision as one
  /// immutable operation.
  Result<DocumentRevisionSnapshot, StructuredFailure> advanceObjects(
    Iterable<ObjectId> changedObjects,
  ) {
    final ids = changedObjects.toSet();
    if (ids.any((id) => !objects.containsKey(id))) {
      return Err(_revisionFailure('missing_object'));
    }
    final nextDocument = document.increment().fold(
      onOk: (value) => value,
      onErr: (_) => null,
    );
    if (nextDocument == null) return Err(_revisionFailure('overflow'));
    final nextObjects = Map<ObjectId, Revision>.of(objects);
    for (final id in ids) {
      final next = objects[id]!.increment().fold(
        onOk: (value) => value,
        onErr: (_) => null,
      );
      if (next == null) return Err(_revisionFailure('overflow'));
      nextObjects[id] = next;
    }
    return Ok(
      DocumentRevisionSnapshot.fromValues(
        documentId: documentId,
        document: nextDocument,
        sections: sections,
        pages: pages,
        layers: layers,
        layerMembership: layerMembership,
        objects: nextObjects,
        resourceCatalog: resourceCatalog,
      ),
    );
  }

  /// Returns every mismatch, including absent expected subjects.
  List<StaleRevisionEvidence> mismatches(RevisionPreconditions required) {
    final result = <StaleRevisionEvidence>[];
    void compare(RevisionSubject subject, Revision expected, Revision? actual) {
      if (actual != expected)
        result.add(
          StaleRevisionEvidence(
            subject: subject,
            expected: expected,
            actual: actual,
          ),
        );
    }

    if (required.document case final expected?)
      compare(DocumentRevisionSubject(documentId), expected, document);
    for (final entry in required.sections.entries)
      compare(
        SectionRevisionSubject(entry.key),
        entry.value,
        sections[entry.key],
      );
    for (final entry in required.pages.entries)
      compare(PageRevisionSubject(entry.key), entry.value, pages[entry.key]);
    for (final entry in required.layers.entries)
      compare(LayerRevisionSubject(entry.key), entry.value, layers[entry.key]);
    for (final entry in required.layerMembership.entries)
      compare(
        LayerMembershipRevisionSubject(entry.key),
        entry.value,
        layerMembership[entry.key],
      );
    for (final entry in required.objects.entries)
      compare(
        ObjectRevisionSubject(entry.key),
        entry.value,
        objects[entry.key],
      );
    if (required.resourceCatalog case final expected?)
      compare(
        ResourceCatalogRevisionSubject(documentId),
        expected,
        resourceCatalog,
      );
    result.sort();
    return List.unmodifiable(result);
  }

  @override
  bool operator ==(Object other) =>
      other is DocumentRevisionSnapshot &&
      other.documentId == documentId &&
      other.document == document &&
      _mapEquals(other.sections, sections) &&
      _mapEquals(other.pages, pages) &&
      _mapEquals(other.layers, layers) &&
      _mapEquals(other.layerMembership, layerMembership) &&
      _mapEquals(other.objects, objects) &&
      other.resourceCatalog == resourceCatalog;
  @override
  int get hashCode => Object.hash(
    documentId,
    document,
    Object.hashAll(sections.entries),
    Object.hashAll(pages.entries),
    Object.hashAll(layers.entries),
    Object.hashAll(layerMembership.entries),
    Object.hashAll(objects.entries),
    resourceCatalog,
  );
  @override
  String toString() =>
      'DocumentRevisionSnapshot(document: $document, objects: ${objects.length})';
}

Map<K, Revision> _sortedMap<K>(Map<K, Revision> source) {
  final entries = source.entries.toList()
    ..sort(
      (a, b) =>
          _uuidText(a.key as Object).compareTo(_uuidText(b.key as Object)),
    );
  return UnmodifiableMapView(Map<K, Revision>.fromEntries(entries));
}

String _uuidText(Object value) => switch (value) {
  SectionId(:final uuid) ||
  PageId(:final uuid) ||
  LayerId(:final uuid) ||
  ObjectId(:final uuid) => uuid.value,
  _ => value.toString(),
};

bool _mapEquals<K, V>(Map<K, V> left, Map<K, V> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries)
    if (right[entry.key] != entry.value) return false;
  return true;
}

StructuredFailure _revisionFailure(String leaf) => StructuredFailure(
  code: 'documents.revisions.$leaf',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.never,
  message: 'The revision snapshot cannot be advanced.',
);
