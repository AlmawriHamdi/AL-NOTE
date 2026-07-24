// SPDX-License-Identifier: GPL-3.0-or-later

/// The complete set of AL NOTE data classifications.
enum DataClassification {
  /// Information intended for unrestricted disclosure.
  publicData('Public'),

  /// Non-public operational information that is not sensitive content.
  internal('Internal'),

  /// User content requiring sensitive-data protections.
  sensitiveContent('Sensitive Content'),

  /// Sensitive information derived from user content.
  derivedSensitive('Derived Sensitive'),

  /// Short-lived sensitive information used during an operation.
  temporarySensitive('Temporary Sensitive'),

  /// Passwords, keys, credentials, bearer tokens, and equivalent secrets.
  secret('Secret'),

  /// Security audit information subject to audit protections.
  securityAudit('Security Audit'),

  /// Plugin metadata that remains untrusted regardless of visibility.
  untrustedPluginMetadata('Untrusted Plugin Metadata'),

  /// Content-free operational measurements that do not identify a user.
  anonymousOperationalMetrics('Anonymous Operational Metrics');

  const DataClassification(this.label);

  /// The exact stable human-readable classification label.
  final String label;
}
