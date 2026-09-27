# Architecture

## Build machine

The build machine is a high-performance Windows x64 host. It owns all compilation and produces a portable release directory.

```text
immich-app/immich @ immutable tag
        |
        +-- apply patches/*
        |
        +-- build SDK / Server / Web / core plugin
        +-- create production Server deployment
        +-- create Python ML runtime
        +-- collect geodata
        +-- build/collect native dependencies
        |     +-- pgvector
        |     +-- VectorChord
        |     +-- Sharp/libvips codec stack
        |     +-- Jellyfin FFmpeg
        |     +-- Valkey
        |     +-- WinSW
        |
        +-- integration tests
        |
        `-- dist/immich-windows-vX.Y.Z-win-x64/
```

## Production machine

```text
C:\Program Files\Immich\
  releases\vX.Y.Z\        immutable application release
  current\                 selected release (directory link/junction)

C:\ProgramData\Immich\
  immich.env               persistent configuration
  logs\                    persistent logs
  cache\                   ML/model cache
  state\                   installer/update state

PostgreSQL 18 data          SSD
Valkey runtime              Windows process/service
Immich Server               Windows process/service
Immich ML                   Windows process/service
Media root                  existing NTFS HDD, e.g. D:\Immich
```

The release directory is disposable. Configuration, database data, media and caches are outside it.

## Compatibility boundary

The following remain upstream-owned and MUST NOT be independently forked:

- SQL schema and migrations
- API contracts
- entity models
- job names/queue semantics
- metadata format
- storage-template semantics
- web application
- mobile clients

Windows-specific code is permitted only for:

- OS null-device handling
- PostgreSQL executable discovery
- process launch/service integration
- filesystem path migration/validation
- native dependency compilation/package selection
- hardware acceleration selection

## Upgrade model

Every Windows package maps to one exact Immich upstream version. Update flow:

1. verify the candidate package and record the current release target;
2. create and verify a pre-upgrade PostgreSQL logical backup;
3. stop Windows services and stage the new immutable release;
4. switch the `current` junction to the candidate while services are stopped;
5. start the candidate and allow upstream Immich migrations to run;
6. run native Windows smoke checks plus `immich-admin schema-check`;
7. mark the candidate `qualified` in `C:\ProgramData\Immich\state\upgrade-recovery.json`;
8. retain the previous release and its paired pre-upgrade database backup.

The `current` junction must point at the candidate before it starts because all service commands are intentionally version-independent and resolve through that junction. A candidate is **not** considered promoted merely because the junction changed; qualification is the successful completion of migrations and the post-start smoke/schema gate.

On failure, Server and ML remain stopped and the recovery state records the previous release, candidate and database backup. `installer\Recover-Upgrade.ps1` restores the previous release's PostgreSQL extension binaries, restores the paired pre-upgrade database backup, switches `current` back, and reruns the smoke/schema gate. Binary-only rollback is prohibited.
