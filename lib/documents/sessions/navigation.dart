// SPDX-License-Identifier: GPL-3.0-or-later

import '../layers/document_layer.dart';
import '../model/document_root.dart';
import '../model/identifiers.dart';

/// Immutable view-local navigation identities; never persistent document data.
final class ViewNavigation {
  const ViewNavigation({
    this.sectionId,
    this.pageId,
    this.layerId,
    this.objectId,
  });
  final SectionId? sectionId;
  final PageId? pageId;
  final LayerId? layerId;
  final ObjectId? objectId;
  bool get hasActiveTarget =>
      sectionId != null ||
      pageId != null ||
      layerId != null ||
      objectId != null;
}

/// Deterministically repairs navigation after an authoritative root change.
final class ViewNavigationRepair {
  const ViewNavigationRepair();

  ViewNavigation repair({
    required ViewNavigation previous,
    required DocumentRoot previousRoot,
    required DocumentRoot currentRoot,
  }) {
    final currentPages = currentRoot.pages;
    final priorPages = previousRoot.pages;
    final page = _retainOrSibling(
      previous.pageId,
      priorPages.map((p) => p.id).toList(),
      currentPages.map((p) => p.id).toList(),
    );
    if (page == null) return const ViewNavigation();
    final currentPage = currentPages.firstWhere((p) => p.id == page);
    final layer = _repairLayer(previous.layerId, currentPage.layers);
    final objectIds = currentPage.layers
        .expand((l) => l.objects)
        .map((o) => o.id)
        .toSet();
    final object =
        previous.objectId != null && objectIds.contains(previous.objectId)
        ? previous.objectId
        : null;
    return ViewNavigation(
      sectionId: _sectionFor(currentRoot, page),
      pageId: page,
      layerId: layer,
      objectId: object,
    );
  }

  T? _retainOrSibling<T>(T? active, List<T> prior, List<T> current) {
    if (active != null && current.contains(active)) return active;
    final index = active == null ? -1 : prior.indexOf(active);
    if (index >= 0) {
      for (var i = index + 1; i < prior.length; i++)
        if (current.contains(prior[i])) return prior[i];
      for (var i = index - 1; i >= 0; i--)
        if (current.contains(prior[i])) return prior[i];
    }
    return current.firstOrNull;
  }

  LayerId? _repairLayer(LayerId? active, List<DocumentLayer> current) {
    if (active != null && current.any((layer) => layer.id == active)) {
      return active;
    }
    final preferred = current
        .where((l) => l.role == LayerCoreRole.content && l.visible && !l.locked)
        .firstOrNull;
    return preferred?.id ?? current.firstOrNull?.id;
  }

  SectionId? _sectionFor(DocumentRoot root, PageId page) {
    if (root is NotebookDocument) {
      for (final section in root.sections)
        if (section.pages.any((p) => p.id == page)) return section.id;
    }
    return null;
  }
}
