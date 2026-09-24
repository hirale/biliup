# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the `hirale/biliup` fork (`origin`) of `biliup/biliup` (`upstream`). Upstream is merged in periodically; fork-specific work so far is the Docker image (`ghcr.io/hirale/biliup`) and the FLV-to-MP3 postprocessor (`scripts/flv_to_mp3.sh`). Most code comments and upstream commit messages are in Chinese.

## Commands

Frontend (Next.js, static export to `out/`):
- `npm i` then `npm run dev` (http://localhost:3000; talks to the API at `NEXT_PUBLIC_API_SERVER` from `.env.development`, default `http://localhost:19159`)
- `npm run build`: produces `out/`, which the Rust server embeds at compile time. **Run this before any `cargo build` or `maturin` build**, or the `rust-embed` folder is missing or stale.
- `npm run lint`

Python package (Rust extension built with maturin, see `pyproject.toml`):
- `maturin dev`: builds `crates/stream-gears` into the active venv as `stream_gears`
- `python3 -m biliup` (equivalent to `biliup server`), or `python3 -m biliup server --auth`
- `maturin build --release`: wheel into `target/wheels/`

Rust:
- `cargo build --release --bin biliup`: standalone CLI/server without the Python engine
- `cargo test -p biliup` / `cargo test -p biliup-cli`; single test: `cargo test -p biliup-cli <test_name>`
- `crates/stream-gears/tests/*.py` are manual scripts that need real `cookies.json` credentials and network access, not an automated suite.

Docker: `docker build .` runs the multi-stage build (webui → maturin wheel → python:3.13-slim with a static ffmpeg). The image entrypoint is `biliup`, workdir `/opt`, and `scripts/` is copied to `/opt/scripts`. CI (`.github/workflows/docker-publish.yml`) only builds and pushes images on pushes to `master` and `v*` tags. There is no test or lint CI.

## Architecture

The system has three layers packaged as one Python wheel. **Rust owns the process; Python is a plugin host.**

1. **`biliup/__main__.py`** does almost nothing. It sets up logging and calls `stream_gears.main_loop`, which reads `sys.argv` and runs the Rust server (`crates/stream-gears/src/server.rs::_main`) with the GIL released.
2. **`crates/biliup-cli`** is the real application: clap CLI (`cli.rs`), axum web server and REST/WS API (`server/api/`), auth via axum-login, the SQLite store (sqlx; migrations in `crates/biliup-cli/migrations`, run automatically on startup; offline query metadata in `.sqlx/`), the monitor/download manager (`server/core/`), upload orchestration, and hooks (`server/common/upload.rs`, `server/infrastructure/models/hook_step.rs`). It also builds as the standalone `biliup` binary.
3. **`crates/stream-gears`** is the pyo3 bridge (`abi3-py38`). It exposes `upload`, `download`, the login functions, and `main_loop` to Python. It also calls back into Python. `server.rs::from_py` imports `biliup.plugins` and wraps each class registered through `@Plugin.download(regexp)` (`biliup/engine/decorators.py`) as a `PyPlugin`. Rust then invokes the plugin's `acheck_stream()` on the Python asyncio loop from `biliup.common.util`, and calls `update_headers` and `danmaku_init`. Danmaku clients (`biliup/Danmaku/`) are driven from Rust via `start`/`stop`/`save` (`danmaku.rs`). The type stubs live in `crates/stream-gears/stream_gears/stream_gears.pyi`, so keep them in sync when you change a `#[pyfunction]` signature.
4. **`crates/biliup`** is the core library: the Bilibili uploader (upload lines upos/kodo/cos, credentials) and native downloaders (httpflv, hls, FLV parsing and writing, and Rust extractors for bilibili/douyu/huya).

Streaming platforms are supported by Python plugins in `biliup/plugins/` (subclass `DownloadBase` from `biliup/engine/download.py` and decorate with `@Plugin.download(...)`). A few platforms have Rust-native plugins in `crates/biliup-cli/src/server/core/plugin/` (twitch, yy). The actual stream fetching is done by pluggable downloaders in `server/core/downloader/`: stream-gears (native), ffmpeg, streamlink, yt-dlp.

`tauri-app/` is a separate desktop app and is not part of the wheel build. `docs/` is a Zola site with a git submodule theme.

## Hooks and the FLV-to-MP3 postprocessor

A per-streamer `postprocessor` (and other hook points) is a list of `HookStep`: `{run: "cmd"}`, `{mv: "dir"}`, or `"rm"`. A `run` step receives the uploaded file paths **newline-separated on stdin**. `scripts/flv_to_mp3.sh` follows this contract. It concatenates the FLV segments into a single dated MP3 in one ffmpeg concat-filter pass and tolerates a missing `ffprobe`. The Docker image deletes `ffprobe` on amd64/arm64, so that path is the normal case in the container.
