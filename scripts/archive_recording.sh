#!/usr/bin/env bash
# Usage (postprocessor): run: bash archive_recording.sh <archive_dir> <rclone_remote>...
# Segment paths arrive on stdin. With empty stdin it only retries sessions whose
# upload failed earlier. Keep this as the last postprocessor step: the source
# segments and the MP4 are deleted once every remote holds a verified copy.
# A literal {rand} in a remote is replaced by a random token fixed per session,
# so a public download URL reveals nothing about other sessions' paths.

set -euo pipefail

log() {
  printf '[archive] %s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Net media duration in seconds (duration minus start offset), ffprobe optional.
media_duration() {
  local file="$1" dur="" start="" out hms h m s

  if command -v ffprobe >/dev/null 2>&1; then
    out=$(ffprobe -v error -show_entries format=duration,start_time -of default=nw=1 "$file" 2>/dev/null || true)
    dur=$(printf '%s\n' "$out" | sed -n 's/^duration=\([0-9.]*\)$/\1/p')
    start=$(printf '%s\n' "$out" | sed -n 's/^start_time=\([0-9.-]*\)$/\1/p')
  fi

  if [[ -z "$dur" ]]; then
    out=$(ffmpeg -hide_banner -i "$file" 2>&1 || true)
    hms=$(printf '%s\n' "$out" | sed -n 's/.*Duration: \([0-9:.]*\),.*/\1/p' | head -1)
    start=$(printf '%s\n' "$out" | sed -n 's/.*, start: \([0-9.-]*\).*/\1/p' | head -1)
    if [[ -n "$hms" ]]; then
      IFS=: read -r h m s <<<"$hms"
      dur=$(awk "BEGIN{printf \"%.3f\", $h*3600 + $m*60 + $s}")
    fi
  fi

  awk -v d="${dur:-0}" -v s="${start:-0}" 'BEGIN{r=d-s; if (r < 0) r=d; printf "%.3f", r}'
}

# Stream copy cannot drop content silently except by truncation, so a short
# output is the one failure worth checking for.
duration_matches() {
  local expected="$1" actual="$2"
  awk -v e="$expected" -v a="$actual" 'BEGIN{exit (e <= 0 || a >= e * 0.97) ? 0 : 1}'
}

# Codec, resolution and audio layout per stream; bitrates are left out because
# they differ between segments of the same stream.
stream_signature() {
  ffmpeg -hide_banner -i "$1" 2>&1 \
    | grep -oE '(Video|Audio): [a-z0-9_]+|[0-9]{2,5}x[0-9]{2,5}|[0-9]+ Hz, [a-z0-9.()]+' \
    | tr '\n' ' ' || true
}

remux_session() {
  local stem="$1"
  shift
  local -a segments=("$@")
  local list="$tmp_dir/concat.txt" part="$archive_dir/$stem.mp4.part"
  local expected=0 actual seg idx out first_sig same_params=1

  : >"$list"
  first_sig=$(stream_signature "${segments[0]}")
  for seg in "${segments[@]}"; do
    expected=$(awk -v a="$expected" -v b="$(media_duration "$seg")" 'BEGIN{printf "%.3f", a + b}')
    printf "file '%s'\n" "${seg//\'/\'\\\'\'}" >>"$list"
    [[ "$(stream_signature "$seg")" == "$first_sig" ]] || same_params=0
  done
  log "Remuxing ${#segments[@]} segment(s), ${expected}s total, into $stem.mp4"

  # -f mp4 because the .part suffix hides the container from ffmpeg.
  if ((same_params)) && ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$list" \
      -map "0:v?" -map "0:a?" -c copy -f mp4 "$part"; then
    actual=$(media_duration "$part")
    if duration_matches "$expected" "$actual"; then
      mv "$part" "$archive_dir/$stem.mp4"
      session_outputs=("$stem.mp4")
      return 0
    fi
    log "Concatenated output is ${actual}s, expected ${expected}s"
  fi
  rm -f "$part"

  # A single MP4 can't carry a mid-session change of codec parameters, so keep
  # the session lossless by remuxing each segment on its own instead.
  ((same_params)) || log "Stream parameters differ between segments"
  log "Falling back to one MP4 per segment"
  session_outputs=()
  idx=0
  for seg in "${segments[@]}"; do
    idx=$((idx + 1))
    out=$(printf '%s.part%02d.mp4' "$stem" "$idx")
    ffmpeg -hide_banner -loglevel error -y -i "$seg" \
      -map "0:v?" -map "0:a?" -c copy -f mp4 "$archive_dir/$out.part" \
      || fail "ffmpeg remux failed for $seg"
    actual=$(media_duration "$archive_dir/$out.part")
    duration_matches "$(media_duration "$seg")" "$actual" \
      || fail "remuxed $out is truncated (${actual}s)"
    mv "$archive_dir/$out.part" "$archive_dir/$out"
    session_outputs+=("$out")
  done
}

# Uploads one session to every remote and deletes the local files only when
# every copy verifies by hash; a size-only match does not count.
archive_session() {
  local session_file="$1" stem check_log template remote rel token=""
  local -a outputs=() sources=()
  stem=$(basename "$session_file" .session)

  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      out) outputs+=("$value") ;;
      src) sources+=("$value") ;;
      rand) token=$value ;;
    esac
  done <"$session_file"

  for rel in "${outputs[@]}"; do
    [[ -f "$archive_dir/$rel" ]] || { log "$stem: missing $rel"; return 1; }
  done
  printf '%s\n' "${outputs[@]}" >"$tmp_dir/files.txt"

  # Logs name the template, not the resolved path, to keep tokens out of them.
  for template in "${remotes[@]}"; do
    if [[ "$template" == *'{rand}'* ]]; then
      [[ -n "$token" ]] || { log "$stem: session has no rand token"; return 1; }
      remote=${template//'{rand}'/$token}
    else
      remote=$template
    fi
    log "$stem: uploading to $template"
    rclone copy "$archive_dir" "$remote" --files-from-raw "$tmp_dir/files.txt" \
      --s3-no-check-bucket --stats 5m --stats-one-line --stats-log-level NOTICE \
      || { log "$stem: upload to $template failed"; return 1; }

    check_log="$tmp_dir/check.log"
    if ! rclone check "$archive_dir" "$remote" --one-way \
        --files-from-raw "$tmp_dir/files.txt" >"$check_log" 2>&1; then
      cat "$check_log" >&2
      log "$stem: verification against $template failed"
      return 1
    fi
    if grep -Eq '[1-9][0-9]* hash(es)? could not be checked' "$check_log"; then
      cat "$check_log" >&2
      log "$stem: $template has no comparable hash; refusing to trust a size-only match"
      return 1
    fi
    log "$stem: verified on $template"
  done

  # Session file first: an interruption after this leaves stray files, never a
  # session that points at already-deleted outputs.
  rm -f -- "$session_file"
  for rel in "${outputs[@]}"; do
    rm -f -- "$archive_dir/$rel"
  done
  for rel in "${sources[@]}"; do
    rm -f -- "$rel"
  done
  log "$stem: archived; removed local MP4 and ${#sources[@]} source segment(s)"
}

command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is required"
command -v rclone >/dev/null 2>&1 || fail "rclone is required"
command -v flock >/dev/null 2>&1 || fail "flock is required"

(($# >= 2)) || fail "usage: archive_recording.sh <archive_dir> <rclone_remote>..."
archive_dir=$1
shift
remotes=("$@")

mkdir -p "$archive_dir"
archive_dir=$(cd "$archive_dir" && pwd -P)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

declare -a segments=()
while IFS= read -r raw || [[ -n "$raw" ]]; do
  [[ -n "${raw//[[:space:]]/}" ]] || continue
  case "${raw,,}" in
    *.flv | *.ts) ;;
    *) log "Skipping non-video input: $raw"; continue ;;
  esac
  [[ -f "$raw" ]] || { log "Skipping missing file: $raw"; continue; }
  segments+=("$(cd "$(dirname "$raw")" && pwd -P)/$(basename "$raw")")
done

current_stem=""
if ((${#segments[@]} > 0)); then
  mapfile -t segments < <(printf '%s\n' "${segments[@]}" | LC_ALL=C sort)
  current_stem=$(basename "${segments[0]}")
  current_stem=${current_stem%.*}

  if [[ -f "$archive_dir/$current_stem.session" ]]; then
    log "$current_stem was already remuxed; retrying its upload"
  else
    declare -a session_outputs=()
    remux_session "$current_stem" "${segments[@]}"
    {
      printf 'rand\t%s\n' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
      printf 'src\t%s\n' "${segments[@]}"
      printf 'out\t%s\n' "${session_outputs[@]}"
    } >"$archive_dir/$current_stem.session.tmp"
    mv "$archive_dir/$current_stem.session.tmp" "$archive_dir/$current_stem.session"
  fi
fi

# One uploader at a time: overlapping sessions would otherwise race on the
# retry sweep.
exec 9>"$archive_dir/.archive.lock"
flock 9

status=0
while IFS= read -r session_file; do
  stem=$(basename "$session_file" .session)
  if ! archive_session "$session_file"; then
    [[ "$stem" == "$current_stem" ]] && status=1
    log "$stem: left for the next run"
  fi
done < <(find "$archive_dir" -maxdepth 1 -name '*.session' | LC_ALL=C sort)

exit "$status"
