#!/bin/bash

run_tests() {
  echo "▶ Starting test execution..."

  set -o pipefail

  # shellcheck disable=1091
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

  return $TEST_EXIT_CODE
}

run_bruno_from_test_params() {

  echo "=================================================="
  echo "🚀 Bruno execution with EnvGene (legacy bru.js mode)"
  echo "=================================================="

  source /tools/bru_tools.sh

  # Проверяем TEST_PARAMS
  check_env_var "TEST_PARAMS" ""

  extract_bruno_env "$TEST_PARAMS" "BRUNO_ENV_STR"
  extract_bruno_collections "$TEST_PARAMS" "BRUNO_COLLECTIONS_ARRAY"
  extract_bruno_env_vars "$TEST_PARAMS" "BRUNO_ENV_VARS_CLI"
  extract_bruno_flags "$TEST_PARAMS" "BRUNO_FLAGS_CLI"

  cd "$TMP_DIR"

  PATH_TO_ATTACHMENTS_DIR="${TMP_DIR}/attachments"
  PATH_TO_ALLURE_RESULTS="${TMP_DIR}/allure-results"

  mkdir -p "$PATH_TO_ATTACHMENTS_DIR"
  mkdir -p "$PATH_TO_ALLURE_RESULTS"

  # === EnvGene экспорт ===
  echo "🔧 EnvGene mapping:"
  echo "PUBLIC_GATEWAY_URL=$PUBLIC_GATEWAY_URL"
  echo "PRIVATE_GATEWAY_URL=$PRIVATE_GATEWAY_URL"
  echo "INTERNAL_GATEWAY_URL=$INTERNAL_GATEWAY_URL"
  echo "OPENSEARCH_URL=$OPENSEARCH_URL"

  export PUBLIC_GATEWAY_URL
  export PRIVATE_GATEWAY_URL
  export INTERNAL_GATEWAY_URL
  export OPENSEARCH_URL
  export HUAWEI_URL
  export MONITORING_ALARM_ENGINE_URL
  export KAFKA_PLATFORM_URL

  # === Определяем BRU_BIN ===
  if [ -z "$BRU_BIN" ]; then
    BRU_BIN="$(npm root -g)/@usebruno/cli"
  fi

  TOTAL_FAILED=0

  for collection_dir in "${BRUNO_COLLECTIONS_ARRAY[@]}"; do

    collection_path="${TMP_DIR}/${collection_dir}"

    echo "--------------------------------------------------"
    echo "➡️ Processing: $collection_path"
    echo "--------------------------------------------------"

    if [ ! -d "$collection_path" ]; then
      echo "❌ Collection not found: $collection_path"
      TOTAL_FAILED=1
      continue
    fi

    collection_name=$(basename "$collection_dir")
    bruno_report_path="${PATH_TO_ATTACHMENTS_DIR}/${collection_name}-result.json"

    pushd "$collection_path" > /dev/null

    echo "▶ Running via bru.js"

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

    popd > /dev/null

    # Конвертация в Allure
    if [ -f "$bruno_report_path" ]; then
      node /tools/bruno-to-allure.js \
        "$bruno_report_path" \
        "$PATH_TO_ALLURE_RESULTS"
    else
      echo "⚠️ Report missing for $collection_name"
      TOTAL_FAILED=1
    fi

  done

  echo "=================================================="

  if [ "$TOTAL_FAILED" -ne 0 ]; then
    echo "❌ Some collections failed"
    return 1
  else
    echo " All collections executed"
    return 0
  fi
}