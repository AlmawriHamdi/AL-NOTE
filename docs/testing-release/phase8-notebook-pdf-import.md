# Notebook PDF page import

Implementation handoff for Main AI and independent review. Linux private PDF
acceptance and source-capture C1 were previously accepted; this is a separate
notebook-import change, not Phase 8 or release approval.

## Workflow and exact scope

The notebook toolbar offers **Import PDF pages**, separately from standalone
Open PDF. Source acquisition and inspection reuse the existing bounded picker,
`LocalPdfOpenWorkflow`, immutable source capture and approved backend admission.
The temporary standalone preparation is never installed. The user enters `all`
or one-based numbers/ranges such as `1, 3-5`. Repeated/overlapping selections are
collapsed and inserted in source order, after the current Page in its existing
Section. No thumbnails are generated.

- `lib/documents/pdf/pdf_notebook_import.dart`: bounded selection parsing and
  asynchronous immutable preparation. New Page and Layer UUIDs are generated
  without changing the notebook; source references and authoritative geometry
  are reused exactly. One source resource is shared across the imported Pages.
- `lib/documents/commands/command_contracts.dart`: one `ImportPdfPagesRequest`
  plus additional retained-structure cost evidence for history admission.
- `lib/documents/commands/document_mutation_coordinator.dart`: validates the
  destination Section/Page revisions and resource catalog, notebook capacity,
  fresh identities, ordered PDF source Pages and complete candidate root. It
  uses the existing preparation/publication/history machinery. Matching existing
  resource identity/digest/metadata reuses the active immutable snapshot; identity
  conflicts reject. Resource subsetting and a new storage deduplication policy
  are not introduced.
- The coordinator records live Page/Layer revisions on import and removes them
  on Undo. Redo restores exact persistent values and IDs with fresh revision
  generations. Previously issued Page/Layer IDs cannot be reused by a new import.
  Resource bytes and a conservative 4 KiB per imported Page structure estimate
  participate in the existing history ceiling. A rejected history plan changes
  no root, resources, saved checkpoint, history or observers.
- `lib/ui/canvas/phase6_canvas.dart`: minimal selection dialog, cancellation and
  stale-owner checks, and one command execution. The current notebook Page,
  Selection, saved checkpoint and live text editor remain in place. Import does
  not commit or discard the draft. Immediate import Undo/Redo also retains that
  draft; other text/save/history behavior remains established behavior.
- Undo/Redo gains the same optional companion-publication hook already used by
  command execution. Canvas installs navigation/status and any required detached
  cleanup before observers. Undo while viewing a removed imported Page safely
  returns to a surviving Page. Publication uses the existing owner-notification
  batch; no second transaction or replacement coordinator is created for import.
- The selection route finishes its exit animation and overlay disposal before
  command publication, so a synchronous observer can replace or dispose Canvas
  without leaving an outgoing dialog attached to obsolete state. Successful
  publication has no later owner writes that could overwrite observer actions.

New regressions live in `test/documents/pdf_notebook_import_test.dart` and
`test/support/pdf_notebook_import_checks.dart`; `test/widget_test.dart` registers
the latter. Existing tracked and untracked work is retained. Scope hashes and
logs are under `/tmp/al-note-notebook-import/`. The incremental scope is **4
modified existing files, 4 added files, zero removals, 506 unchanged baseline
files**. HEAD remains `921e43f41a31b0649a2ae890c993fd4e406ad39a` on
`phase-8-pdf-system`.

## Bounds and limitations

Selection text is limited to 8,192 code units; numbers use at most four digits.
At most 1,000 source/imported Pages and 10,000 total notebook Pages are admitted
by this operation, additionally subject to existing backend/model/history limits.
Page preparation yields every 32 selected Pages and checks cancellation around
identity allocation and preparation. Source selection/inspection remains bounded
by the unchanged 50,000,000-byte private Linux ceiling. All source Pages are
inspected before selection; the full immutable PDF is retained even for a subset.
Repeated imports may repeat source acquisition/inspection; no parser cache is added.

The existing 10,000,000-byte production history budget can reject an import even
when the PDF can be opened as a standalone document. Ordinary input remains
untrusted and requires the existing Linux x86-64 private-debug capability.
There is no in-process Linux fallback, release enablement, or Windows/Web ordinary
admission. No Android PDF implementation, movable PDF Object insertion, extraction,
password entry, export, dependency or package changes are included.

**Save/Reopen remains in-memory, not durable export.** Storage ceilings are not
increased. A PDF that opens may exceed the separate 10 MB storage limits.
Save/Reopen performance is unchanged: the prior independent measurements were
2.20 seconds of UI stall for 8 MB Reopen and 4.69 seconds for a 50 MB rejected Save;
2.21 GB was the process high-water RSS across that run, not allocation attributed
solely to one operation. These findings and zoom preservation remain separate
fixes-milestone work. No new responsiveness or low-memory guarantee is claimed.

## Verification

Verification on the final production source:

- **Full Flutter suite: 888 passed, 14 explicit host/private opt-in skips**, one
  invocation, 2m37s (`full-suite.log`). No source/test changes followed this run.
- **85 affected Canvas/PDF/Undo/Redo checks passed** after the toolbar correction
  (`affected-canvas-verified.log`).
- **32 focused import checks passed** before the final toolbar adjustment, whose
  affected widget cases passed again in the 85-case run. Four additional live-draft
  observer combinations then joined the final suite; all **8 observer combinations
  passed** in their focused rerun (`observer-analysis-final.log`).
- **Fatal-info analysis passed**, no issues (`observer-analysis-final.log`).
- **Formatting: 7 changed Dart files, zero changes** (`format-final.log`).
- Actual-host private import plus existing Linux Canvas checks passed **4 tests**
  (`host-import.log`). Existing Linux protocol/cleanup/correction checks passed
  **14 tests** (`host-regressions.log`), including confirmed empty cgroups and
  reaped launchers with four worker PIDs in each controller-outage round.
- **Linux private debug build passed** (`linux-build.log`); the generated Linux
  SDK header remains present. **Web release compilation and Wasm dry run passed**
  with the Linux private define supplied (`web-build.log`). Existing conditional
  gates still exclude ordinary Web PDFs. Web emitted the pre-existing nonfatal
  CupertinoIcons font notice; no font/package change was made.
- **Final post-build actual-host rerun: 4 passed** (`host-import-final.log`),
  covering import, standalone/live-draft opening, missing-package retention and
  in-flight disposal/reaping against the final shared UI. Final read-only service
  inventory found **zero remaining PDF worker units** (`final-worker-units.txt`).

The full suite was run once. Its production and test file hashes remain unchanged
through the builds and final host rerun (`final-code-hashes.json`). The earlier
14-case protocol/cleanup run was not repeated after the toolbar-only adjustment;
its worker, scheduler, protocol and cleanup sources did not change. Linux/Web
builds refreshed generated outputs; protected engine sources/binaries, worker,
package pins, dependencies, lockfile, CI and storage code remained unchanged.

These are automated flows on the reviewed host, not a claim of manual acceptance
of the standalone application. No engine rebuild, package-pin change, dependency
upgrade, Android/Windows build, or renewed engine/vendor audit was performed.

Development failures are retained in the logs: the first disposal harness lacked
a Flutter View; subsequent testing exposed publication during the outgoing dialog
animation, fixed by awaiting route completion. Reopen assertions were strengthened
to scroll and actually activate the control; pending-backend assertions now await
inspection entry; Selection compares its meaningful geometry rather than a newly
constructed diagnostic object's identity. One duplicate test declaration and
format/lint findings were fixed during development. An affected baseline run also
caught the new button shifting the toolbar's fixed five-control partition. Import
now follows the original document controls and the partition count is explicit;
the existing Save/Reopen and navigation positions are preserved.

## Reproduction commands

Use the logical repository path consistently. The existing verified worker
package must be present; do not rebuild the engine or run `flutter clean`.

Focused import tests in the existing development container:

```sh
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && /home/Hamdi/Development/flutter-3.44.6/bin/flutter test --no-pub test/documents/pdf_notebook_import_test.dart test/widget_test.dart --name "Notebook PDF import|PDF import" --reporter expanded'
```

Actual-host import, standalone opening and disposal checks:

```sh
cd /home/Hamdi/Projacts/AL-NOTE
/home/Hamdi/Development/flutter-3.44.6/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true --dart-define=ALNOTE_LINUX_PRIVATE_HOST_TEST=true test/widget_test.dart --name 'private Linux notebook PDF import|Linux integrated' --reporter expanded
```

Existing actual-host protocol/cleanup checks, serially after the preceding run:

```sh
cd /home/Hamdi/Projacts/AL-NOTE
/home/Hamdi/Development/flutter-3.44.6/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_INTEGRATION_TEST=true test/documents/linux_pdf_integration_test.dart test/documents/linux_pdf_correction_test.dart --reporter expanded
```

Private Linux application build and host launch:

```sh
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && /home/Hamdi/Development/flutter-3.44.6/bin/flutter build linux --debug --no-pub --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true'
cd /home/Hamdi/Projacts/AL-NOTE
./build/linux/x64/debug/bundle/al_note
```

## Manual acceptance checklist

1. Draw notes in a notebook; optionally leave a live text draft. Import a small,
   unencrypted PDF using `all`. Confirm the notebook and draft remain intact and
   the new Pages follow the current Page.
2. Import again using `3, 1-2` (for a source with at least three Pages). Confirm
   source order, correct Page dimensions, a locked source and editable annotations.
3. Undo once to remove that import; Redo once to restore it. Repeat Undo while
   viewing an imported Page and verify navigation remains valid.
4. Draw/edit an annotation on an imported Page. Save in memory and Reopen saved;
   check original notes, imported sources and annotations. This is not disk export.
5. Enter an invalid range, cancel selection/preparation, and try an unsupported or
   oversized source. Confirm no partial import, lost notes or lost draft.
6. Confirm Open PDF still performs the separate standalone-opening workflow.

No commits, pushes, PR changes, tags, merges or publication are part of this task.
Stop for Main AI and independent review after final verification.
