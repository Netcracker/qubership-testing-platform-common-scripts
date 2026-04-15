#!/bin/bash

run_tests() {
  echo "▶ Starting test execution..."

  set -o pipefail

  # shellcheck disable=SC1091
  if [ -f "/app/scripts/upload-monitor.sh" ]; then
    source "/app/scripts/upload-monitor.sh"
  elif [ -f "/scripts/upload-monitor.sh" ]; then
    source "/scripts/upload-monitor.sh"
  else
    echo "❌ upload-monitor.sh not found!"
    exit 1
  fi

  echo "📁 Creating Allure results directory..."
  mkdir -p "$TMP_DIR/allure-results"

  echo "🔐 Clearing sensitive environment variables before tests..."
  clear_sensitive_vars

  echo "🚀 Running test suite..."

  if [ -f "./start_tests.sh" ]; then
    chmod +x "./start_tests.sh"
    ./start_tests.sh
    TEST_EXIT_CODE=$?
  elif [ -d "./collections" ]; then
    echo "ℹ️ collections/ detected — running Bruno runner"
    run_bruno_from_test_params
    TEST_EXIT_CODE=$?
  else
    echo "❌ Neither start_tests.sh nor collections/ directory found"
    exit 1
  fi

  TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}
  echo "ℹ️ Test script exited with code: $TEST_EXIT_CODE"
  echo "✅ Test execution completed"

  return "$TEST_EXIT_CODE"
}

apply_project_patches() {
  local patch_dir="$1"
  local patch_root="$2"
  local fail_on_error="${3:-true}"

  if [ ! -d "$patch_dir" ]; then
    echo "ℹ️ No patch directory found: $patch_dir"
    return 0
  fi

  if ! command -v patch >/dev/null 2>&1; then
    echo "❌ 'patch' command is not installed"
    [ "$fail_on_error" = "true" ] && return 1 || return 0
  fi

  shopt -s nullglob
  local patches=("$patch_dir"/*.patch)
  shopt -u nullglob

  if [ ${#patches[@]} -eq 0 ]; then
    echo "ℹ️ No .patch files found in $patch_dir"
    return 0
  fi

  echo "🩹 Applying patches from: $patch_dir"
  echo "📁 Patch root: $patch_root"

  local patch_file
  for patch_file in "${patches[@]}"; do
    echo "🩹 Applying patch: $(basename "$patch_file")"

    if patch --forward --batch -p1 -d "$patch_root" < "$patch_file"; then
      echo "✅ Patch applied: $(basename "$patch_file")"
    else
      echo "❌ Failed to apply patch: $(basename "$patch_file")"
      if [ "$fail_on_error" = "true" ]; then
        return 1
      fi
    fi
  done

  return 0
}

run_collection_body() {

  collection_dir="$1"
  collection_path="${TMP_DIR}/${collection_dir}"


  if [ -n "$BRUNO_FOLDERS_STR" ]; then
    mapfile -t BRUNO_FOLDERS_ARRAY <<< "$BRUNO_FOLDERS_STR"
  else
    BRUNO_FOLDERS_ARRAY=()
  fi
  
  echo "➡️ Processing collection: $collection_path"

  if [ -d "$collection_path" ]; then
    collection_name=$(basename "$collection_dir")
    bruno_report_path="${PATH_TO_ATTACHMENTS_DIR}/${collection_name}-result.json"
    raw_log_path="${PATH_TO_ATTACHMENTS_DIR}/${collection_name}.raw.log"

    collection_start_ts=$(date +%s)
    echo "🚀 START collection=$collection_name pid=$$ time=$(date '+%H:%M:%S')"

    pushd "$collection_path" > /dev/null || return 1
    
    RESOLVED_FOLDERS=()

    if [ ${#BRUNO_FOLDERS_ARRAY[@]} -gt 0 ]; then

      for folder in "${BRUNO_FOLDERS_ARRAY[@]}"; do
        found_any=false

        while IFS= read -r found; do
          echo "✔ Found folder in $collection_name: $found"
          RESOLVED_FOLDERS+=("$found")
          found_any=true
        done < <(find . -maxdepth 5 -type d -name "$folder" -not -path "*/.git/*" -not -path "*/node_modules/*")

        if [ "$found_any" = false ]; then
          echo "⚠ Folder not found in $collection_name: $folder"
        fi
      done

    fi


    if [ ${#BRUNO_FOLDERS_ARRAY[@]} -eq 0 ]; then

      echo "➡ Running full collection"
      echo "▶ BRUNO RUN START collection=$collection_name pid=$$ mode=full time=$(date '+%H:%M:%S')"

      if ${BRU_BIN}/bru.js run ${BRUNO_FLAGS_CLI} \
        --env "${BRUNO_ENV_STR}" \
        ${BRUNO_ENV_VARS_CLI} \
        --reporter-json "${bruno_report_path}" \
        >"${raw_log_path}" 2>&1; then
        echo "✅ SUCCESS: $collection_name"
      else
        rc=$?
        echo "❌ FAILED: $collection_name rc=$rc"
        TOTAL_FAILED=0
      fi

      echo "◀ BRUNO RUN END collection=$collection_name pid=$$ time=$(date '+%H:%M:%S')"
    else

      if [ ${#RESOLVED_FOLDERS[@]} -eq 0 ]; then
        echo "⚠ No matching folders found — skipping collection"
        popd > /dev/null
        uuid=$(cat /proc/sys/kernel/random/uuid)

        cat > "$PATH_TO_ALLURE_RESULTS/${uuid}-result.json" <<EOF
        {
          "uuid": "$uuid",
          "name": "Collection: $collection_name",
          "status": "skipped",
          "stage": "finished",
          "statusDetails": {
            "message": "No matching folders found",
            "trace": "Folders: ${BRUNO_FOLDERS_ARRAY[*]}"
          },
          "start": $(date +%s)000,
          "stop": $(date +%s)000
        }
EOF
        collection_end_ts=$(date +%s)
        echo "🏁 BRUNO EXECUTION FINISHED =$collection_name pid=$$ duration=$((collection_end_ts-collection_start_ts))s time=$(date '+%H:%M:%S')"
        return
      fi

      echo "➡ Running folders: ${RESOLVED_FOLDERS[*]}"
      echo "▶ BRUNO RUN START collection=$collection_name pid=$$ mode=folders time=$(date '+%H:%M:%S')"

      if ${BRU_BIN}/bru.js run ${BRUNO_FLAGS_CLI} \
        --env "${BRUNO_ENV_STR}" \
        ${BRUNO_ENV_VARS_CLI} \
        "${RESOLVED_FOLDERS[@]}" \
        --reporter-json "${bruno_report_path}" \
        >"${raw_log_path}" 2>&1; then
        echo "✅ SUCCESS: $collection_name"
      else
        rc=$?
        echo "❌ FAILED: $collection_name rc=$rc"
        TOTAL_FAILED=1
      fi

      echo "◀ BRUNO RUN END collection=$collection_name pid=$$ time=$(date '+%H:%M:%S')"
    fi

    popd > /dev/null || return 1

    collection_end_ts=$(date +%s)

    echo "🏁 BRUNO EXECUTION FINISHED =$collection_name pid=$$ duration=$((collection_end_ts-collection_start_ts))s time=$(date '+%H:%M:%S')"

    if [ -f "$bruno_report_path" ]; then
      echo "📦 Parsing report: $bruno_report_path"

      count=$(jq 'if type=="array" then (if (.[0]?|type)=="object" and (.[0]?|has("results")) then ([.[].results[]]|length) else length end) elif type=="object" and has("results") then (.results|length) else 0 end' "$bruno_report_path")
      echo "📊 $collection_name → $count tests"
      printf "%s,%s\n" "$collection_name" "$count" >> "$TMP_DIR/tests_count.csv"
      node /app/tools/bruno-to-allure.js  \
        "$bruno_report_path" \
        "$PATH_TO_ALLURE_RESULTS" \
        "$collection_name"
      echo "✅ COLLECTION FULLY FINISHED collection=$collection_name pid=$$ time=$(date '+%H:%M:%S')"
    else

      echo "⚠ Bruno report missing — writing broken test to Allure"

      uuid=$(cat /proc/sys/kernel/random/uuid)

      cat > "$PATH_TO_ALLURE_RESULTS/${uuid}-result.json" <<EOF
      {
        "uuid": "$uuid",
        "name": "Collection: $collection_name",
        "status": "broken",
        "stage": "finished",
        "labels": [
          { "name": "parentSuite", "value": "Bruno" },
          { "name": "suite", "value": "$collection_name" }
        ],
        "statusDetails": {
          "message": "Bruno report file not generated",
          "trace": "See raw log: $raw_log_path"
        },
        "start": $(date +%s)000,
        "stop": $(date +%s)000
      }
EOF
      
    fi

  else
    echo "⚠️ Collection not found: $collection_path — skipping"

    uuid=$(cat /proc/sys/kernel/random/uuid)
    skipped_file="$PATH_TO_ALLURE_RESULTS/${uuid}-result.json"

    cat > "$skipped_file" <<EOF
    {
      "uuid": "$uuid",
      "name": "Collection: $(basename "$collection_dir")",
      "status": "skipped",
      "stage": "finished",
      "labels": [
        { "name": "parentSuite", "value": "Bruno" },
        { "name": "suite", "value": "$(basename "$collection_dir")" }
      ],
      "statusDetails": {
        "message": "Collection directory not found: $collection_path",
        "trace": ""
      },
      "start": $(date +%s)000,
      "stop": $(date +%s)000
    }
EOF

  fi

}

run_bruno_from_test_params() {
  echo "🚀 Bruno execution with EnvGene "

  # shellcheck disable=SC1091
  source /app/tools/bru_tools.sh

  check_env_var "TEST_PARAMS" ""

  extract_bruno_env "$TEST_PARAMS" "BRUNO_ENV_STR"
  extract_bruno_collections "$TEST_PARAMS" "BRUNO_COLLECTIONS_ARRAY"
  if [ ${#BRUNO_COLLECTIONS_ARRAY[@]} -eq 0 ]; then
    echo "⚠ No collections provided — discovering all collections automatically"

    mapfile -t BRUNO_COLLECTIONS_ARRAY < <(
      find collections -mindepth 1 -maxdepth 1 -type d \
      ! -name ".git" \
      ! -name "node_modules" \
      | sort
    )

    echo "📦 Discovered collections:"
    printf "  - %s\n" "${BRUNO_COLLECTIONS_ARRAY[@]}"
  fi
  extract_bruno_env_vars "$TEST_PARAMS" "BRUNO_ENV_VARS_CLI"
  extract_bruno_flags "$TEST_PARAMS" "BRUNO_FLAGS_CLI"
  extract_bruno_folders "$TEST_PARAMS" "BRUNO_FOLDERS_ARRAY"

  cd "$TMP_DIR" || return 1

  if ! apply_project_patches "${TMP_DIR}/bruno-runner/patches" "/app" "true"; then
    echo "❌ Failed to apply project patches"
    return 1
  fi

  PATH_TO_ATTACHMENTS_DIR="${TMP_DIR}/attachments"
  PATH_TO_ALLURE_RESULTS="${TMP_DIR}/allure-results"
  rm -rf "$PATH_TO_ATTACHMENTS_DIR" "$PATH_TO_ALLURE_RESULTS" "$TMP_DIR/allure-report"
  mkdir -p "$PATH_TO_ATTACHMENTS_DIR"
  mkdir -p "$PATH_TO_ALLURE_RESULTS"
  : > "$TMP_DIR/tests_count.csv"

  {
    echo "BRUNO_ENV=$BRUNO_ENV_STR"

    while IFS= read -r key; do
      case "$key" in
        *_URL|*_LOGIN|*_PASSWORD|NAMESPACE|SERVER_HOSTNAME)
          printf '%s=%s\n' "$key" "${!key}"
          ;;
      esac
    done < <(compgen -e | sort)
  } > "$PATH_TO_ALLURE_RESULTS/environment.properties"

  echo "Env vars exported to Bruno child processes:"
  while IFS= read -r key; do
    case "$key" in
      *_URL|*_LOGIN|*_PASSWORD|NAMESPACE|SERVER_HOSTNAME)
        export "$key"
        echo "  - $key"
        ;;
    esac
  done < <(compgen -e)

  TOTAL_FAILED=0
  export -f run_collection_body

  export TMP_DIR
  export PATH_TO_ATTACHMENTS_DIR
  export PATH_TO_ALLURE_RESULTS
  export BRU_BIN
  export BRUNO_ENV_STR
  export BRUNO_ENV_VARS_CLI
  export BRUNO_FLAGS_CLI

  if [ ${#BRUNO_FOLDERS_ARRAY[@]} -gt 0 ]; then
    BRUNO_FOLDERS_STR=$(printf "%s\n" "${BRUNO_FOLDERS_ARRAY[@]}")
  else
    BRUNO_FOLDERS_STR=""
  fi

export BRUNO_FOLDERS_STR

  PARALLELISM=${PARALLELISM:-2}
  echo "Collections to run:"
  printf "%s\n" "${BRUNO_COLLECTIONS_ARRAY[@]}"
  echo "Total collections: ${#BRUNO_COLLECTIONS_ARRAY[@]}"

  echo "⚡ Running ${#BRUNO_COLLECTIONS_ARRAY[@]} collections with parallelism=$PARALLELISM"

  printf "%s\n" "${BRUNO_COLLECTIONS_ARRAY[@]}" > "$PATH_TO_ALLURE_RESULTS/collections.txt"

  parallel_start_ts=$(date +%s)
  echo "✅ PARALLEL PHASE START time=$(date '+%H:%M:%S')"

  running_jobs=0

  for collection in "${BRUNO_COLLECTIONS_ARRAY[@]}"; do
    bash -c 'run_collection_body "$1"' _ "$collection" &
    running_jobs=$((running_jobs + 1))

    if [ "$running_jobs" -ge "$PARALLELISM" ]; then
      wait -n || true
      running_jobs=$((running_jobs - 1))
    fi
  done

  while [ "$running_jobs" -gt 0 ]; do
    wait -n || true
    running_jobs=$((running_jobs - 1))
  done

  parallel_end_ts=$(date +%s)

  echo "✅ PARALLEL PHASE END time=$(date '+%H:%M:%S') took=$((parallel_end_ts-parallel_start_ts))s"

  echo "📊 Generating Allure HTML report..."
  if npx allure --version >/dev/null 2>&1; then
    if npx allure generate "$PATH_TO_ALLURE_RESULTS" -o "$TMP_DIR/allure-report" --clean; then
      if [ -f "$TMP_DIR/allure-report/index.html" ]; then
        echo "✅ Allure report generated: $TMP_DIR/allure-report (index.html present)"
      else
        echo "⚠️ Allure report directory created but index.html missing"
        ls -la "$TMP_DIR/allure-report" || true
      fi
    else
      echo "⚠️ Allure report generation failed (will continue, results will still be uploaded)"
    fi
  else
    echo "⚠️ Allure CLI not found in PATH, skipping HTML report generation"
  fi

  # echo " DEBUG ALLURE RESULTS "
  # ls -la "$PATH_TO_ALLURE_RESULTS"
  echo "==== TEST COUNT BY COLLECTION ===="
  sort "$TMP_DIR/tests_count.csv"
  echo "-----------------------------------------"

  return 0
}