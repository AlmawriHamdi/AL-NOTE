// SPDX-License-Identifier: GPL-3.0-or-later

/// Foundational AL NOTE contracts for outcomes, identity, versions, time, and
/// randomness.
library;

export 'geometry/affine_transform_2d.dart';
export 'geometry/geometry_values.dart';
export 'geometry/transform_operations.dart';
export 'identity/namespaced_identifier.dart';
export 'identity/uuid_generator.dart';
export 'identity/uuid_identifier.dart';
export 'outcomes/cancellation.dart';
export 'outcomes/operation_outcome.dart';
export 'outcomes/result.dart';
export 'outcomes/structured_failure.dart';
export 'random/random_source.dart';
export 'random/sdk_secure_random_source.dart';
export 'security/data_classification.dart';
export 'security/resource_limits.dart';
export 'time/clock.dart';
export 'time/sdk_clock.dart';
export 'validation/validation_failure.dart';
export 'validation/validation_issue.dart';
export 'validation/validation_path.dart';
export 'validation/validation_report.dart';
export 'validation/validator.dart';
export 'versioning/content_identity.dart';
export 'versioning/contract_version.dart';
export 'versioning/revision.dart';
export 'versioning/schema_version.dart';
