# Guarded existing-photo date repair

For AkaakuHub/immich-windows, upstream Immich v3.3.0 at `e3b165609135365302e40a43d94967fdbb2e6888`. This is a single optional Windows maintenance tool, not a startup hook, background job, or normal metadata refresh. Releasing/building it does not authorize running it on a library.

## Double-click repair

1. Open `runtime\metadata-date-repair\Repair-MetadataDates.cmd` in the extracted package or installed release. No terminal commands are required.
2. If more than one registered installation is found, choose the installation. An AllUsers installation requests the normal Windows administrator confirmation.
3. Choose a new scan or resume. For resume, select the exact previous repair folder in the folder picker. Then choose the Immich user by number. The utility reads the selected installation's existing configuration and automatically checks that user's candidates.
4. Review the selected user, effective server timezone, candidate/repair/exclusion counts, and the historical-edit warning. Enter `1` to repair that exact plan or `0` (or Enter) to cancel.
5. Keep the window open while progress is displayed. The final result and private plan/recovery-record folder remain visible until you close the window.

UUIDs, environment paths, timezone strings and approval hashes do not need to be entered or copied. Japanese and English follow the Windows UI language. User listing is read-only and does not start ExifTool. The existing installed PowerShell 7 and Node runtimes are used; nothing is downloaded.

Discovery uses existing installer records and validates the current release and configuration. Missing, inconsistent or ambiguous records stop with a visible error; the utility does not guess another installation, database or timezone. Cancelling Windows elevation does not start a repair. The selected installation stays fixed across elevation, even if another administrator approves it.

Each run writes its plan and recovery journals under the selected data directory's `state/metadata-date-repair/repair-*` directory. These records inherit that installation's access controls. No date changes occur until the confirmation. A failed apply can have earlier committed changes: retain these records and reconcile before attempting another write; the utility does not retry uncertain writes. The guided scan continues until the selected user’s candidate scope is exhausted, with no total-count limit. Pages and saved chunks remain bounded; an incomplete scan is never applied.

## Failure logs and resuming a scan

In the guided launcher, caught failures are recorded as `failure.json` in the new private repair folder, before runtime cleanup. The record contains a safe phase, error code/class, optional asset UUID/cursor and completed-page counters. It excludes raw messages, source paths, SQL, credentials and environment values. A cleanup failure is recorded separately. Advanced CLI commands emit the same structured safe diagnostic to stderr; file logging is provided by the guided launcher. If the log cannot be saved (for example disk full), the window keeps both the original safe diagnostic and the log-write failure visible.

Choose **Resume** and select the previous folder. The tool reads only the exact saved part files and index in that folder, plus any immutable part references already recorded by that index; it does not search media folders. Completed parts from v3.2.4.6 are accepted only for the exact recognized tool bytes and unchanged owner, runtime, timezone, database and schema identity. Gaps, malformed parts, unknown tools or identity mismatches stop. Existing plan files are neither copied nor relabeled nor changed. A fresh index references their exact byte hashes; new work is saved in a new private folder.

New indexes are atomically checkpointed after each completed 1,000-candidate chunk. An old v3.2.4.6 scan may have an empty index, but its complete consecutively numbered part files can be verified and reused. The unfinished chunk must be read again. An unreferenced tail after a newer checkpoint is not trusted; scanning resumes at the checkpoint cursor. Keep every referenced repair folder until repair/recovery is finished.

Resume is still planning. It shows the complete proposed/excluded counts and requires a new approval. Apply rechecks the current database snapshot, original metadata and exact date-field CAS for every proposed asset; stale or changed data stops rather than being overwritten. Missing or access-denied source files are explicitly excluded with their IDs/reasons. Database errors, unexpected I/O and output-write failures stop. A resumed keyset pass does not revisit new or changed candidates behind its saved UUID cursor; it is not a claim about concurrent changes to the whole library.

## Scope and uncertainty

The tool proposes only `asset.localDateTime` and `asset_exif.timeZone` changes. It preserves the exact existing `asset.fileCreatedAt` and `asset_exif.dateTimeOriginal` instants. PostgreSQL's existing `updated_at` triggers also advance each changed row's `updatedAt` and `updateId`; those automatic revision changes are checked and journaled by revision ID.

A database date edit made long ago, or an XMP sidecar subsequently deleted, can leave no distinguishing marker. These guards cannot prove that every historical manual edit is absent. Absence of a remembered manual edit is not proof that no historical edit occurred. The guided flow requires deliberate acknowledgement of this residual ambiguity before applying its exact displayed plan.

The default policy is deliberately strict:

- One selected owner; bounded UUID-keyset candidate pages, at most 1,000 candidates per plan chunk and 100 per page (default page size 25); the guided flow continues until no further candidates remain
- PNG/JPEG still images only; exclude edited/offline/deleted assets and either direction of a live-photo link
- Existing `fileCreatedAt`, `localDateTime`, and `dateTimeOriginal` must agree exactly at millisecond precision; existing timezone must be null; no active metadata locks
- No linked sidecar; check only the two conventional sibling XMP paths on Windows, without directory enumeration
- Reject source links/reparse paths, nonregular files, failed metadata reads, empty metadata, warnings/errors, unexpected MIME types, motion-photo markers, and any parseable or malformed nonempty capture-date tag
- A valid capture timestamp without a timezone is still a capture timestamp and is excluded
- Reject any existing/inferred source timezone, including GPS-derived zones
- Stored actual instant must also match the earliest current filesystem creation/modification time used by Immich's fallback; an earlier stored timestamp without this independent match is excluded as `stored-instant-not-filesystem-anchored`
- Recompute with the installed patched `MetadataService.getDates`, preserving its exact configured metadata reader and timezone behavior

Filesystem anchoring may exclude legitimate uploaded images whose on-disk dates changed during transfer. There is intentionally no override to force such uncertain cases. Excluded items remain untouched. This is not a universal repair for screenshots or missing EXIF timezones.

## What the tool does not do

No reuploads, image display, original writes/copies/moves, whole-media hashes, setting changes, service restarts, job queues, workflow events, metadata extraction handlers, API-based asset updates, schema migrations, or application/Nest bootstrap. It loads a small set of installed runtime modules and uses their existing dependencies. There are no new dependencies.

Originals are read only for metadata/stat information. Reading may update filesystem access times according to the operating system; access time is not a source fingerprint. Small hashes of six installed runtime/package files and the five maintenance-tool modules bind plan approval to the same implementation; these are not photo hashes.

Plans are text and contain asset IDs, original paths, relevant dates/revisions/flags, the proposed two-field change, and small stat/metadata evidence. Keep them private. Journals contain only plan identity and per-ID old/new date fields and revision IDs, never photo content, paths, complete EXIF dumps, or credentials. Existing output files are never overwritten.

## Installation layout

Package the launcher and its supporting files under `runtime/metadata-date-repair/`:

- `Repair-MetadataDates.cmd` and `Start-MetadataDateRepair.ps1` (guided launcher)
- `MetadataDateRepair.Launcher.psm1` (installation discovery)
- `guided.cjs`
- `resume.cjs` (verified immutable-part resume)
- `Repair-MetadataDates.ps1` (advanced CLI wrapper)
- `cli.cjs`
- `core.cjs`
- `runtime.cjs`

The standalone launcher loads the selected installed `runtime/launchers/Load-ImmichEnv.ps1` without `-ServiceRole`, invokes the packaged Node executable, and restores its process environment afterward. It never starts the server. The installed release root contains `manifest.json`, `server/`, and `runtime/`; it is not the build-stage application directory.

Runtime compatibility is fail-closed: Windows, exact upstream commit/version, known enum values, actual installed-method synthetic self-tests, expected timestamp schema, and only the pinned UPDATE trigger body. DELETE-only audit triggers are not confused with UPDATE triggers. Import/SQL/cleanup failures stop the operation. Upstream raw SQL/error logging is suppressed; errors print sanitized codes only.

The requested timezone must exactly match the effective Luxon timezone loaded from the selected service environment/system. The tool never sets `TZ` to make the check pass. If the configured running server differs, establish the correct environment separately before planning; changing settings is outside this tool. The plan binds runtime hashes, effective zone, database endpoint/name, schema/trigger fingerprints, and the exact owner/IDs. A different build, timezone, database target, snapshot, or source requires a new plan.

## Advanced CLI usage and approval

Review the candidate scope and plan before applying changes. Use explicit existing install and env-file paths; do not put credentials on the command line. The PowerShell launcher accepts the ordinary Node arguments after its own named parameters. To avoid shell-argument ambiguity, a new `pwsh -File` invocation is recommended.

First run the packaged-runtime self-test in the isolated build/test environment. It imports the real modules and calls the actual date method with synthetic data; it opens no database and reads no media. The separate CI integration test must also pass before describing production compatibility as verified.

A separately authorized planning invocation would be:

```powershell
pwsh -NoProfile -File "<release>\runtime\metadata-date-repair\Repair-MetadataDates.ps1" -ReleaseRoot "<release>" -EnvFile "<existing immich.env>" plan --owner-id "<owner UUID>" --expected-timezone "Asia/Tokyo" --limit 100 --page-size 25 --out "<private text directory>\plan.json"
```

`plan` is the default command and performs PostgreSQL reads in actual read-only transactions. It does not write any database row. Returned candidates are paged by UUID, and linked sidecar/live-photo checks are part of that page's SQL statement rather than per-candidate SQL round trips. A small page limit bounds returned candidates and source reads; it does not promise PostgreSQL avoids an internal broad scan. `exhausted` refers only to this SQL candidate scope. If bounded early, `nextAfterId` can be supplied explicitly in a new planning invocation. The `plan-all` command below automates chunking when a larger scan is explicitly requested.

Review every exact before/after proposal. `review --plan plan.json` works offline and prints a canonical SHA-256 plan digest and summary. The digest is over parsed canonical JSON, not formatting or raw file bytes. Neither a generated plan nor its digest is itself permission to apply.

After explicit approval of those IDs/values and disclosure of the historical ambiguity, an operator would use:

```text
apply --owner-id <UUID> --expected-timezone Asia/Tokyo --plan plan.json --approved-plan-sha256 <reviewed digest> --journal apply.jsonl --acknowledge-history-ambiguity
```

Pass the same installed runtime/env context through the launcher. The acknowledgement flag is a deliberate operator gate, not an authentication or historical-proof mechanism. Building or installing the tool does not grant permission to apply a plan. Command-irrelevant options are rejected; e.g. `apply --limit 1` cannot silently imply a smaller batch. To change a batch, prepare and approve a different exact plan.

## One command for a large approved scan

`plan-all` uses the same read-only planner, automatically walking UUID-keyset chunks of at most 1,000 candidates. By default it continues until the candidate scope is exhausted, without a total-count limit. Advanced CLI use may explicitly supply `--max-candidates COUNT` to request a limited scan. It writes one small index plus numbered text plan files in the index's directory. Each index entry contains the exact chunk-file SHA-256 and the canonical plan digest. No new tool, scheduled worker, dependency, or image copy is involved.

```text
plan-all --owner-id <UUID> --expected-timezone Asia/Tokyo --page-size 25 --out index.json
```

Pass the same runtime/env context through the launcher. Review the index and the exact chunk proposals. `review --plan index.json` prints the single index approval digest; it also reports whether the candidate scope was exhausted. `exhausted: false` is an incomplete scan, not a claim that the whole candidate scope was inspected.

After later explicit approval of that exact index and its listed changes, one command runs the approved chunks sequentially:

```text
apply-all --owner-id <UUID> --expected-timezone Asia/Tokyo --index index.json --approved-index-sha256 <reviewed index digest> --journal-dir <private existing directory> --acknowledge-history-ambiguity
```

It verifies every listed chunk before the first mutation, rejects duplicate asset IDs, re-verifies each file at use time, and delegates to the same guarded per-ID apply. Each chunk gets its own exclusive `*.apply.jsonl` recovery journal. The batch stops on any changed state, failure, or uncertain commit; it does not retry or silently continue. Earlier chunks/IDs may already have committed. Use the named original chunk plan and its journal for read-only reconciliation or separately approved undo. Index approval avoids one approval/hash command per chunk; it never turns planning into automatic apply.

## Concurrency and recovery

For each exact ID, apply reads source stat → installed ExifTool metadata → source stat outside the write transaction. It compares the reviewed source evidence and recomputed output. A short serializable transaction locks both rows, rereads their relevant snapshots and both revision IDs, rechecks sidecar absence/stat, and performs owner-scoped compare-and-swap updates of only the two fields. A zero-row or unexpected change rolls back both updates. No long ExifTool read occurs while row locks are held. No automatic transaction/commit retry is performed.

After both uncommitted updates return their actual new revisions, the tool appends and fsyncs a minimal `prepared` journal record before permitting COMMIT. If that write/fsync fails, the database transaction rolls back. A separate `committed` marker follows successful commit. Earlier IDs can already be committed if a later ID fails; the batch is intentionally per-asset, not one giant transaction.

If the process dies or the commit acknowledgement is uncertain, do not run apply again blindly. `reconcile` is read-only and compares the exact old/new fields and both revision IDs from the prepared records against the selected owner's current rows. Results are `applied-unchanged`, `not-applied-unchanged`, or `changed-or-ambiguous`. An incomplete final journal line is ignored and reported as a truncated tail; no ambiguous state is automatically retried, applied, or undone. Keep the original plan and journal.

A separately approved `undo` requires the exact original plan digest and reviewed parsed journal digest, plus a new exclusive journal. It restores only `localDateTime` and `timeZone` if the current after-values, both recorded resulting revisions, other relevant snapshot values, source stat and sidecar checks still match. It refuses newer manual changes and uses its own write-ahead journal. It does not roll back unrelated database state or recreate old revision IDs. A partial/truncated source journal must be reviewed rather than passed straight to undo. Reconciliation is not undo permission.

There is no atomic transaction spanning the filesystem and PostgreSQL. Immediate checks materially narrow the race window but cannot rule out a file mutation after the final stat, an undetectable restored-stat rewrite, or faulty filesystem/disk durability. Sidecar/DB workflows running concurrently can still change state after this transaction. The tool stops when it can observe inconsistency rather than claiming certainty it cannot establish.

## Tests

Synthetic tests run without installed-runtime, database, network or media access:

```text
node --test tests/Metadata-DateRepair-Core.test.cjs tests/Metadata-DateRepair-Gates.test.cjs
```

Coverage includes two-chunk/1,002-asset orchestration and exact-index failure gates, bounded read-only planning, strict source gates, timezone-less capture preservation, two-field apply/undo, revision races, CAS rollback, fsync rollback, uncertain commits, reconciliation, stale undo, and misleading-option rejection.

The existing Windows/PostgreSQL CI job additionally tests actual installed-module imports, ExifTool metadata reads, database triggers, compare-and-swap transactions and rollback. It is restricted to the already migrated `immich_ci_allusers` test database, explicit CI flags and generated synthetic fixtures. It never uses production libraries or databases. This integration gate must pass before the packaged runtime is considered validated.
