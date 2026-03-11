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

run_bruno_from_test_params() {
  echo "🚀 Bruno execution with EnvGene (legacy mode)"

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

  mkdir -p "$PATH_TO_ATTACHMENTS_DIR"
  mkdir -p "$PATH_TO_ALLURE_RESULTS"

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
  BRUNO_FOLDERS_CLI=()

  for folder in "${BRUNO_FOLDERS_ARRAY[@]}"; do
    BRUNO_FOLDERS_CLI+=(--folder "$folder")
  done
  for collection_dir in "${BRUNO_COLLECTIONS_ARRAY[@]}"; do
    collection_path="${TMP_DIR}/${collection_dir}"

    echo "➡️ Processing collection: $collection_path"

    if [ -d "$collection_path" ]; then
      collection_name=$(basename "$collection_dir")
      bruno_report_path="${PATH_TO_ATTACHMENTS_DIR}/${collection_name}-result.json"

      pushd "$collection_path" > /dev/null || return 1

      # shellcheck disable=SC2086
      if ! output=$(${BRU_BIN}/bru.js run ${BRUNO_FLAGS_CLI} \
        --env "${BRUNO_ENV_STR}" \
        ${BRUNO_ENV_VARS_CLI} \
        "${BRUNO_FOLDERS_CLI[@]}" \
        --reporter-json "${bruno_report_path}" 2>&1); then

        echo "$output"
        echo "❌ FAILED: $collection_name"
        TOTAL_FAILED=1
      else
        echo "$output"
        echo "✅ SUCCESS: $collection_name"
      fi

      popd > /dev/null || return 1

      node /tools/bruno-to-allure.js \
        "$bruno_report_path" \
        "$PATH_TO_ALLURE_RESULTS"
    
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
    "statusDetails": {
      "message": "Collection directory not found: $collection_path",
      "trace": ""
    },
    "start": $(date +%s)000,
    "stop": $(date +%s)000
  }
EOF

  fi

  done

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

  echo " DEBUG ALLURE RESULTS "
  ls -la "$PATH_TO_ALLURE_RESULTS"
  echo "-----------------------------------------"

  if [ "$TOTAL_FAILED" -ne 0 ]; then
    return 1
  else
    return 0
  fi
}