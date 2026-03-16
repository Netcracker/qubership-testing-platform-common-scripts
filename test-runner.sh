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

      if ! output=$(${BRU_BIN}/bru.js run ${BRUNO_FLAGS_CLI} \
        --env "${BRUNO_ENV_STR}" \
        ${BRUNO_ENV_VARS_CLI} \
        --reporter-json "${bruno_report_path}" 2>&1); then

        echo "$output"
        echo "❌ FAILED: $collection_name"
        TOTAL_FAILED=1

      else
        echo "$output"
        echo "✅ SUCCESS: $collection_name"
      fi

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

        return
      fi

      echo "➡ Running folders: ${RESOLVED_FOLDERS[*]}"

      
      if ! output=$(${BRU_BIN}/bru.js run ${BRUNO_FLAGS_CLI} \
        --env "${BRUNO_ENV_STR}" \
        ${BRUNO_ENV_VARS_CLI} \
        "${RESOLVED_FOLDERS[@]}" \
        --reporter-json "${bruno_report_path}" 2>&1); then

        echo "$output"
        echo "❌ FAILED: $collection_name"
        TOTAL_FAILED=1

      else
        echo "$output"
        echo "✅ SUCCESS: $collection_name"
      fi

    fi

    popd > /dev/null || return 1

    if [ -f "$bruno_report_path" ]; then

      count=$(jq '.results | length' "$bruno_report_path")

      echo "📊 $collection_name → $count tests"
      printf "%s,%s\n" "$collection_name" "$count" >> "$TMP_DIR/tests_count.csv"
      node /tools/bruno-to-allure.js \
        "$bruno_report_path" \
        "$PATH_TO_ALLURE_RESULTS" \
        "$collection_name"

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
          "trace": $(jq -Rs . <<< "$output")
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
  source /tools/bru_tools.sh

  check_env_var "TEST_PARAMS" ""

  extract_bruno_env "$TEST_PARAMS" "BRUNO_ENV_STR"
  extract_bruno_collections "$TEST_PARAMS" "BRUNO_COLLECTIONS_ARRAY"
  extract_bruno_env_vars "$TEST_PARAMS" "BRUNO_ENV_VARS_CLI"
  extract_bruno_flags "$TEST_PARAMS" "BRUNO_FLAGS_CLI"
  extract_bruno_folders "$TEST_PARAMS" "BRUNO_FOLDERS_ARRAY"

  cd "$TMP_DIR" || return 1

  PATH_TO_ATTACHMENTS_DIR="${TMP_DIR}/attachments"
  PATH_TO_ALLURE_RESULTS="${TMP_DIR}/allure-results"
  rm -rf "$PATH_TO_ATTACHMENTS_DIR" "$PATH_TO_ALLURE_RESULTS" "$TMP_DIR/allure-report"
  mkdir -p "$PATH_TO_ATTACHMENTS_DIR"
  mkdir -p "$PATH_TO_ALLURE_RESULTS"
  : > "$TMP_DIR/tests_count.csv"

  echo "NAMESPACE=$NAMESPACE" > "$PATH_TO_ALLURE_RESULTS/environment.properties"
  echo "PUBLIC_GATEWAY_URL=$PUBLIC_GATEWAY_URL" >> "$PATH_TO_ALLURE_RESULTS/environment.properties"
  echo "BRUNO_ENV=$BRUNO_ENV_STR" >> "$PATH_TO_ALLURE_RESULTS/environment.properties"

  export PUBLIC_GATEWAY_URL
  export PRIVATE_GATEWAY_URL
  export INTERNAL_GATEWAY_URL
  export OPENSEARCH_URL
  export HUAWEI_URL
  export MONITORING_ALARM_ENGINE_URL
  export KAFKA_PLATFORM_URL
  export NAMESPACE
  export PUBLIC_GATEWAY_LOGIN
  export PUBLIC_GATEWAY_PASSWORD

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

  PARALLELISM=${PARALLELISM:-4}
  echo "Collections to run:"
  printf "%s\n" "${BRUNO_COLLECTIONS_ARRAY[@]}"
  echo "Total collections: ${#BRUNO_COLLECTIONS_ARRAY[@]}"

  echo "⚡ Running ${#BRUNO_COLLECTIONS_ARRAY[@]} collections with parallelism=$PARALLELISM"

  printf "%s\n" "${BRUNO_COLLECTIONS_ARRAY[@]}" > "$PATH_TO_ALLURE_RESULTS/collections.txt"

  printf "%s\n" "${BRUNO_COLLECTIONS_ARRAY[@]}" \
  | xargs -I {} -P "${PARALLELISM}" bash -c 'run_collection_body "$@"' _ {} || true

  echo "📊 Generating Allure HTML report..."
  if command -v allure >/dev/null 2>&1; then
    if allure generate "$PATH_TO_ALLURE_RESULTS" -o "$TMP_DIR/allure-report" --clean; then
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