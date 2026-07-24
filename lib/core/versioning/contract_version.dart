// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';

/// A nonnegative major/minor contract version.
final class ContractVersion implements Comparable<ContractVersion> {
  const ContractVersion._(this.major, this.minor);

  /// Creates a contract version from nonnegative [major] and [minor] values.
  static Result<ContractVersion, StructuredFailure> create(
    int major,
    int minor,
  ) {
    if (major < 0 || minor < 0) {
      return Err<ContractVersion, StructuredFailure>(
        StructuredFailure(
          code: 'core.versioning.invalid_contract_version',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'Contract major and minor versions must be nonnegative.',
        ),
      );
    }
    return Ok<ContractVersion, StructuredFailure>(
      ContractVersion._(major, minor),
    );
  }

  /// The contract major version.
  final int major;

  /// The contract minor version.
  final int minor;

  /// Whether this provider version satisfies [requiredVersion].
  ///
  /// Compatibility requires equal major versions and a provider minor version
  /// greater than or equal to the required minor version.
  bool isCompatibleProviderFor(ContractVersion requiredVersion) =>
      major == requiredVersion.major && minor >= requiredVersion.minor;

  @override
  int compareTo(ContractVersion other) {
    final majorComparison = major.compareTo(other.major);
    return majorComparison != 0
        ? majorComparison
        : minor.compareTo(other.minor);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContractVersion && other.major == major && other.minor == minor;

  @override
  int get hashCode => Object.hash(major, minor);

  @override
  String toString() => '$major.$minor';
}
