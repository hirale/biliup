# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the `hirale/biliup` fork (`origin`) of `biliup/biliup` (`upstream`). Upstream is merged in periodically. Fork-specific work so far: the Docker image (`ghcr.io/hirale/biliup`), the FLV-to-MP3 postprocessor (`scripts/flv_to_mp3.sh`), and the `use_live_cover` fallback for templates without a cover (`with_live_cover_fallback` in `server/common/upload.rs`). Most code comments and upstream commit messages are in Chinese.

## Commands

Frontend (Next.js, static export to `out/`):
- `npm i` then `npm run dev` (http://localhost:3000; talks to the API at `NEXT_PUBLIC_API_SERVER` from `.env.development`, default `http://localhost:19159`)
- `npm run build`: produces `out/`, which the Rust server embeds at compile time. **Run this before any `cargo build`, `cargo test` or `maturin` build**, or the `rust-embed` folder is missing or stale.
- `npm run lint`

Rust:
- `cargo build --release --bin biliup`: standalone CLI/server
- `cargo test --workspace` (upstream CI runs `cargo test --locked --workspace`); single crate: `cargo test -p biliup-cli <test_name>`

Python wheel (maturin; `pyproject.toml` lives in `crates/stream-gears/`):
- `maturin develop -m crates/stream-gears/Cargo.toml`, then `python3 -m biliup` (equivalent to `biliup server`)
- `maturin build --release -m crates/stream-gears/Cargo.toml`: wheel into `target/wheels/`
- `pytest crates/stream-gears/tests`: offline smoke tests (`test_smoke.py` and others) that run against an **installed** wheel, not the source tree. `crates/stream-gears/examples/*.py` are manual scripts that need real credentials.

Docker: `docker build .` runs the multi-stage build (webui, maturin wheel, python:3.13-slim with a pinned, sha256-verified BtbN FFmpeg). Entrypoint `biliup`, default `CMD server --bind 0.0.0.0 --auth`, workdir `/opt`, and `scripts/` is copied to `/opt/scripts`. The only CI is `.github/workflows/docker-publish.yml`, which builds and pushes images on pushes to `master` and `v*` tags. The fork deletes upstream's other workflows (test, release, desktop, docs, Termux).

## Architecture

**Rust owns everything; the Python package is a thin launcher.**

1. **`crates/stream-gears/biliup/`** is the minimal Python package: `__main__.py` calls `stream_gears.main_loop`, which parses `sys.argv` and runs the Rust server with the GIL released. `biliup/plugins/bili_webup*.py` are kept only as an importable upload library. There is no Python plugin host.
2. **`crates/stream-gears`** is the pyo3 bridge (mixed layout: the native module is `stream_gears.stream_gears`, and `stream_gears/__init__.py` re-exports it). It exposes `upload`, `download`, the login functions, config bindings and `main_loop`. Keep `stream_gears/stream_gears.pyi` in sync when you change a `#[pyfunction]` signature. The smoke tests check the exports.
3. **`crates/biliup-cli`** is the application: clap CLI, axum web server and REST/WS API (`server/api/`), multi-user web auth (roles admin/operator/viewer), the SQLite store (sqlx/ormlite; migrations in `crates/biliup-cli/migrations`, run automatically on startup), the monitor/download manager (`server/core/`), upload orchestration including record-while-upload (`server/common/upload.rs`, `server/common/sync.rs`), and hooks (`server/infrastructure/models/hook_step.rs`).
4. **`crates/biliup`** is the core library: the Bilibili uploader (lines, credentials) and the per-platform live extractors in `src/downloader/live/*.rs` (bilibili, douyu, huya, douyin, twitch, youtube, ...).
5. **`crates/danmaku`** holds the danmaku clients and XML output.

Downloaders live in `server/core/downloader/`: mesio (the default when none is configured; writes `.flv` for FLV sources, `.ts`/`.m4s` for HLS), stream-gears, ffmpeg, streamlink, yt-dlp, and sync-downloader.

`tauri-app/` is the desktop app and is not part of the wheel build. `docs/` is a Zola site with a git submodule theme.

## Hooks and the FLV-to-MP3 postprocessor

A per-streamer `postprocessor` (and other hook points) is a list of `HookStep`: `{run: "cmd"}`, `{mv: "dir"}`, `{remux: "fmt"}` or `"rm"`. A `run` step receives the file paths **newline-separated on stdin**, with no trailing newline. `scripts/flv_to_mp3.sh` follows this contract. It keeps only `.flv` inputs, concatenates them into a single dated MP3 in one ffmpeg concat-filter pass, and tolerates a missing `ffprobe`. The Docker image deletes `ffprobe` on amd64/arm64, so that path is the normal case in the container.
