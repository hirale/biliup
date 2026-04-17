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

escape_for_concat() {
  local input="$1"
  printf "%s" "${input//\'/\'\\\'\'}"
}

# Returns the audio duration in seconds for a file, or 0 on failure.
probe_duration() {
  local file="$1"
  local dur raw hours minutes seconds

  if [[ "$has_ffprobe" -eq 1 ]]; then
    dur=$(ffprobe -v quiet -select_streams a:0 \
      -show_entries stream=duration \
      -of csv=p=0 "$file" 2>/dev/null | head -1 || true)
    if [[ -z "$dur" || "$dur" == "N/A" ]]; then
      dur=$(ffprobe -v quiet \
        -show_entries format=duration \
        -of csv=p=0 "$file" 2>/dev/null | head -1 || true)
    fi
  fi

  if [[ -z "$dur" || "$dur" == "N/A" ]]; then
    raw=$(ffmpeg -hide_banner -i "$file" 2>&1 || true)
    dur=$(printf '%s\n' "$raw" | awk -F 'Duration: |, start:' '/Duration: / {print $2; exit}' || true)

    if [[ -n "$dur" ]]; then
      IFS=: read -r hours minutes seconds <<<"$dur"
      dur=$(awk "BEGIN{printf \"%.3f\", ($hours * 3600) + ($minutes * 60) + $seconds}")
    fi
  fi

  printf '%s' "${dur:-0}"
}

duration_ok() {
  local actual="$1"
  local minimum="$2"
  awk "BEGIN{exit ($actual >= $minimum) ? 0 : 1}"
}

verify_duration() {
  local expected_seconds="$1"
  local file="$2"
  local label="$3"
  local output_seconds min_required

  if [[ $(awk "BEGIN{print ($expected_seconds > 0)}") -ne 1 ]]; then
    return 0
  fi

  output_seconds=$(probe_duration "$file")
  min_required=$(awk "BEGIN{printf \"%.3f\", $expected_seconds * 0.6}")
  log "$label duration: ${output_seconds}s  (minimum required: ${min_required}s)"

  duration_ok "$output_seconds" "$min_required"
}

convert_all_at_once() {
  ffmpeg -hide_banner -loglevel error -y \
    -c:a aac -strict -2 \
    -f concat -safe 0 -i "$concat_list" \
    -vn -map 0:a:0 -c:a libmp3lame -q:a 2 \
    "$output_part" || return 1

  verify_duration "$total_input_seconds" "$output_part" "Combined output"
}

convert_segment_by_segment() {
  local segment_dir="$temp_dir/segments"
  local segment_list="$temp_dir/segments.txt"
  local total_segments=${#sorted_paths[@]}
  local path index segment_output expected_seconds

  mkdir -p "$segment_dir"
  : >"$segment_list"

  for index in "${!sorted_paths[@]}"; do
    path="${sorted_paths[$index]}"
    segment_output=$(printf '%s/%05d.mp3' "$segment_dir" "$((index + 1))")
    expected_seconds=$(probe_duration "$path")

    log "Fallback converting segment $((index + 1))/${total_segments}: $(basename "$path")"
    ffmpeg -hide_banner -loglevel error -y \
      -c:a aac -strict -2 \
      -i "$path" \
      -vn -map 0:a:0 -c:a libmp3lame -q:a 2 \
      "$segment_output" || return 1

    verify_duration "$expected_seconds" "$segment_output" "Segment $((index + 1))" || return 1
    printf "file '%s'\n" "$(escape_for_concat "$segment_output")" >>"$segment_list"
  done

  ffmpeg -hide_banner -loglevel error -y \
    -f concat -safe 0 -i "$segment_list" \
    -vn -map 0:a:0 -c:a libmp3lame -q:a 2 \
    "$output_part" || return 1

  verify_duration "$total_input_seconds" "$output_part" "Fallback output"
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

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/biliup-flv-to-mp3-XXXXXX")
concat_list="$temp_dir/concat.txt"
output_part="${output_file}.part.mp3"

cleanup() {
  rm -f "$output_part"
  rm -rf "$temp_dir"
}

trap cleanup EXIT

# Sum input durations so we can detect silent truncation later.
total_input_seconds=0
for path in "${sorted_paths[@]}"; do
  printf "file '%s'\n" "$(escape_for_concat "$path")" >>"$concat_list"
  dur=$(probe_duration "$path")
  total_input_seconds=$(awk "BEGIN{printf \"%.3f\", $total_input_seconds + $dur}")
done

log "Total input duration: ${total_input_seconds}s across ${#sorted_paths[@]} file(s)"
log "Converting ${#sorted_paths[@]} ordered FLV file(s) to MP3: $output_file"

if ! convert_all_at_once; then
  log "Primary conversion failed or looked truncated; retrying segment-by-segment"
  rm -f "$output_part"
  if ! convert_segment_by_segment; then
    fail "failed to convert ordered FLV segments to MP3 without truncation"
  fi
fi

mv "$output_part" "$output_file"
log "MP3 saved to: $output_file"
