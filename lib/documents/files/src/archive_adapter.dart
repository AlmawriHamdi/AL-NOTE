// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../../core/identity/uuid_identifier.dart';
import '../../../core/outcomes/result.dart';
import '../../../core/outcomes/structured_failure.dart';
import '../../model/preserved_data.dart';
import '../contracts.dart';

/// AL NOTE-owned immutable entry bytes passed into the private archive adapter.
final class ArchiveEntryBytes {
  /// Defensively captures one canonical entry.
  ArchiveEntryBytes(this.path, Iterable<int> bytes)
    : bytes = List<int>.unmodifiable(List<int>.of(bytes));

  final String path;
  final List<int> bytes;
}

/// AL NOTE-owned preflight metadata; no package type crosses this boundary.
final class ArchiveEntryMetadata {
  const ArchiveEntryMetadata({
    required this.path,
    required this.compressedByteLength,
    required this.decodedByteLength,
    required this.compressionMethod,
    required this.requiresRegularUnixMode,
  });

  final String path;
  final int compressedByteLength;
  final int decodedByteLength;
  final int compressionMethod;
  final bool requiresRegularUnixMode;
}

/// A private memory-backed archive whose individual entries decode on demand.
final class BoundedMemoryArchive {
  BoundedMemoryArchive._(this._archive, this.entries);

  final Archive _archive;
  final List<ArchiveEntryMetadata> entries;

  /// Reads and CRC-verifies exactly one entry on demand.
  Result<List<int>, StructuredFailure> read(String path) {
    final metadata = entries.where((entry) => entry.path == path).firstOrNull;
    final entry = _archive.find(path);
    if (metadata == null || entry == null) {
      return Err<List<int>, StructuredFailure>(
        storageFailure('missing_entry', 'A required package entry is missing.'),
      );
    }
    if (!_isDecodedOrdinaryFile(entry, metadata)) {
      return Err<List<int>, StructuredFailure>(
        storageFailure('entry_type', 'A package entry is not a regular file.'),
      );
    }
    try {
      final bytes = entry.readBytes();
      if (bytes == null || bytes.length != metadata.decodedByteLength) {
        return Err<List<int>, StructuredFailure>(
          storageFailure(
            'entry_decoded_bytes',
            'An entry decoded size is invalid.',
          ),
        );
      }
      if (entry.crc32 == null || getCrc32(bytes) != entry.crc32) {
        return Err<List<int>, StructuredFailure>(
          storageFailure('entry_integrity', 'An entry failed CRC validation.'),
        );
      }
      return Ok<List<int>, StructuredFailure>(
        List<int>.unmodifiable(List<int>.of(bytes)),
      );
    } on Object {
      return Err<List<int>, StructuredFailure>(
        storageFailure(
          'entry_decoding',
          'A package entry could not be decoded.',
        ),
      );
    }
  }
}

/// Canonically encodes stored ZIP32 entries with fixed version-1 metadata.
Result<List<int>, StructuredFailure> encodeCanonicalZip(
  List<ArchiveEntryBytes> entries,
) {
  if (entries.length > 0xffff) {
    return Err<List<int>, StructuredFailure>(
      storageFailure('zip32', 'The package exceeds ZIP32 representability.'),
    );
  }
  var predicted = 22;
  for (final entry in entries) {
    if (entry.bytes.any((byte) => byte < 0 || byte > 255)) {
      return Err<List<int>, StructuredFailure>(
        storageFailure('archive_encoding', 'Archive bytes are not valid.'),
      );
    }
    final nameLength = ascii.encode(entry.path).length;
    if (entry.bytes.length > 0xffffffff || nameLength > 0xffff) {
      return Err<List<int>, StructuredFailure>(
        storageFailure('zip32', 'The package exceeds ZIP32 representability.'),
      );
    }
    predicted += 30 + nameLength + entry.bytes.length + 46 + nameLength;
    if (predicted > 0xffffffff) {
      return Err<List<int>, StructuredFailure>(
        storageFailure('zip32', 'The package exceeds ZIP32 representability.'),
      );
    }
  }
  try {
    final archive = Archive()..comment = null;
    for (final source in entries) {
      final file =
          ArchiveFile.noCompress(source.path, source.bytes.length, source.bytes)
            ..mode = 0x81a4
            ..comment = null
            ..creationTime = 315532800
            ..lastModTime = 315532800;
      archive.add(file);
    }
    final bytes = ZipEncoder().encodeBytes(
      archive,
      modified: DateTime.utc(1980),
    );
    if (bytes.length > 0xffffffff) {
      return Err<List<int>, StructuredFailure>(
        storageFailure('zip32', 'The package exceeds ZIP32 representability.'),
      );
    }
    return Ok<List<int>, StructuredFailure>(
      List<int>.unmodifiable(List<int>.of(bytes)),
    );
  } on Object {
    return Err<List<int>, StructuredFailure>(
      storageFailure('archive_encoding', 'The package could not be encoded.'),
    );
  }
}

/// Performs bounded raw ZIP preflight before exposing lazy entry decoding.
Result<BoundedMemoryArchive, StructuredFailure> openBoundedZip(
  List<int> source,
  AlnoteStorageLimits limits,
) {
  if (source.length > limits['alnote.storage.package_bytes']) {
    return Err<BoundedMemoryArchive, StructuredFailure>(
      storageFailure('package_bytes', 'The package byte ceiling was exceeded.'),
    );
  }
  try {
    if (source.any((byte) => byte < 0 || byte > 255)) {
      throw const _ZipRejected('package_bytes');
    }
    final bytes = Uint8List.fromList(source);
    final data = ByteData.sublistView(bytes);
    final eocd = _findEocd(data);
    if (eocd < 0 || eocd + 22 > bytes.length)
      throw const _ZipRejected('headers');
    final disk = data.getUint16(eocd + 4, Endian.little);
    final centralDisk = data.getUint16(eocd + 6, Endian.little);
    final diskEntries = data.getUint16(eocd + 8, Endian.little);
    final entryCount = data.getUint16(eocd + 10, Endian.little);
    final centralSize = data.getUint32(eocd + 12, Endian.little);
    final centralOffset = data.getUint32(eocd + 16, Endian.little);
    final commentLength = data.getUint16(eocd + 20, Endian.little);
    if (disk != 0 || centralDisk != 0 || diskEntries != entryCount) {
      throw const _ZipRejected('multi_disk');
    }
    if (entryCount == 0xffff ||
        centralSize == 0xffffffff ||
        centralOffset == 0xffffffff) {
      throw const _ZipRejected('zip64');
    }
    if (entryCount > limits['alnote.storage.entry_count']) {
      throw const _ZipRejected('entry_count');
    }
    if (commentLength != 0) throw const _ZipRejected('comments');
    if (eocd + 22 + commentLength != bytes.length ||
        centralOffset + centralSize != eocd) {
      throw const _ZipRejected('headers');
    }
    var cursor = centralOffset;
    var totalDecoded = 0;
    final names = <String>{};
    final localRanges = <_ByteRange>[];
    final metadata = <ArchiveEntryMetadata>[];
    for (var index = 0; index < entryCount; index += 1) {
      if (cursor + 46 > eocd ||
          data.getUint32(cursor, Endian.little) != 0x02014b50) {
        throw const _ZipRejected('headers');
      }
      final madeBy = data.getUint16(cursor + 4, Endian.little);
      final flags = data.getUint16(cursor + 8, Endian.little);
      final method = data.getUint16(cursor + 10, Endian.little);
      final crc = data.getUint32(cursor + 16, Endian.little);
      final compressed = data.getUint32(cursor + 20, Endian.little);
      final decoded = data.getUint32(cursor + 24, Endian.little);
      final nameLength = data.getUint16(cursor + 28, Endian.little);
      final extraLength = data.getUint16(cursor + 30, Endian.little);
      final entryCommentLength = data.getUint16(cursor + 32, Endian.little);
      final startDisk = data.getUint16(cursor + 34, Endian.little);
      final externalAttributes = data.getUint32(cursor + 38, Endian.little);
      final localOffset = data.getUint32(cursor + 42, Endian.little);
      final end = cursor + 46 + nameLength + extraLength + entryCommentLength;
      if (end > eocd || nameLength == 0) throw const _ZipRejected('headers');
      if (compressed == 0xffffffff ||
          decoded == 0xffffffff ||
          localOffset == 0xffffffff) {
        throw const _ZipRejected('zip64');
      }
      if ((flags & 1) != 0) throw const _ZipRejected('encryption');
      if ((flags & 0x0008) != 0) {
        throw const _ZipRejected('data_descriptor');
      }
      if ((flags & ~0x0800) != 0) throw const _ZipRejected('flags');
      if (method != 0 && method != 8) throw const _ZipRejected('compression');
      if (startDisk != 0) throw const _ZipRejected('multi_disk');
      if (nameLength > limits['alnote.storage.entry_name_bytes']) {
        throw const _ZipRejected('entry_name_bytes');
      }
      if (compressed > limits['alnote.storage.entry_compressed_bytes']) {
        throw const _ZipRejected('entry_compressed_bytes');
      }
      if (decoded > limits['alnote.storage.entry_decoded_bytes']) {
        throw const _ZipRejected('entry_decoded_bytes');
      }
      if (decoded > maximumWebSafeInteger - totalDecoded) {
        throw const _ZipRejected('total_decoded_bytes');
      }
      totalDecoded += decoded;
      if (totalDecoded > limits['alnote.storage.total_decoded_bytes']) {
        throw const _ZipRejected('total_decoded_bytes');
      }
      final ratio = limits['alnote.storage.compression_ratio'];
      final ratioExceeded =
          decoded > 0 &&
          (ratio == 0 ||
              compressed == 0 ||
              compressed <= maximumWebSafeInteger ~/ ratio &&
                  decoded > compressed * ratio);
      if (ratioExceeded) {
        throw const _ZipRejected('compression_ratio');
      }
      final nameBytes = bytes.sublist(cursor + 46, cursor + 46 + nameLength);
      final name = utf8.decode(nameBytes, allowMalformed: false);
      _validatePath(name, nameLength, limits);
      if (!names.add(name)) throw const _ZipRejected('duplicate_path');
      _validateExtra(data, cursor + 46 + nameLength, extraLength);
      if (entryCommentLength != 0) throw const _ZipRejected('comments');
      final localRange = _validateLocalHeader(
        data,
        bytes,
        localOffset,
        flags,
        method,
        nameBytes,
        crc,
        compressed,
        decoded,
        centralOffset,
      );
      if (localRanges.any((range) => range.overlaps(localRange))) {
        throw const _ZipRejected('overlapping_entries');
      }
      localRanges.add(localRange);
      final requiresRegularUnixMode = _validateEntryType(
        madeBy,
        externalAttributes,
      );
      metadata.add(
        ArchiveEntryMetadata(
          path: name,
          compressedByteLength: compressed,
          decodedByteLength: decoded,
          compressionMethod: method,
          requiresRegularUnixMode: requiresRegularUnixMode,
        ),
      );
      cursor = end;
    }
    if (cursor != eocd) throw const _ZipRejected('headers');
    localRanges.sort((left, right) => left.start.compareTo(right.start));
    if (localRanges.isEmpty || localRanges.first.start != 0) {
      throw const _ZipRejected('unowned_bytes');
    }
    for (var index = 1; index < localRanges.length; index += 1) {
      if (localRanges[index - 1].end != localRanges[index].start) {
        throw const _ZipRejected('unowned_bytes');
      }
    }
    if (localRanges.last.end != centralOffset) {
      throw const _ZipRejected('unowned_bytes');
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.length != metadata.length)
      throw const _ZipRejected('duplicate_path');
    for (final entryMetadata in metadata) {
      final entry = archive.find(entryMetadata.path);
      if (entry == null || !_isDecodedOrdinaryFile(entry, entryMetadata)) {
        throw const _ZipRejected('entry_type');
      }
    }
    return Ok<BoundedMemoryArchive, StructuredFailure>(
      BoundedMemoryArchive._(
        archive,
        List<ArchiveEntryMetadata>.unmodifiable(metadata),
      ),
    );
  } on _ZipRejected catch (rejected) {
    return Err<BoundedMemoryArchive, StructuredFailure>(
      storageFailure(
        rejected.dimension,
        'The ZIP package violates a required policy dimension.',
      ),
    );
  } on Object {
    return Err<BoundedMemoryArchive, StructuredFailure>(
      storageFailure('headers', 'The ZIP package headers are malformed.'),
    );
  }
}

bool _validateEntryType(int madeBy, int externalAttributes) {
  final creator = madeBy >> 8;
  final dosAttributes = externalAttributes & 0xffff;
  const allowedOrdinaryDosAttributes = 0x0027;
  if ((dosAttributes & ~allowedOrdinaryDosAttributes) != 0) {
    throw const _ZipRejected('entry_type');
  }
  switch (creator) {
    case 0:
      final unixType = externalAttributes >> 16 & 0xf000;
      if (unixType != 0 && unixType != 0x8000) {
        throw const _ZipRejected('entry_type');
      }
      return unixType != 0;
    case 3:
      final unixType = externalAttributes >> 16 & 0xf000;
      if (unixType != 0x8000) throw const _ZipRejected('entry_type');
      return true;
    default:
      throw const _ZipRejected('entry_type');
  }
}

bool _isDecodedOrdinaryFile(ArchiveFile entry, ArchiveEntryMetadata metadata) {
  if (!entry.isFile || entry.isDirectory || entry.isSymbolicLink) return false;
  return !metadata.requiresRegularUnixMode || entry.mode & 0xf000 == 0x8000;
}

int _findEocd(ByteData data) {
  final first = data.lengthInBytes > 65557 ? data.lengthInBytes - 65557 : 0;
  for (var cursor = data.lengthInBytes - 22; cursor >= first; cursor -= 1) {
    if (data.getUint32(cursor, Endian.little) == 0x06054b50) return cursor;
  }
  return -1;
}

void _validateExtra(ByteData data, int offset, int length) {
  var cursor = offset;
  final end = offset + length;
  while (cursor < end) {
    if (cursor + 4 > end) throw const _ZipRejected('headers');
    final id = data.getUint16(cursor, Endian.little);
    final size = data.getUint16(cursor + 2, Endian.little);
    cursor += 4;
    if (cursor + size > end) throw const _ZipRejected('headers');
    if (id == 0x0001) throw const _ZipRejected('zip64');
    if (id == 0x9901) throw const _ZipRejected('encryption');
    throw const _ZipRejected('unsupported_extra');
  }
}

_ByteRange _validateLocalHeader(
  ByteData data,
  Uint8List bytes,
  int offset,
  int centralFlags,
  int centralMethod,
  List<int> centralName,
  int centralCrc,
  int compressed,
  int decoded,
  int centralOffset,
) {
  if (offset < 0 ||
      offset + 30 > centralOffset ||
      data.getUint32(offset, Endian.little) != 0x04034b50) {
    throw const _ZipRejected('headers');
  }
  final flags = data.getUint16(offset + 6, Endian.little);
  final method = data.getUint16(offset + 8, Endian.little);
  final crc = data.getUint32(offset + 14, Endian.little);
  final localCompressed = data.getUint32(offset + 18, Endian.little);
  final localDecoded = data.getUint32(offset + 22, Endian.little);
  final nameLength = data.getUint16(offset + 26, Endian.little);
  final extraLength = data.getUint16(offset + 28, Endian.little);
  final end = offset + 30 + nameLength + extraLength;
  if (end > centralOffset ||
      flags != centralFlags ||
      method != centralMethod ||
      crc != centralCrc ||
      localCompressed != compressed ||
      localDecoded != decoded) {
    throw const _ZipRejected('ambiguous_metadata');
  }
  if (!_listEquals(
    bytes.sublist(offset + 30, offset + 30 + nameLength),
    centralName,
  )) {
    throw const _ZipRejected('ambiguous_metadata');
  }
  _validateExtra(data, offset + 30 + nameLength, extraLength);
  final dataEnd = end + compressed;
  if (dataEnd > centralOffset) throw const _ZipRejected('headers');
  return _ByteRange(offset, dataEnd);
}

void _validatePath(String path, int nameBytes, AlnoteStorageLimits limits) {
  if (path.isEmpty ||
      path.length != nameBytes ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains('//') ||
      RegExp(r'^[a-zA-Z]:').hasMatch(path) ||
      path.codeUnits.any((code) => code < 0x20 || code > 0x7e) ||
      path != path.toLowerCase()) {
    throw const _ZipRejected('entry_path');
  }
  final segments = path.split('/');
  final callerSegmentLimit = limits['alnote.storage.entry_path_segments'];
  final effectiveSegmentLimit = callerSegmentLimit < maximumAlnotePathSegments
      ? callerSegmentLimit
      : maximumAlnotePathSegments;
  if (segments.length > effectiveSegmentLimit ||
      segments.any((segment) => !_safeSegment(segment))) {
    throw const _ZipRejected('entry_path');
  }
  final allowed =
      path == 'mimetype' ||
      path == 'manifest.json' ||
      path == 'document.json' ||
      _typedRecordPath(path, 'sections') ||
      _typedRecordPath(path, 'pages') ||
      RegExp(r'^resources/[0-9a-f]{2}/[0-9a-f]{64}$').hasMatch(path) ||
      isCanonicalAlnoteExtensionPath(path);
  if (!allowed) throw const _ZipRejected('entry_path');
}

bool _typedRecordPath(String path, String directory) {
  final prefix = '$directory/';
  if (!path.startsWith(prefix) || !path.endsWith('.json')) return false;
  final text = path.substring(prefix.length, path.length - 5);
  final parsed = UuidIdentifier.parse(text);
  return parsed is Ok<UuidIdentifier, StructuredFailure> &&
      parsed.value.value == text;
}

bool _safeSegment(String segment) {
  if (segment.isEmpty || segment == '.' || segment == '..') return false;
  final base = segment.split('.').first;
  return !RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$').hasMatch(base);
}

final class _ByteRange {
  const _ByteRange(this.start, this.end);
  final int start;
  final int end;

  bool overlaps(_ByteRange other) => start < other.end && other.start < end;
}

bool _listEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class _ZipRejected implements Exception {
  const _ZipRejected(this.dimension);
  final String dimension;
}
