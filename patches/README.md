# Patch policy

This repository is a patch/distribution layer, not an Immich source fork. Upstream Immich source and commit history are never vendored, merged, rebased, or added as a submodule.

`patches/series` is the authoritative ordered stack applied to the exact Immich tag and commit pinned by `upstream.json`.

Rules:

- keep one concern per patch;
- do not change upstream SQL migrations or data models;
- prefer cross-platform changes that preserve Linux behavior;
- every patch must be a valid unified diff and pass `git apply --check --whitespace=error-all` against the pinned pristine checkout;
- an upstream update that breaks a patch is a hard stop until that patch is reviewed;
- remove a patch when equivalent behavior lands upstream;
- never commit the disposable patched checkout under `.work/immich`.

## Current v3.2.2 patch stack

1. `server/0001-use-platform-null-device.patch` — use Node's platform null device for FFmpeg two-pass output.
2. `server/0002-configurable-postgres-bin.patch` — make PostgreSQL client executables and psql null output cross-platform.
3. `server/0003-cross-platform-absolute-paths.patch` — accept native Windows drive/UNC absolute paths.
4. `server/0004-use-node-gzip-on-windows.patch` — remove the GNU `gzip` runtime dependency on Windows.
5. `server/0005-cross-platform-media-location-migration.patch` — make DB file-path prefix rewriting safe for Windows separators.
6. `server/0006-cross-platform-storage-boundary.patch` — use platform path semantics for Immich media-root containment.
7. `server/0007-cross-platform-folder-paths.patch` — make folder browsing work with native Windows asset paths.
8. `server/0008-cross-platform-glob-paths.patch` — convert native Windows library roots to fast-glob patterns before crawling.
9. `machine-learning/0001-native-windows-uvicorn.patch` — avoid Gunicorn on Windows and launch the same FastAPI app with Uvicorn.

## Update procedure

For a new Immich stable release:

1. update `upstream.json` to the new immutable tag/commit and update dependency pins required by that upstream release;
2. run `build/Prepare-Source.ps1`; it reuses the single generated checkout, checks upstream tool versions, and fetches the new tag;
3. remove patches already covered upstream and refresh only hunks that no longer apply;
4. rerun `build/Prepare-Source.ps1`, then the Windows build and migration qualification gates;
5. commit the release pins and any patch changes in separate logical commits.

The patched source tree is build input only. The history of this repository must remain independent from `immich-app/immich`.
