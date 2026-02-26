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

  echo "📍 Current working directory: $(pwd)"
  echo "📍 TMP_DIR: $TMP_DIR"
  echo "🔧 Bruno version: $(bru --version 2>/dev/null || echo 'not found')"
  echo "🔧 Node version: $(node --version)"
  echo "🔧 NPM version: $(npm --version)"
  echo ""

  if ! jq . <<< "$TEST_PARAMS" >/dev/null 2>&1; then
    echo "❌ TEST_PARAMS is not valid JSON"
    return 1
  fi

  jq . <<< "$TEST_PARAMS" > /tmp/test_params.json

  BRUNO_ENV=$(jq -r '.env // empty' /tmp/test_params.json)
  if [ -z "$BRUNO_ENV" ]; then
    echo "❌ TEST_PARAMS.env is required"
    return 1
  fi

  echo "🔧 Using Bruno environment: $BRUNO_ENV"

  mapfile -t COLLECTIONS < <(jq -r '.collections[]? // empty' /tmp/test_params.json)

  if [ "${#COLLECTIONS[@]}" -eq 0 ]; then
    echo "❌ No collections provided"
    return 1
  fi

  BRUNO_FLAGS=$(jq -r '.flags[]? // empty' /tmp/test_params.json | xargs)
  export BRUNO_ENV="$BRUNO_ENV"
  export public_gateway_url="$PUBLIC_GATEWAY_URL"
  export private_gateway_url="$PRIVATE_GATEWAY_URL"
  export internal_gateway_url="$INTERNAL_GATEWAY_URL"
  export opensearch_url="$OPENSEARCH_URL"
  export huawei_url="$HUAWEI_URL"
  export monitoring_alarm_engine_url="$MONITORING_ALARM_ENGINE_URL"
  export kafka_platform_url="$KAFKA_PLATFORM_URL"

  echo "🔎 Effective gateway mapping:"
  echo "public_gateway_url=$public_gateway_url"
  echo "BRUNO_ENV=$BRUNO_ENV"
  echo ""
  export BRUNO_ENV="$BRUNO_ENV"
  export public_gateway_url="$PUBLIC_GATEWAY_URL"
  export private_gateway_url="$PRIVATE_GATEWAY_URL"
  export internal_gateway_url="$INTERNAL_GATEWAY_URL"
  export opensearch_url="$OPENSEARCH_URL"
  export huawei_url="$HUAWEI_URL"
  export monitoring_alarm_engine_url="$MONITORING_ALARM_ENGINE_URL"
  export kafka_platform_url="$KAFKA_PLATFORM_URL"
  
  for COL in "${COLLECTIONS[@]}"; do
    echo "--------------------------------------------------"
    echo "🚀 Running collection: $COL"

    if [ ! -d "$COL" ]; then
      echo "❌ Collection not found: $COL"
      return 1
    fi

    # 1) normalize path for running FROM collections root
    COL_REL="${COL#collections/}"

    COLLECTION_NAME=$(basename "$COL")
    BRUNO_REPORT_PATH="$TMP_DIR/attachments/${COLLECTION_NAME}-result.json"

    mkdir -p "$TMP_DIR/attachments" "$TMP_DIR/allure-results"



    (
      cd collections || exit 1

      echo "📄 Saving Bruno JSON report to: $BRUNO_REPORT_PATH"
      echo "🧪 EXECUTING: bru run \"$COL_REL\" --env \"$BRUNO_ENV\" $BRUNO_FLAGS ..."

      bru run "$COL_REL" \
        --env "$BRUNO_ENV" \
        $BRUNO_FLAGS \
        --reporter-json "$BRUNO_REPORT_PATH" \
        --verbose
    )

    BRU_EXIT_CODE=$?
    echo "🔎 Bruno exit code: $BRU_EXIT_CODE"

    if [ $BRU_EXIT_CODE -ne 0 ]; then
      echo "❌ Bruno execution failed"
      return $BRU_EXIT_CODE
    fi

    if [ ! -f "$BRUNO_REPORT_PATH" ]; then
      echo "❌ Bruno report not generated"
      return 1
    fi

    echo "🔄 Converting Bruno report to Allure format..."
    node /tools/bruno-to-allure.js "$BRUNO_REPORT_PATH" "$TMP_DIR/allure-results"
  done

  echo "✅ Bruno tests completed successfully"
  return 0
}