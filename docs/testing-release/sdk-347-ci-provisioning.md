# SDK adoption CI corrections R1/R2

Status: R1 and R2 implemented and verified, awaiting independent review. The
[publication follow-up](sdk-347-ci-resource-publication.md) records the authorized
immutable resource/source release, final acquisition tooling and successful fresh
Linux build using the public remote asset. No SDK adoption is implied.

The remainder of this report records the initial R1/R2 pass, before publication
authorization; its approval requests are historical, not new requirements.
Scope is test/provisioning tooling and CI. Accepted SDK, lockfile, vendor patches,
PDF admission, native binaries, package pins and rollback resources are unchanged.

## R1: explicit fixture library

`tool/provision_pdf_fixture.py` acquires the exact Chromium 7811 artifact already
selected by `pdfium_dart 0.2.5`. It checks the pinned compressed archive length and
SHA-256 before reading the single library member, then checks its length and
SHA-256. It extracts no other archive paths. Publication is atomic and exclusive;
existing corrupt files reject instead of being silently replaced. An offline
archive passes the same verification. Python's standard library is sufficient.

`test/flutter_test_config.dart` configures the supported
`Pdfrx.pdfiumModulePath` API before test registration, after independently checking
the local library. It does not initialize the engine early. Existing tests retain
initialization/disposal ownership and admission assertions. Missing, wrong-length,
corrupt or symlinked libraries fail before native initialization; SDK discovery is
not a fallback. Browser tests do not use this native setup. Linux and Windows CI
now provision their fixture library before the existing test step. No gates or
fixture tests were removed or skipped.

| Target | Upstream archive / SHA-256 | Extracted library / SHA-256 |
|---|---|---|
| Linux x64 | [pdfium-linux-x64.tgz](https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/7811/pdfium-linux-x64.tgz), `e76e0a37aefb843d56f04657475ce612157021b1ebc53d801f2fbfcc537ccf64` | `lib/libpdfium.so`, `d106072a29b3689a5d6739948f98a97fe3ec82f5a1c309dc44e86f6c549fb44e` |
| Windows x64 | [pdfium-win-x64.tgz](https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/7811/pdfium-win-x64.tgz), `2e7af12674ac3716cb0e20369bb9fb269ceadfa2f0b0597097a520e6834175a0` | `bin/pdfium.dll`, `019b6ee6e54e5508002e43c5199b00f6caca26d32dd23c7bb229ff6855cd5394` |

Both archives matched the digests returned by the upstream GitHub release API.
The Linux member also matches the previously accepted local fixture library.
The complete pins and lengths are in `tool/pdf_fixture_resources.json`. This is
checksum verification, not a signature/provenance authentication claim. Windows
archive bytes were checked on Linux; Windows loader/runtime execution is unverified.

From a source checkout with the accepted SDK on PATH:

```sh
flutter pub get --enforce-lockfile
python3 tool/provision_pdf_fixture.py
flutter test --no-pub test/documents/pdf_fixture_setup_test.dart test/documents/pdfrx_patch_test.dart
```

On Windows use `python` for the same script. The default library directory is
`build/pdf-fixture`. For a separate verified location, pass `--directory` and set
`ALNOTE_PDF_FIXTURE_LIBRARY` to its exact library path when running tests. This
environment variable is consumed by AL NOTE's test bootstrap, which verifies the
bytes and sets the public API; it is not reliance on the dependency's discovery.
`--archive PATH` supports an already downloaded pinned archive and `--verify-only`
checks the destination without acquisition. No SDK files need modification.

## R2: exact package verification, distribution still blocked

The reviewed package has 114 resource files (21,574,898 payload bytes) plus its
manifest. The manifest digest remains
`82d1b451f94b2fa641a6931a899cfae781e23659fe5e1d17eb303d9a2d0fe298`.
`tool/linux_pdf/verify_package.py` checks agreement with the existing Dart/CMake
pins, exact file membership, regular/read-only files, lengths and every digest.
It rejects missing, extra, symlinked, writable, corrupt and wrong resources. It
never changes a pin or repairs a rejected package. This is verification of an
already acquired package, **not a remote provisioning implementation**:

```sh
python3 tool/linux_pdf/verify_package.py build/linux-pdf-resources
```

No viable exact-package remote source/build route is currently recorded:

- `controlled_engine.json` identifies a controlled local source build and
  explicitly disclaims cross-machine bit reproducibility. It uses the development
  container's system headers with `use_sysroot=false`.
- `package_resources.py` consumes ignored engine/tool outputs and copies runtime
  files from the host's `/lib64` and `/usr/share/licenses`.
- The accepted runtime includes Fedora `glibc-2.43-7.fc44` and
  `gcc-16.1.1-2.fc44` bytes. An ordinary Ubuntu runner build does not establish
  those exact resources. The publisher engine archive is a different, quarantined
  artifact and cannot substitute for the controlled engine.

Source/dependency revision records are useful provenance, but do not establish a
working byte-identical clean build. No unverified rebuild, runtime substitution,
new binary hashes or automatic hash approval was attempted. No local package was
copied into the fresh checkout to disguise the missing remote route. The CMake
install guard remains unchanged; the current Linux CI build remains blocked on R2.

The smallest next step is an approved immutable distribution source for the exact
reviewed package, verified before Linux installation. An existing approved URL can
be supplied, or publication of the reviewed package needs explicit authorization.
Publication, credentials, new services, changed native packaging and CI triggers
remain outside this correction's authorization. Fixture PDFium is not that package.

## Verification and preservation

Local evidence: `build/sdk-ci-r1-r2/`.

- Auditor's missing-SDK-library command: reproduced the original failure, then
  passed unchanged through the repository bootstrap (one test, 40 geometry cases).
- Focused bootstrap and native fixture tests: 12 passed.
- Provisioning/verifier unit tests: 14 passed, using controlled non-executable bytes.
- Three process-level invalid fixture paths (missing, same-length corruption,
  isolated-engine substitution): rejected before native loading, with no SDK fallback.
- Actual package verifier: 114 entries passed. Missing directory/resource, corrupt
  worker, fixture-engine substitution and old manifest all rejected. These local
  copies are verifier-negative tests, not remote CI provisioning evidence.
- Strict fatal-info analysis passed after replacing one metadata query with its
  synchronous equivalent required by the existing lint. No analysis rule changed.

Fresh full suite: **890 passed, 14 existing skips**. This one full run was warranted
by the global native-test bootstrap change. The fresh Linux build completed
compilation and rejected installation at the unchanged required-package guard
(exit 1); it is **not a successful Linux build**. No source/code fix followed the
full run; only this report/evidence was finalized.

The fresh source tree began without
`build` or `.dart_tool`; a separate initially empty `PUB_CACHE` is used. Its SDK was
extracted from the retained, rehashed approved archive and has no fixture-library
symlink. The archive SHA-256 is unchanged; the earlier user-approved exception still
applies and SDK provenance signatures remain UNVERIFIED. Execution uses existing
`al-note-dev` build prerequisites; this is not a new VM or a GitHub Actions run.

Fresh checkout: `/tmp/alnote-sdk-ci-fresh-ac1u9cwk/AL-NOTE`; SDK and package cache
are separate sibling directories. `fresh_verify.py`, `fresh-results.json` and
`fresh-*.log` record the exact commands and outcomes. The SDK link and isolated
package remain absent after the run; fresh fixture bytes and lockfile match the
maintained pins (`fresh-final-check.json`). This proves fixture acquisition from
upstream, not remote acquisition of the isolated package.

No engine/host-security audits, native engine rebuild, new dependencies, Android
build, Web build, Windows execution or CI trigger are part of this correction.
Ordinary-PDF admission and application behavior are unchanged. Existing physical
input/GPU and Save/Reopen performance limitations remain open.

The pre-correction source hashes and workflow copy are retained under
`build/sdk-ci-r1-r2/`. The prior SDK rollback snapshot/inventories remain untouched;
restore this correction's delta first before using that older guarded rollback.


## Exact correction delta and remaining decision

Only nine paths changed relative to the accepted candidate working tree:

- `.github/workflows/verify.yml`: fixture acquisition before Linux/Windows tests;
  all existing platform gates and accepted SDK pins remain.
- `tool/pdf_fixture_resources.json`, `tool/provision_pdf_fixture.py`: fixed
  fixture-origin/archive/member pins and verified acquisition.
- `test/flutter_test_config.dart`, `test/support/verified_fixture_library.dart`:
  verified explicit module-path setup, without early native initialization.
- `test/documents/pdf_fixture_setup_test.dart`, `tool/test_pdf_provisioning.py`:
  initialization and negative-resource regressions.
- `tool/linux_pdf/verify_package.py`: complete local package verification only.
- This report.

No R2 remote source was invented or added to CI. Recheck R1 independently now;
R2 and SDK adoption remain blocked. The smallest proposed distribution operation
is publishing the **unchanged** reviewed package as a dedicated CI-resource asset
in the existing `AlmawriHamdi/AL-NOTE` GitHub repository, with a dedicated resource
tag if needed. That publication/tag/credential use requires explicit user approval
before implementation. Supplying an existing approved immutable download URL is
another route. Neither grants application release or ordinary-PDF enablement.
