// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../layers/document_layer.dart';
import '../objects/object_envelope.dart';
import '../objects/object_registry.dart';
import 'document_root.dart';
import 'document_validator.dart';
import 'identifiers.dart';

/// Pure immutable candidate-building primitives for document replacement.
///
/// These operations do not authorize or publish persistent mutation, create
/// history, or bypass the future Command coordinator.
final class DocumentReplacement {
  /// Creates replacement primitives using [validator] for complete candidates.
  const DocumentReplacement(this.validator);

  /// The validator used before complete-root candidate success.
  final DocumentValidator validator;

  /// Replaces one Object in [layer] while retaining its identity.
  Result<DocumentLayer, StructuredFailure> replaceObjectInLayer({
    required DocumentLayer layer,
    required ObjectId targetId,
    required ObjectEnvelope replacement,
  }) {
    if (replacement.id != targetId) {
      return Err<DocumentLayer, StructuredFailure>(_identityMismatch());
    }
    if (!_objectCandidateIsValid(replacement)) {
      return Err<DocumentLayer, StructuredFailure>(_invalidCandidate());
    }
    final indexes = <int>[];
    for (var index = 0; index < layer.objects.length; index += 1) {
      if (layer.objects[index].id == targetId) {
        indexes.add(index);
      }
    }
    final targetFailure = _targetFailure(indexes.length);
    if (targetFailure != null) {
      return Err<DocumentLayer, StructuredFailure>(targetFailure);
    }
    final candidate = List<ObjectEnvelope>.of(layer.objects);
    candidate[indexes.single] = replacement;
    return layer.withObjects(candidate);
  }

  /// Replaces one Layer in [page] while retaining its identity.
  Result<DocumentPage, StructuredFailure> replaceLayerInPage({
    required DocumentPage page,
    required LayerId targetId,
    required DocumentLayer replacement,
  }) {
    if (replacement.id != targetId) {
      return Err<DocumentPage, StructuredFailure>(_identityMismatch());
    }
    if (!_layerObjectsAreValid(replacement)) {
      return Err<DocumentPage, StructuredFailure>(_invalidCandidate());
    }
    final indexes = <int>[];
    for (var index = 0; index < page.layers.length; index += 1) {
      if (page.layers[index].id == targetId) {
        indexes.add(index);
      }
    }
    final targetFailure = _targetFailure(indexes.length);
    if (targetFailure != null) {
      return Err<DocumentPage, StructuredFailure>(targetFailure);
    }
    final candidate = List<DocumentLayer>.of(page.layers);
    candidate[indexes.single] = replacement;
    return DocumentPage.create(
      id: page.id,
      name: page.name,
      size: page.size,
      layers: candidate,
      extensionData: page.extensionData,
    );
  }

  /// Replaces one Page in [section] while retaining its identity.
  Result<DocumentSection, StructuredFailure> replacePageInSection({
    required DocumentSection section,
    required PageId targetId,
    required DocumentPage replacement,
  }) {
    if (replacement.id != targetId) {
      return Err<DocumentSection, StructuredFailure>(_identityMismatch());
    }
    if (!_pageObjectsAreValid(replacement)) {
      return Err<DocumentSection, StructuredFailure>(_invalidCandidate());
    }
    final indexes = <int>[];
    for (var index = 0; index < section.pages.length; index += 1) {
      if (section.pages[index].id == targetId) {
        indexes.add(index);
      }
    }
    final targetFailure = _targetFailure(indexes.length);
    if (targetFailure != null) {
      return Err<DocumentSection, StructuredFailure>(targetFailure);
    }
    final candidate = List<DocumentPage>.of(section.pages);
    candidate[indexes.single] = replacement;
    return DocumentSection.create(
      id: section.id,
      name: section.name,
      pages: candidate,
      extensionData: section.extensionData,
    );
  }

  /// Replaces one Section in [notebook] while retaining its identity.
  Result<NotebookDocument, StructuredFailure> replaceSectionInNotebook({
    required NotebookDocument notebook,
    required SectionId targetId,
    required DocumentSection replacement,
  }) {
    if (replacement.id != targetId) {
      return Err<NotebookDocument, StructuredFailure>(_identityMismatch());
    }
    final indexes = <int>[];
    for (var index = 0; index < notebook.sections.length; index += 1) {
      if (notebook.sections[index].id == targetId) {
        indexes.add(index);
      }
    }
    final targetFailure = _targetFailure(indexes.length);
    if (targetFailure != null) {
      return Err<NotebookDocument, StructuredFailure>(targetFailure);
    }
    final candidate = List<DocumentSection>.of(notebook.sections);
    candidate[indexes.single] = replacement;
    final built = NotebookDocument.create(
      id: notebook.id,
      schemaVersion: notebook.schemaVersion,
      title: notebook.title,
      resources: notebook.resources,
      extensionData: notebook.extensionData,
      sections: candidate,
    );
    return built.fold(
      onOk: _validatedRoot<NotebookDocument>,
      onErr: Err<NotebookDocument, StructuredFailure>.new,
    );
  }

  /// Replaces one Page wherever it is directly owned by [root].
  Result<DocumentRoot, StructuredFailure> replacePageInRoot({
    required DocumentRoot root,
    required PageId targetId,
    required DocumentPage replacement,
  }) {
    if (replacement.id != targetId) {
      return Err<DocumentRoot, StructuredFailure>(_identityMismatch());
    }
    switch (root) {
      case StandalonePageDocument(:final page):
        if (page.id != targetId) {
          return Err<DocumentRoot, StructuredFailure>(_targetNotFound());
        }
        final built = StandalonePageDocument.create(
          id: root.id,
          schemaVersion: root.schemaVersion,
          title: root.title,
          resources: root.resources,
          extensionData: root.extensionData,
          page: replacement,
        );
        return built.fold(
          onOk: _validatedRoot<StandalonePageDocument>,
          onErr: Err<DocumentRoot, StructuredFailure>.new,
        );
      case StandalonePdfDocument():
        final matches = root.pages.where((page) => page.id == targetId).length;
        final targetFailure = _targetFailure(matches);
        if (targetFailure != null) {
          return Err<DocumentRoot, StructuredFailure>(targetFailure);
        }
        final pages = <DocumentPage>[
          for (final page in root.pages)
            if (page.id == targetId) replacement else page,
        ];
        final built = StandalonePdfDocument.create(
          id: root.id,
          schemaVersion: root.schemaVersion,
          title: root.title,
          resources: root.resources,
          extensionData: root.extensionData,
          pages: pages,
          source: root.source,
        );
        return built.fold(
          onOk: _validatedRoot<StandalonePdfDocument>,
          onErr: Err<DocumentRoot, StructuredFailure>.new,
        );
      case NotebookDocument():
        var matches = 0;
        for (final section in root.sections) {
          matches += section.pages.where((page) => page.id == targetId).length;
        }
        final targetFailure = _targetFailure(matches);
        if (targetFailure != null) {
          return Err<DocumentRoot, StructuredFailure>(targetFailure);
        }
        final sections = <DocumentSection>[];
        for (final section in root.sections) {
          if (section.pages.any((page) => page.id == targetId)) {
            final replaced = replacePageInSection(
              section: section,
              targetId: targetId,
              replacement: replacement,
            );
            final failure = replaced.fold<StructuredFailure?>(
              onOk: (value) {
                sections.add(value);
                return null;
              },
              onErr: (error) => error,
            );
            if (failure != null) {
              return Err<DocumentRoot, StructuredFailure>(failure);
            }
          } else {
            sections.add(section);
          }
        }
        final built = NotebookDocument.create(
          id: root.id,
          schemaVersion: root.schemaVersion,
          title: root.title,
          resources: root.resources,
          extensionData: root.extensionData,
          sections: sections,
        );
        return built.fold(
          onOk: _validatedRoot<NotebookDocument>,
          onErr: Err<DocumentRoot, StructuredFailure>.new,
        );
    }
  }

  /// Validates a complete root replacement that retains document identity.
  Result<DocumentRoot, StructuredFailure> replaceDocumentRoot({
    required DocumentRoot current,
    required DocumentRoot replacement,
  }) {
    if (current.id != replacement.id) {
      return Err<DocumentRoot, StructuredFailure>(_identityMismatch());
    }
    return _validatedRoot<DocumentRoot>(replacement);
  }

  bool _objectCandidateIsValid(ObjectEnvelope object) =>
      validator.objectRegistry.resolve(object)
          is! InvalidObjectPayloadResolution;

  bool _layerObjectsAreValid(DocumentLayer layer) =>
      layer.objects.every(_objectCandidateIsValid);

  bool _pageObjectsAreValid(DocumentPage page) =>
      page.layers.every(_layerObjectsAreValid);

  Result<T, StructuredFailure> _validatedRoot<T extends DocumentRoot>(T root) {
    if (!validator.validate(root).isValid) {
      return Err<T, StructuredFailure>(_invalidCandidate());
    }
    return Ok<T, StructuredFailure>(root);
  }
}

StructuredFailure? _targetFailure(int count) {
  if (count == 0) {
    return _targetNotFound();
  }
  if (count != 1) {
    return StructuredFailure(
      code: 'documents.replacement.target_not_unique',
      category: FailureCategory.state,
      retryDisposition: RetryDisposition.never,
      message: 'A replacement target must exist exactly once.',
    );
  }
  return null;
}

StructuredFailure _targetNotFound() => StructuredFailure(
  code: 'documents.replacement.target_not_found',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.never,
  message: 'The replacement target does not exist.',
);

StructuredFailure _identityMismatch() => StructuredFailure(
  code: 'documents.replacement.identity_mismatch',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'A replacement must retain the target identity.',
);

StructuredFailure _invalidCandidate() => StructuredFailure(
  code: 'documents.replacement.invalid_candidate',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'A replacement candidate violates document invariants.',
);
