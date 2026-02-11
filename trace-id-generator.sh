#!/bin/bash
#
# Generates B3 tracing identifiers for job-level correlation.
# Format (16 chars): project_id{4}run_id{4}step_id{5}random{3}
#
# Exports:
#   X_B3_TRACE_ID
#   X_B3_SPAN_ID
#   X_B3_SAMPLED
#

_b3__upper() {
  # Uppercase stdin
  tr '[:lower:]' '[:upper:]'
}

_b3__hash4() {
  # Produce 4 hex-ish chars from input string (stdin).
  local out=""
  if command -v md5sum >/dev/null 2>&1; then
    out="$(md5sum | cut -c1-4)"
  elif command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum | cut -c1-4)"
  else
    # Last-resort fallback
    out="$(date +%s%N | cut -c1-4)"
  fi
  echo -n "$out" | _b3__upper
}

_b3__rand_alnum_upper() {
  local n="${1:-3}"
  if [ -r /dev/urandom ]; then
    LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c "$n"
  else
    # Fallback: not cryptographically strong
    echo -n "${RANDOM}${RANDOM}${RANDOM}" | _b3__upper | tr -dc 'A-Z0-9' | head -c "$n"
  fi
}

_b3__rand_hex_lower() {
  local n="${1:-16}"
  if [ -r /dev/urandom ]; then
    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c "$n"
  else
    # Fallback: not cryptographically strong
    echo -n "${RANDOM}${RANDOM}${RANDOM}" | tr -dc '0-9' | head -c "$n"
  fi
}

_b3__next_step_id() {
  # 5 digits sequential, persisted per container run.
  local step_file="${B3_STEP_ID_FILE:-/tmp/b3-step-id}"
  local current="0"
  if [ -f "$step_file" ]; then
    current="$(cat "$step_file" 2>/dev/null || true)"
  fi
  current="${current//[^0-9]/}"
  if [ -z "$current" ]; then current="0"; fi
  local next=$((10#$current + 1))
  local formatted
  formatted="$(printf "%05d" "$next")"
  printf "%s" "$formatted" > "$step_file" 2>/dev/null || true
  echo -n "$formatted"
}

_b3__generate() {
  local project="${PROJECT_TRACE_ID:-UNKW}"
  project="$(echo -n "$project" | _b3__upper | cut -c1-4)"
  if [ "${#project}" -lt 4 ]; then
    project="$(printf "%-4s" "$project" | tr ' ' 'W')" # pad to 4 chars
  fi

  local timestamp="${CURRENT_DATE:-}""${CURRENT_TIME:-}"
  if [ -z "$timestamp" ]; then
    timestamp="$(date +%F)$(date +%H-%M-%S)"
  fi
  local run_id
  run_id="$(echo -n "$timestamp" | _b3__hash4)"

  local step_id
  step_id="$(_b3__next_step_id)"

  local rand3
  rand3="$(_b3__rand_alnum_upper 3)"

  local trace_id="${project}${run_id}${step_id}${rand3}"
  local span_id
  span_id="$(_b3__rand_hex_lower 16)"

  export X_B3_TRACE_ID="$trace_id"
  export X_B3_SPAN_ID="$span_id"
  export X_B3_SAMPLED="${X_B3_SAMPLED:-1}"
}

_b3__generate

