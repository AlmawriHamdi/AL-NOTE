// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/geometry_values.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/schema_version.dart';
import '../layers/document_layer.dart';
import '../resources/resources.dart';
import 'identifiers.dart';
import 'preserved_data.dart';

/// An immutable fixed-boundary Page with authoritative ordered Layers.
final class DocumentPage {
  DocumentPage._({
    required this.id,
    required this.name,
    required this.size,
    required List<DocumentLayer> layers,
    required this.extensionData,
  }) : layers = List<DocumentLayer>.unmodifiable(layers);

  /// Creates a Page after atomically checking all Page invariants.
  static Result<DocumentPage, StructuredFailure> create({
    required PageId id,
    required String name,
    required Size2 size,
    required Iterable<DocumentLayer> layers,
    required PreservedMap extensionData,
  }) {
    if (size.isEmpty) {
      return Err<DocumentPage, StructuredFailure>(
        _documentFailure(
          'documents.pages.invalid_size',
          'Page dimensions must be strictly positive.',
        ),
      );
    }
    final copiedLayers = List<DocumentLayer>.of(layers);
    final structureFailure = _validateLayerStructure(copiedLayers);
    if (structureFailure != null) {
      return Err<DocumentPage, StructuredFailure>(structureFailure);
    }
    return Ok<DocumentPage, StructuredFailure>(
      DocumentPage._(
        id: id,
        name: name,
        size: size,
        layers: copiedLayers,
        extensionData: extensionData,
      ),
    );
  }

  /// The document-unique Page identity.
  final PageId id;

  /// The sensitive user-visible Page name.
  final String name;

  /// The strictly positive finite Page size.
  final Size2 size;

  /// The directly owned Layers in authoritative order.
  final List<DocumentLayer> layers;

  /// The immutable preserved Page extension data.
  final PreservedMap extensionData;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocumentPage &&
          other.id == id &&
          other.name == name &&
          other.size == size &&
          _listsEqual(other.layers, layers) &&
          other.extensionData == extensionData;

  @override
  int get hashCode =>
      Object.hash(id, name, size, Object.hashAll(layers), extensionData);

  @override
  String toString() => 'DocumentPage(id: $id, layers: ${layers.length})';
}

/// An immutable named Notebook Section with authoritative ordered Pages.
final class DocumentSection {
  DocumentSection._({
    required this.id,
    required this.name,
    required List<DocumentPage> pages,
    required this.extensionData,
  }) : pages = List<DocumentPage>.unmodifiable(pages);

  /// Creates a Section and rejects duplicate Page identities.
  static Result<DocumentSection, StructuredFailure> create({
    required SectionId id,
    required String name,
    required Iterable<DocumentPage> pages,
    required PreservedMap extensionData,
  }) {
    final copiedPages = List<DocumentPage>.of(pages);
    final pageIds = <PageId>{};
    for (final page in copiedPages) {
      if (!pageIds.add(page.id)) {
        return Err<DocumentSection, StructuredFailure>(
          _duplicateIdentityFailure(),
        );
      }
    }
    return Ok<DocumentSection, StructuredFailure>(
      DocumentSection._(
        id: id,
        name: name,
        pages: copiedPages,
        extensionData: extensionData,
      ),
    );
  }

  /// The document-unique Section identity.
  final SectionId id;

  /// The sensitive user-visible Section name.
  final String name;

  /// The directly owned Pages in authoritative order.
  final List<DocumentPage> pages;

  /// The immutable preserved Section extension data.
  final PreservedMap extensionData;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocumentSection &&
          other.id == id &&
          other.name == name &&
          _listsEqual(other.pages, pages) &&
          other.extensionData == extensionData;

  @override
  int get hashCode =>
      Object.hash(id, name, Object.hashAll(pages), extensionData);

  @override
  String toString() => 'DocumentSection(id: $id, pages: ${pages.length})';
}

/// The sealed immutable family of authoritative document forms.
sealed class DocumentRoot {
  const DocumentRoot._({
    required this.id,
    required this.schemaVersion,
    required this.title,
    required this.resources,
    required this.extensionData,
  });

  /// The document identity.
  final DocumentId id;

  /// The positive document-root schema version.
  final SchemaVersion schemaVersion;

  /// The sensitive user-visible document title.
  final String title;

  /// The immutable logical resource catalog.
  final ResourceCatalog resources;

  /// The immutable preserved document-root extension data.
  final PreservedMap extensionData;

  /// Every authoritative Page in document order.
  List<DocumentPage> get pages;
}

/// An authoritative Notebook document containing ordered Sections.
final class NotebookDocument extends DocumentRoot {
  NotebookDocument._({
    required super.id,
    required super.schemaVersion,
    required super.title,
    required super.resources,
    required super.extensionData,
    required List<DocumentSection> sections,
  }) : sections = List<DocumentSection>.unmodifiable(sections),
       super._();

  /// Creates a Notebook after checking complete document identity uniqueness.
  static Result<NotebookDocument, StructuredFailure> create({
    required DocumentId id,
    required SchemaVersion schemaVersion,
    required String title,
    required ResourceCatalog resources,
    required PreservedMap extensionData,
    required Iterable<DocumentSection> sections,
  }) {
    final copiedSections = List<DocumentSection>.of(sections);
    final failure = _validateNotebookIdentities(copiedSections);
    if (failure != null) {
      return Err<NotebookDocument, StructuredFailure>(failure);
    }
    return Ok<NotebookDocument, StructuredFailure>(
      NotebookDocument._(
        id: id,
        schemaVersion: schemaVersion,
        title: title,
        resources: resources,
        extensionData: extensionData,
        sections: copiedSections,
      ),
    );
  }

  /// The directly owned Sections in authoritative order.
  final List<DocumentSection> sections;

  @override
  List<DocumentPage> get pages => List<DocumentPage>.unmodifiable(
    sections.expand((section) => section.pages),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotebookDocument &&
          other.id == id &&
          other.schemaVersion == schemaVersion &&
          other.title == title &&
          other.resources == resources &&
          other.extensionData == extensionData &&
          _listsEqual(other.sections, sections);

  @override
  int get hashCode => Object.hash(
    NotebookDocument,
    id,
    schemaVersion,
    title,
    resources,
    extensionData,
    Object.hashAll(sections),
  );

  @override
  String toString() =>
      'NotebookDocument(id: $id, sections: ${sections.length})';
}

/// An authoritative standalone document containing exactly one Page.
final class StandalonePageDocument extends DocumentRoot {
  const StandalonePageDocument._({
    required super.id,
    required super.schemaVersion,
    required super.title,
    required super.resources,
    required super.extensionData,
    required this.page,
  }) : super._();

  /// Creates a standalone Page document without a synthetic Section.
  static Result<StandalonePageDocument, StructuredFailure> create({
    required DocumentId id,
    required SchemaVersion schemaVersion,
    required String title,
    required ResourceCatalog resources,
    required PreservedMap extensionData,
    required DocumentPage page,
  }) => Ok<StandalonePageDocument, StructuredFailure>(
    StandalonePageDocument._(
      id: id,
      schemaVersion: schemaVersion,
      title: title,
      resources: resources,
      extensionData: extensionData,
      page: page,
    ),
  );

  /// The one authoritative Page.
  final DocumentPage page;

  @override
  List<DocumentPage> get pages =>
      List<DocumentPage>.unmodifiable(<DocumentPage>[page]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StandalonePageDocument &&
          other.id == id &&
          other.schemaVersion == schemaVersion &&
          other.title == title &&
          other.resources == resources &&
          other.extensionData == extensionData &&
          other.page == page;

  @override
  int get hashCode => Object.hash(
    StandalonePageDocument,
    id,
    schemaVersion,
    title,
    resources,
    extensionData,
    page,
  );

  @override
  String toString() => 'StandalonePageDocument(id: $id)';
}

/// An authoritative standalone PDF-backed document with ordinary AL NOTE Pages.
final class StandalonePdfDocument extends DocumentRoot {
  StandalonePdfDocument._({
    required super.id,
    required super.schemaVersion,
    required super.title,
    required super.resources,
    required super.extensionData,
    required List<DocumentPage> pages,
    required this.source,
  }) : _pages = List<DocumentPage>.unmodifiable(pages),
       super._();

  /// Creates a standalone PDF document after checking identity uniqueness.
  static Result<StandalonePdfDocument, StructuredFailure> create({
    required DocumentId id,
    required SchemaVersion schemaVersion,
    required String title,
    required ResourceCatalog resources,
    required PreservedMap extensionData,
    required Iterable<DocumentPage> pages,
    required ResourceReference source,
  }) {
    final copiedPages = List<DocumentPage>.of(pages);
    final failure = _validatePageTreeIdentities(copiedPages);
    if (failure != null) {
      return Err<StandalonePdfDocument, StructuredFailure>(failure);
    }
    return Ok<StandalonePdfDocument, StructuredFailure>(
      StandalonePdfDocument._(
        id: id,
        schemaVersion: schemaVersion,
        title: title,
        resources: resources,
        extensionData: extensionData,
        pages: copiedPages,
        source: source,
      ),
    );
  }

  final List<DocumentPage> _pages;

  /// The generic immutable source resource reference.
  final ResourceReference source;

  @override
  List<DocumentPage> get pages => _pages;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StandalonePdfDocument &&
          other.id == id &&
          other.schemaVersion == schemaVersion &&
          other.title == title &&
          other.resources == resources &&
          other.extensionData == extensionData &&
          _listsEqual(other._pages, _pages) &&
          other.source == source;

  @override
  int get hashCode => Object.hash(
    StandalonePdfDocument,
    id,
    schemaVersion,
    title,
    resources,
    extensionData,
    Object.hashAll(_pages),
    source,
  );

  @override
  String toString() =>
      'StandalonePdfDocument(id: $id, pages: ${_pages.length})';
}

StructuredFailure? _validateLayerStructure(List<DocumentLayer> layers) {
  var contentCount = 0;
  var backgroundCount = 0;
  var pdfCount = 0;
  var priorRoleIndex = -1;
  final layerIds = <LayerId>{};
  final objectIds = <ObjectId>{};
  for (final layer in layers) {
    if (!layerIds.add(layer.id)) {
      return _duplicateIdentityFailure();
    }
    final roleIndex = switch (layer.role) {
      LayerCoreRole.backgroundSource => 0,
      LayerCoreRole.pdfSource => 1,
      LayerCoreRole.content => 2,
    };
    if (roleIndex < priorRoleIndex) {
      return _documentFailure(
        'documents.pages.invalid_layer_order',
        'Layer roles must follow canonical source and content order.',
      );
    }
    priorRoleIndex = roleIndex;
    switch (layer.role) {
      case LayerCoreRole.content:
        contentCount += 1;
      case LayerCoreRole.backgroundSource:
        backgroundCount += 1;
      case LayerCoreRole.pdfSource:
        pdfCount += 1;
    }
    for (final object in layer.objects) {
      if (!objectIds.add(object.id)) {
        return _duplicateIdentityFailure();
      }
    }
  }
  if (contentCount == 0) {
    return _documentFailure(
      'documents.pages.missing_content_layer',
      'A Page must retain at least one content-role Layer.',
    );
  }
  if (backgroundCount > 1 || pdfCount > 1) {
    return _documentFailure(
      'documents.pages.duplicate_source_role',
      'A Page may contain at most one Layer for each source role.',
    );
  }
  return null;
}

StructuredFailure? _validateNotebookIdentities(List<DocumentSection> sections) {
  final sectionIds = <SectionId>{};
  final pages = <DocumentPage>[];
  for (final section in sections) {
    if (!sectionIds.add(section.id)) {
      return _duplicateIdentityFailure();
    }
    pages.addAll(section.pages);
  }
  return _validatePageTreeIdentities(pages);
}

StructuredFailure? _validatePageTreeIdentities(List<DocumentPage> pages) {
  final pageIds = <PageId>{};
  final layerIds = <LayerId>{};
  final objectIds = <ObjectId>{};
  for (final page in pages) {
    if (!pageIds.add(page.id)) {
      return _duplicateIdentityFailure();
    }
    for (final layer in page.layers) {
      if (!layerIds.add(layer.id)) {
        return _multipleOwnershipFailure();
      }
      for (final object in layer.objects) {
        if (!objectIds.add(object.id)) {
          return _multipleOwnershipFailure();
        }
      }
    }
  }
  return null;
}

StructuredFailure _duplicateIdentityFailure() => _documentFailure(
  'documents.model.duplicate_identity',
  'A document collection contains a duplicate identity.',
);

StructuredFailure _multipleOwnershipFailure() => _documentFailure(
  'documents.model.multiple_ownership',
  'A document entity has more than one structural owner.',
);

StructuredFailure _documentFailure(String code, String message) =>
    StructuredFailure(
      code: code,
      category: FailureCategory.validation,
      retryDisposition: RetryDisposition.never,
      message: message,
    );

bool _listsEqual<T>(List<T> left, List<T> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
