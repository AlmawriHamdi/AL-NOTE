# Phase 7 image fixture provenance

The image byte fixtures in `test/documents/phase7_objects_test.dart` contain no
external or personal source material and are not runtime assets.

- PNG: signature plus a 2-by-3 RGBA IHDR and IEND marker.
- JPEG: SOI, JFIF 72-DPI metadata, little-endian EXIF orientation 6, a 3-by-2
  baseline SOF, and EOI.

They intentionally contain only enough bytes for AL NOTE's bounded header
preflight tests; they are not claimed to be generally decodable pixel images.

The Flutter decoder tests additionally use two complete, decodable Base64
fixtures kept directly beside the tests and decoded only in the test process:

- a recorded 1-by-1 transparent PNG; and
- a deterministic 2-by-1 JPEG generated on 2026-08-12 with
  `System.Drawing.Bitmap`, using one red pixel and one blue pixel, then encoded
  to JPEG entirely in memory.
