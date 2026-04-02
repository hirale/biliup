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

command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is required but was not found in PATH"

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

for path in "${sorted_paths[@]}"; do
  printf "file '%s'\n" "$(escape_for_concat "$path")" >>"$concat_list"
done

log "Converting ${#sorted_paths[@]} ordered FLV file(s) to MP3: $output_file"
if ! ffmpeg -hide_banner -loglevel error -y \
  -f concat -safe 0 -i "$concat_list" \
  -vn -map 0:a:0 -c:a libmp3lame -q:a 2 \
  "$output_part"; then
  fail "failed to convert ordered FLV segments to MP3"
fi

mv "$output_part" "$output_file"
log "MP3 saved to: $output_file"
