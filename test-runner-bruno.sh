#!/usr/bin/env bash
# test-runner-bruno.sh — dispatcher: parse TEST_PARAMS and run collections in parallel.
#
# Depends on:
#   scripts/tools/bru_tools.sh   (sourced by the caller, entrypoint.sh)
#   scripts/lib/collection-runner.sh  (sourced here)

source /scripts/lib/collection-runner.sh

run_bruno_from_test_params() {
  echo "🚀 Bruno execution started"

  extract_bruno_collections "$TEST_PARAMS" "BRUNO_COLLECTIONS_ARRAY"

  local bruno_auto_discover=0
  if [ "${#BRUNO_COLLECTIONS_ARRAY[@]}" -eq 0 ]; then
    echo "📋 No collections provided — discovering all Bruno collections automatically"
    discover_bruno_collections "BRUNO_COLLECTIONS_ARRAY"
  elif [ "${#BRUNO_COLLECTIONS_ARRAY[@]}" -eq 1 ] && [[ "${BRUNO_COLLECTIONS_ARRAY[0],,}" == "all" ]]; then
    echo "📋 'all' specified — discovering all Bruno collections automatically"
    discover_bruno_collections "BRUNO_COLLECTIONS_ARRAY"
  fi

  if [ "${#BRUNO_COLLECTIONS_ARRAY[@]}" -eq 0 ]; then
    echo "❌ No collections discovered, please check 'collections' directory or provide collections explicitly"
    return 1
  else
    echo "📦 Discovered Bruno collections:"
    printf "  - %s\n" "${BRUNO_COLLECTIONS_ARRAY[@]}"
  fi

  BRUNO_ENV_STR="$BRUNO_ENV"
  BRUNO_FLAGS_CLI="$BRUNO_FLAGS"
  extract_bruno_folders "$BRUNO_FOLDERS" "BRUNO_FOLDERS_ARRAY"

  cd "$TMP_DIR" || return 1

  PATH_TO_ATTACHMENTS_DIR="${TMP_DIR}/attachments"
  PATH_TO_ALLURE_RESULTS="${TMP_DIR}/allure-results"
  rm -rf "$PATH_TO_ATTACHMENTS_DIR" "$PATH_TO_ALLURE_RESULTS"
  mkdir -p "$PATH_TO_ATTACHMENTS_DIR" "$PATH_TO_ALLURE_RESULTS"
  : > "$TMP_DIR/tests_count.csv"

  # Single pass: write environment.properties AND export matching vars to subprocesses.
  {
    echo "BRUNO_ENV=${BRUNO_ENV_STR}"
    while IFS= read -r key; do
      case "$key" in
        *_URL|*_LOGIN|*_PASSWORD|NAMESPACE|SERVER_HOSTNAME)
          printf '%s=%s\n' "$key" "${!key}"
          export "${key?}"
          echo "  Exported: $key" >&2
          ;;
      esac
    done < <(compgen -e | sort)
  } > "$PATH_TO_ALLURE_RESULTS/environment.properties"

  # Export everything the subprocess needs (arrays can't cross fork; serialise folders).
  export -f run_collection_body resolve_folders run_bru write_allure_placeholder wait_for_collection_slot

  export TMP_DIR PATH_TO_ATTACHMENTS_DIR PATH_TO_ALLURE_RESULTS
  export BRU_BIN BRUNO_ENV_STR BRUNO_FLAGS_CLI

  if [ "${#BRUNO_FOLDERS_ARRAY[@]}" -gt 0 ]; then
    BRUNO_FOLDERS_STR=$(printf "%s\n" "${BRUNO_FOLDERS_ARRAY[@]}")
  else
    BRUNO_FOLDERS_STR=""
  fi
  export BRUNO_FOLDERS_STR

  local parallelism="${PARALLELISM:-4}"
  echo "Collections to run:"
  printf "  %s\n" "${BRUNO_COLLECTIONS_ARRAY[@]}"
  echo "Total: ${#BRUNO_COLLECTIONS_ARRAY[@]}  parallelism=${parallelism}"

  printf "%s\n" "${BRUNO_COLLECTIONS_ARRAY[@]}" > "$PATH_TO_ALLURE_RESULTS/collections.txt"

  local parallel_start_ts
  parallel_start_ts=$(date +%s)
  echo "⚡ PARALLEL PHASE START time=$(date '+%H:%M:%S')"

  local running_jobs=0
  active_collection_pids=()

  for collection in "${BRUNO_COLLECTIONS_ARRAY[@]}"; do
    bash -c 'run_collection_body "$1"' _ "$collection" &
    active_collection_pids+=("$!")
    running_jobs=$((running_jobs + 1))

    if [ "$running_jobs" -ge "$parallelism" ]; then
      wait_for_collection_slot
      running_jobs=$((running_jobs - 1))
    fi
  done

  # todo replace with wait?
  while [ "$running_jobs" -gt 0 ]; do
    wait_for_collection_slot
    running_jobs=$((running_jobs - 1))
  done

  local parallel_end_ts
  parallel_end_ts=$(date +%s)
  echo "✅ PARALLEL PHASE END time=$(date '+%H:%M:%S') took=$((parallel_end_ts-parallel_start_ts))s"

  echo "==== TEST COUNT BY COLLECTION ===="
  sort "$TMP_DIR/tests_count.csv"
  echo "----------------------------------"

  if [ -f "${TMP_DIR}/.collection_failed" ]; then
    return 1
  fi
  return 0
}
