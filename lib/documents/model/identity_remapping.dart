// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import 'identifiers.dart';

/// Immutable typed identity remapping supplied to duplication handlers.
final class IdentityRemapping {
  /// Defensively copies every typed mapping.
  IdentityRemapping({
    Map<SectionId, SectionId> sections = const <SectionId, SectionId>{},
    Map<PageId, PageId> pages = const <PageId, PageId>{},
    Map<LayerId, LayerId> layers = const <LayerId, LayerId>{},
    Map<ObjectId, ObjectId> objects = const <ObjectId, ObjectId>{},
    Map<ResourceIdentity, ResourceIdentity> resources =
        const <ResourceIdentity, ResourceIdentity>{},
  }) : sections = _sortedMap(
         sections,
         (left, right) => left.uuid.value.compareTo(right.uuid.value),
       ),
       pages = _sortedMap(
         pages,
         (left, right) => left.uuid.value.compareTo(right.uuid.value),
       ),
       layers = _sortedMap(
         layers,
         (left, right) => left.uuid.value.compareTo(right.uuid.value),
       ),
       objects = _sortedMap(
         objects,
         (left, right) => left.uuid.value.compareTo(right.uuid.value),
       ),
       resources = _sortedMap(
         resources,
         (left, right) => left.uuid.value.compareTo(right.uuid.value),
       );

  /// Section identity replacements.
  final Map<SectionId, SectionId> sections;

  /// Page identity replacements.
  final Map<PageId, PageId> pages;

  /// Layer identity replacements.
  final Map<LayerId, LayerId> layers;

  /// Object identity replacements.
  final Map<ObjectId, ObjectId> objects;

  /// Resource identity replacements.
  final Map<ResourceIdentity, ResourceIdentity> resources;

  /// Returns the mapped Object identity or the original when unchanged.
  ObjectId objectOrSame(ObjectId value) => objects[value] ?? value;

  /// Returns the mapped Layer identity or the original when unchanged.
  LayerId layerOrSame(LayerId value) => layers[value] ?? value;

  /// Returns the mapped Page identity or the original when unchanged.
  PageId pageOrSame(PageId value) => pages[value] ?? value;

  /// Returns the mapped Section identity or the original when unchanged.
  SectionId sectionOrSame(SectionId value) => sections[value] ?? value;

  /// Returns the mapped resource identity or the original when shared.
  ResourceIdentity resourceOrSame(ResourceIdentity value) =>
      resources[value] ?? value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IdentityRemapping &&
          _mapsEqual(sections, other.sections) &&
          _mapsEqual(pages, other.pages) &&
          _mapsEqual(layers, other.layers) &&
          _mapsEqual(objects, other.objects) &&
          _mapsEqual(resources, other.resources);

  @override
  int get hashCode => Object.hash(
    _mapHash(sections),
    _mapHash(pages),
    _mapHash(layers),
    _mapHash(objects),
    _mapHash(resources),
  );

  @override
  String toString() =>
      'IdentityRemapping(sections: ${sections.length}, '
      'pages: ${pages.length}, layers: ${layers.length}, '
      'objects: ${objects.length}, resources: ${resources.length})';
}

Map<K, V> _sortedMap<K, V>(
  Map<K, V> source,
  int Function(K left, K right) compare,
) => UnmodifiableMapView<K, V>(SplayTreeMap<K, V>.from(source, compare));

bool _mapsEqual<K, V>(Map<K, V> left, Map<K, V> right) {
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    if (!right.containsKey(entry.key) || right[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

int _mapHash<K, V>(Map<K, V> value) => Object.hashAll(
  value.entries.map((entry) => Object.hash(entry.key, entry.value)),
);
