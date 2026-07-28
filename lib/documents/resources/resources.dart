// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../model/identifiers.dart';

export 'resource_records.dart';

/// An immutable logical reference to an immutable document resource.
final class ResourceReference {
  /// Creates a logical resource reference.
  const ResourceReference(this.identity);

  /// The referenced document-scoped resource identity.
  final ResourceIdentity identity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourceReference && other.identity == identity;

  @override
  int get hashCode => Object.hash(ResourceReference, identity);

  @override
  String toString() => 'ResourceReference($identity)';
}

/// Evidence that one logical resource is present in a document catalog.
final class ResourceCatalogEntry implements Comparable<ResourceCatalogEntry> {
  /// Creates resource-presence evidence.
  const ResourceCatalogEntry(this.identity);

  /// The available logical resource identity.
  final ResourceIdentity identity;

  @override
  int compareTo(ResourceCatalogEntry other) =>
      identity.uuid.value.compareTo(other.identity.uuid.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourceCatalogEntry && other.identity == identity;

  @override
  int get hashCode => Object.hash(ResourceCatalogEntry, identity);

  @override
  String toString() => 'ResourceCatalogEntry($identity)';
}

/// An immutable deterministic catalog of available logical resources.
final class ResourceCatalog {
  ResourceCatalog._(this.entries, this._identities);

  /// Creates a catalog and rejects duplicate resource identities.
  static Result<ResourceCatalog, StructuredFailure> create(
    Iterable<ResourceCatalogEntry> entries,
  ) {
    final copied = List<ResourceCatalogEntry>.of(entries)..sort();
    final identities = <ResourceIdentity>{};
    for (final entry in copied) {
      if (!identities.add(entry.identity)) {
        return Err<ResourceCatalog, StructuredFailure>(
          StructuredFailure(
            code: 'documents.resources.duplicate_identity',
            category: FailureCategory.validation,
            retryDisposition: RetryDisposition.never,
            message: 'A resource catalog contains a duplicate identity.',
          ),
        );
      }
    }
    return Ok<ResourceCatalog, StructuredFailure>(
      ResourceCatalog._(
        List<ResourceCatalogEntry>.unmodifiable(copied),
        Set<ResourceIdentity>.unmodifiable(identities),
      ),
    );
  }

  /// The unmodifiable entries in deterministic identity order.
  final List<ResourceCatalogEntry> entries;

  final Set<ResourceIdentity> _identities;

  /// Whether [identity] is available in this catalog.
  bool contains(ResourceIdentity identity) => _identities.contains(identity);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! ResourceCatalog || other.entries.length != entries.length) {
      return false;
    }
    for (var index = 0; index < entries.length; index += 1) {
      if (entries[index] != other.entries[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(entries);

  @override
  String toString() => 'ResourceCatalog(length: ${entries.length})';
}
