# Upstream and reference projects

This project reuses upstream behavior and prior native-port work instead of re-implementing Immich.

## Primary upstream

- `immich-app/immich`: application source, schema migrations, web UI, ML service, plugin source and release tags.
- `immich-app/base-images`: authoritative reference for codecs and native libraries bundled by the official Linux image.

## Native installation references

- `arter97/immich-native`: current native Linux installation. This is the primary reference for the Server/Web/plugin production build, `pnpm deploy`, ML `uv sync`, geodata layout and runtime directory layout.
- `daemonless/immich-server`: FreeBSD port. This is the primary reference for treating Sharp/libvips and FFmpeg as replaceable OS-specific build artifacts while retaining upstream Immich application code.
- `4v3ngR/immich-native-macos`: macOS native port. Used to identify assumptions that are Linux packaging details rather than application requirements.

## Windows native dependency references

- `pgvector/pgvector`: upstream Windows/MSVC build path.
- `grimmjoww/vchord-windows-port`: verified native MSVC VectorChord build without Docker/WSL.
- `valkey-windows/valkey-windows`: Windows build of Valkey 9.x.
- `jellyfin/jellyfin-ffmpeg`: Windows FFmpeg build definitions used as the codec baseline.
- `winsw/winsw`: Windows service wrapper.

## Rule for copying prior work

Do not vendor source from these projects unless its license and attribution are reviewed. Prefer invoking upstream repositories, adapting documented build procedures in our own scripts, and recording source revisions in the package manifest.
