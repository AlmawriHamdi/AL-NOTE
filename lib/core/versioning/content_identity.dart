// SPDX-License-Identifier: GPL-3.0-or-later

import '../identity/uuid_identifier.dart';

/// A UUID-backed identity for content, distinct from versions and revisions.
final class ContentIdentity {
  /// Creates a content identity backed by [uuid].
  const ContentIdentity(this.uuid);

  /// The AL NOTE UUID value backing this content identity.
  final UuidIdentifier uuid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ContentIdentity && other.uuid == uuid;

  @override
  int get hashCode => uuid.hashCode;

  @override
  String toString() => uuid.toString();
}
