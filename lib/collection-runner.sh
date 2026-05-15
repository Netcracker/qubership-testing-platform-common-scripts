#!/usr/bin/env bash
# collection-runner.sh — per-collection execution helpers for Bruno.
#
# Exported functions (must be exported with `export -f` by the dispatcher
# before spawning subprocesses):
#   resolve_folders      — resolves folder names to relative paths inside a collection
#   run_bru              — runs bru.js with timeout; appends optional folder args
#   write_allure_placeholder — writes a synthetic skipped/broken Allure result JSON
#   wait_for_collection_slot — semaphore: blocks until one active PID slot is free
#   run_collection_body  — top-level per-collection entry point (called by dispatcher)

# ---------------------------------------------------------------------------
# resolve_folders ARRAY_NAME
#
# Populates the global RESOLVED_FOLDERS array by searching the current
# directory for each folder name in the named array argument.
#
# Args:
#   $1  Name of a bash array variable (passed by reference) holding folder names.
#
# Globals read:  (none beyond the named array)
# Globals set:   RESOLVED_FOLDERS
# ---------------------------------------------------------------------------
resolve_folders() {
  local -n _folders_ref="$1"
  RESOLVED_FOLDERS=()

  if [ "${#_folders_ref[@]}" -eq 0 ]; then
    return 0
  fi

  for folder in "${_folders_ref[@]}"; do
    local found_any=false

    while IFS= read -r found; do
      echo "Found folder: $found"
      RESOLVED_FOLDERS+=("$found")
      found_any=true
    done < <(find . -maxdepth 5 -type d -name "$folder" \
               -not -path "*/.git/*" -not -path "*/node_modules/*")

    if [ "$found_any" = false ]; then
      echo "Folder not found in collection: $folder"
    fi
  done
}

# ---------------------------------------------------------------------------
# run_bru REPORT_PATH LOG_PATH [FOLDER...]
#
# Runs bru.js with a timeout, streaming output to tee. Optional trailing
# arguments are passed directly to bru as folder targets.
#
# Args:
#   $1  Path for the --reporter-json output file
#   $2  Path for the raw tee log file
#   $@ (remaining)  Optional folder paths to restrict the run
#
# Globals read:  BRU_BIN, COLLECTION_TIMEOUT, BRUNO_FLAGS_CLI,
#                BRUNO_ENV_STR, BRUNO_ENV_VARS_CLI
# Returns:       exit code from bru.js (propagated through the pipe via PIPESTATUS)
# ---------------------------------------------------------------------------
run_bru() {
  local report_path="$1"
  local log_path="$2"
  shift 2

  # shellcheck disable=SC2086
  timeout --signal=TERM --kill-after=30s "${COLLECTION_TIMEOUT:-3600}s" \
    "${BRU_BIN}/bru.js" run \
    ${BRUNO_FLAGS_CLI} \
    --env "${BRUNO_ENV_STR:-envoriment-template.bru}" \
    ${BRUNO_ENV_VARS_CLI} \
    --reporter-json "${report_path}" \
    "$@" \
    2>&1 | tee "${log_path}"

  return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
# write_allure_placeholder STATUS NAME MESSAGE TRACE
#
# Writes a minimal Allure result JSON for a collection that could not be run
# (skipped or broken).  The file is written to PATH_TO_ALLURE_RESULTS.
#
# Args:
#   $1  status  — "skipped" or "broken"
#   $2  name    — human-readable test/collection name
#   $3  message — statusDetails.message
#   $4  trace   — statusDetails.trace
#
# Globals read:  PATH_TO_ALLURE_RESULTS
# ---------------------------------------------------------------------------
write_allure_placeholder() {
  local status="$1"
  local name="$2"
  local message="$3"
  local trace="$4"

  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid)
  local ts
  ts=$(date +%s)

  cat > "${PATH_TO_ALLURE_RESULTS}/${uuid}-result.json" <<EOF
{
  "uuid": "${uuid}",
  "name": "${name}",
  "status": "${status}",
  "stage": "finished",
  "labels": [
    { "name": "parentSuite", "value": "Bruno" },
    { "name": "suite",       "value": "${name}" }
  ],
  "statusDetails": {
    "message": "${message}",
    "trace":   "${trace}"
  },
  "start": ${ts}000,
  "stop":  ${ts}000
}
EOF
}

# ---------------------------------------------------------------------------
# wait_for_collection_slot
#
# Blocks until one PID in the global active_collection_pids array has exited,
# then removes it from the array.
#
# Globals read/write:  active_collection_pids
# ---------------------------------------------------------------------------
wait_for_collection_slot() {
  while true; do
    for idx in "${!active_collection_pids[@]}"; do
      local pid="${active_collection_pids[$idx]}"

      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" || true
        unset 'active_collection_pids[idx]'
        active_collection_pids=("${active_collection_pids[@]}")
        return 0
      fi
    done

    sleep 1
  done
}

# ---------------------------------------------------------------------------
# run_collection_body COLLECTION_DIR
#
# Entry point for a single collection subprocess.  Resolves folders, runs
# bru.js, converts the JSON report to Allure, and writes a placeholder on
# failure.
#
# Args:
#   $1  collection_dir — path relative to TMP_DIR
#
# Globals read:  TMP_DIR, PATH_TO_ATTACHMENTS_DIR, PATH_TO_ALLURE_RESULTS,
#                BRUNO_FOLDERS_STR, BRU_BIN, BRUNO_ENV_STR,
#                BRUNO_ENV_VARS_CLI, BRUNO_FLAGS_CLI, COLLECTION_TIMEOUT
# ---------------------------------------------------------------------------
run_collection_body() {
  local collection_dir="$1"
  local collection_path="${TMP_DIR}/${collection_dir}"

  # Deserialise the folder list from the exported string (arrays cannot be
  # exported across process boundaries, so the dispatcher serialises them).
  local -a BRUNO_FOLDERS_ARRAY=()
  if [ -n "$BRUNO_FOLDERS_STR" ]; then
    mapfile -t BRUNO_FOLDERS_ARRAY <<< "$BRUNO_FOLDERS_STR"
  fi

  echo "➡️ Processing collection: $collection_path"

  if [ ! -d "$collection_path" ]; then
    echo "❌ Collection not found: $collection_path — skipping"
    write_allure_placeholder \
      "skipped" \
      "Collection: $(basename "$collection_dir")" \
      "Collection directory not found: $collection_path" \
      ""
    return 0
  fi

  local collection_name
  collection_name=$(basename "$collection_dir")
  local bruno_report_path="${PATH_TO_ATTACHMENTS_DIR}/${collection_name}-result.json"
  local raw_log_path="${PATH_TO_ATTACHMENTS_DIR}/${collection_name}.raw.log"

  local collection_start_ts
  collection_start_ts=$(date +%s)
  echo "START collection=${collection_name} pid=$$ time=$(date '+%H:%M:%S')"

  pushd "$collection_path" > /dev/null || return 1

  # Resolve requested folder names to real paths inside this collection.
  RESOLVED_FOLDERS=()
  resolve_folders BRUNO_FOLDERS_ARRAY

  local run_ok=true

  if [ "${#BRUNO_FOLDERS_ARRAY[@]}" -eq 0 ]; then
    # Full-collection mode
    echo "Running full collection"
    echo "BRUNO RUN START collection=${collection_name} pid=$$ mode=full time=$(date '+%H:%M:%S')"

    if ! run_bru "$bruno_report_path" "$raw_log_path"; then
      echo "FAILED: ${collection_name} rc=$?"
      echo "----- LAST 200 LINES: ${collection_name} -----"
      tail -n 200 "${raw_log_path}" || true
      echo "--------------------------------------------"
      touch "${TMP_DIR}/.collection_failed"
      run_ok=false
    else
      echo "SUCCESS: ${collection_name}"
    fi

    echo "BRUNO RUN END collection=${collection_name} pid=$$ time=$(date '+%H:%M:%S')"

  elif [ "${#RESOLVED_FOLDERS[@]}" -eq 0 ]; then
    # Folder-filter requested but nothing matched — skip with a placeholder
    echo "No matching folders found — skipping collection"
    popd > /dev/null || return 1
    write_allure_placeholder \
      "skipped" \
      "Collection: ${collection_name}" \
      "No matching folders found" \
      "Folders: ${BRUNO_FOLDERS_ARRAY[*]}"
    local collection_end_ts
    collection_end_ts=$(date +%s)
    echo "FINISHED collection=${collection_name} pid=$$ duration=$((collection_end_ts-collection_start_ts))s"
    return 0

  else
    # Folder-filter mode
    echo "Running folders: ${RESOLVED_FOLDERS[*]}"
    echo "BRUNO RUN START collection=${collection_name} pid=$$ mode=folders time=$(date '+%H:%M:%S')"

    if ! run_bru "$bruno_report_path" "$raw_log_path" "${RESOLVED_FOLDERS[@]}"; then
      echo "FAILED: ${collection_name} rc=$?"
      echo "----- LAST 200 LINES: ${collection_name} -----"
      tail -n 200 "${raw_log_path}" || true
      echo "--------------------------------------------"
      touch "${TMP_DIR}/.collection_failed"
      run_ok=false
    else
      echo "SUCCESS: ${collection_name}"
    fi

    echo "BRUNO RUN END collection=${collection_name} pid=$$ time=$(date '+%H:%M:%S')"
  fi

  popd > /dev/null || return 1

  local collection_end_ts
  collection_end_ts=$(date +%s)
  echo "FINISHED collection=${collection_name} pid=$$ duration=$((collection_end_ts-collection_start_ts))s time=$(date '+%H:%M:%S')"

  # Convert report or write a broken placeholder
  if [ -f "$bruno_report_path" ]; then
    echo "Parsing report: ${bruno_report_path}"
    local count
    count=$(jq 'if type=="array"
                then (if (.[0]?|type)=="object" and (.[0]?|has("results"))
                      then ([.[].results[]]|length)
                      else length end)
                elif type=="object" and has("results") then (.results|length)
                else 0 end' "$bruno_report_path")
    echo "${collection_name} -> ${count} tests"
    printf "%s,%s\n" "${collection_name}" "${count}" >> "${TMP_DIR}/tests_count.csv"
    node /scripts/tools/bruno-to-allure.js \
      "$bruno_report_path" \
      "$PATH_TO_ALLURE_RESULTS" \
      "$collection_name"
    echo "COLLECTION FULLY FINISHED collection=${collection_name} pid=$$ time=$(date '+%H:%M:%S')"
  else
    echo "Bruno report missing — writing broken result to Allure"
    write_allure_placeholder \
      "broken" \
      "Collection: ${collection_name}" \
      "Bruno report file not generated" \
      "See raw log: ${raw_log_path}"
  fi

  if [ "$run_ok" = false ]; then
    return 1
  fi
  return 0
}
