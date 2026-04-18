#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[flv_to_mp3] %s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

resolve_path() {
  local input="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath "$input"
    return
  fi

  if command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
    readlink -f "$input"
    return
  fi

  local dir base
  dir=$(cd "$(dirname "$input")" && pwd -P) || return 1
  base=$(basename "$input")
  printf '%s/%s\n' "$dir" "$base"
}

# Emits "duration|start_time" from ffprobe key=value stdin (empty field if absent).
parse_probe_kv() {
  awk -F= '
    /^duration=/   && $2 != "N/A" { d=$2 }
    /^start_time=/ && $2 != "N/A" { s=$2 }
    END { printf "%s|%s\n", d, s }
  '
}

# Returns audio content duration in seconds, net of any stream start offset.
# Live-stream FLV chunks often carry continuous PTS across segments, so a raw
# Duration: reading overstates per-file content by that offset.
probe_duration() {
  local file="$1"
  local dur="" start="" kv line hms hours minutes seconds

  if [[ "$has_ffprobe" -eq 1 ]]; then
    kv=$(ffprobe -v quiet -select_streams a:0 \
      -show_entries stream=duration,start_time \
      -of default=nw=1 "$file" 2>/dev/null | parse_probe_kv)
    IFS='|' read -r dur start <<<"$kv"

    if [[ -z "$dur" ]]; then
      kv=$(ffprobe -v quiet \
        -show_entries format=duration,start_time \
        -of default=nw=1 "$file" 2>/dev/null | parse_probe_kv)
      IFS='|' read -r dur start <<<"$kv"
    fi
  fi

  if [[ -z "$dur" ]]; then
    line=$(ffmpeg -hide_banner -fflags +discardcorrupt -err_detect ignore_err -i "$file" 2>&1 || true)
    hms=$(printf '%s\n' "$line" | awk -F 'Duration: |, start:|, bitrate:' '/Duration: / {print $2; exit}')
    start=$(printf '%s\n' "$line" | sed -n 's/.*, start: \([0-9.-]*\).*/\1/p' | head -1)

    if [[ -n "$hms" && "$hms" != "N/A" ]]; then
      IFS=: read -r hours minutes seconds <<<"$hms"
      dur=$(awk "BEGIN{printf \"%.3f\", ($hours * 3600) + ($minutes * 60) + $seconds}")
    fi
  fi

  [[ -z "$dur" ]] && dur=0
  [[ -z "$start" ]] && start=0

  # r<0 means start_time exceeded duration (corrupt metadata); use raw duration.
  awk "BEGIN{d=$dur+0; s=$start+0; r=d - s; if (r < 0) r = d; printf \"%.3f\", r}"
}

duration_ok() {
  local actual="$1"
  local minimum="$2"
  awk "BEGIN{exit ($actual >= $minimum) ? 0 : 1}"
}

command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is required but was not found in PATH"

has_ffprobe=0
if command -v ffprobe >/dev/null 2>&1; then
  has_ffprobe=1
else
  log "ffprobe not found; falling back to ffmpeg duration probing"
fi

target_dir=${1:-audio}
mkdir -p "$target_dir"
target_dir=$(resolve_path "$target_dir") || fail "failed to resolve output directory: $target_dir"

declare -a flv_paths=()

while IFS= read -r raw_path || [[ -n "$raw_path" ]]; do
  if [[ -z "${raw_path//[[:space:]]/}" ]]; then
    continue
  fi

  if [[ ! -e "$raw_path" ]]; then
    log "Skipping missing file: $raw_path"
    continue
  fi

  case "${raw_path,,}" in
    *.flv) ;;
    *)
      log "Skipping non-FLV input: $raw_path"
      continue
      ;;
  esac

  resolved_path=$(resolve_path "$raw_path") || {
    log "Skipping unreadable path: $raw_path"
    continue
  }

  flv_paths+=("$resolved_path")
done

if [[ ${#flv_paths[@]} -eq 0 ]]; then
  fail "no FLV inputs were provided on stdin"
fi

mapfile -t sorted_paths < <(printf '%s\n' "${flv_paths[@]}" | LC_ALL=C sort)

if [[ ${#sorted_paths[@]} -eq 0 ]]; then
  fail "no FLV inputs remained after sorting"
fi

first_name=$(basename "${sorted_paths[0]}")
output_date=$(date '+%Y-%m-%d')
output_stem="${first_name%.*}_${output_date}_full"
output_file="$target_dir/${output_stem}.mp3"

if [[ -e "$output_file" ]]; then
  timestamp=$(date '+%Y%m%dT%H%M%S')
  output_file="$target_dir/${output_stem}_${timestamp}.mp3"
fi

output_part="${output_file}.part.mp3"

cleanup() {
  rm -f "$output_part"
}

trap cleanup EXIT

total_input_seconds=0
for path in "${sorted_paths[@]}"; do
  dur=$(probe_duration "$path")
  total_input_seconds=$(awk "BEGIN{printf \"%.3f\", $total_input_seconds + $dur}")
done

log "Total input duration: ${total_input_seconds}s across ${#sorted_paths[@]} file(s)"
log "Converting ${#sorted_paths[@]} ordered FLV file(s) to MP3: $output_file"

# Concat filter: each input gets its own decoder instance, so mid-session
# codec-parameter changes don't poison the output the way a concat demuxer
# would. Filenames are passed as separate -i args, never composed into a
# text list file.
input_args=()
filter=""
for idx in "${!sorted_paths[@]}"; do
  input_args+=(-i "${sorted_paths[$idx]}")
  filter+="[${idx}:a:0]"
done
filter+="concat=n=${#sorted_paths[@]}:v=0:a=1[out]"

ffmpeg -hide_banner -loglevel error -y \
  -err_detect ignore_err -fflags +discardcorrupt \
  "${input_args[@]}" \
  -filter_complex "$filter" \
  -map '[out]' \
  -c:a libmp3lame -q:a 2 \
  "$output_part" || fail "ffmpeg concat-filter conversion failed"

output_seconds=$(probe_duration "$output_part")

if awk "BEGIN{exit !($total_input_seconds > 0)}"; then
  min_required=$(awk "BEGIN{printf \"%.3f\", $total_input_seconds * 0.6}")
  log "Output duration: ${output_seconds}s  (minimum required: ${min_required}s)"
  if ! duration_ok "$output_seconds" "$min_required"; then
    fail "output MP3 appears truncated; less than 60% of input audio was encoded"
  fi
else
  log "Output duration: ${output_seconds}s  (skipping threshold check; no input duration could be probed)"
fi

mv "$output_part" "$output_file"
log "MP3 saved to: $output_file"
