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
#!/bin/bash

# Test execution module
run_tests() {
    echo "▶ Starting test execution..."

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
        ./start_tests.sh || TEST_EXIT_CODE=$?
    elif [ -d "./collections" ]; then
        echo "ℹ️ start_tests.sh not found, but collections/ detected — running default Bruno runner"
        run_bruno_from_test_params || TEST_EXIT_CODE=$?
    else
        echo "❌ Neither start_tests.sh nor collections/ directory found in tests repo"
        exit 1
    fi

    TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}
    echo "ℹ️ Test script exited with code: $TEST_EXIT_CODE (but continuing...)"
    echo "✅ Test execution completed"
}
run_bruno_from_test_params() {

  echo "=================================================="
  echo "🚀 Starting Bruno execution from TEST_PARAMS"
  echo "=================================================="

  echo "📍 Working directory: $(pwd)"
  echo "📍 TMP_DIR: $TMP_DIR"
  echo "🔧 Bruno version: $(bru --version 2>/dev/null || echo 'NOT FOUND')"
  echo "🔧 Node version: $(node --version)"
  echo "🔧 NPM version: $(npm --version)"
  echo "=================================================="

  # Validate TEST_PARAMS
  if ! jq . <<< "$TEST_PARAMS" >/dev/null 2>&1; then
    echo "❌ TEST_PARAMS is not valid JSON"
    return 1
  fi

  echo "$TEST_PARAMS" | jq .
  echo "=================================================="

  # Extract ENV
  BRUNO_ENV=$(jq -r '.env // empty' <<< "$TEST_PARAMS")

  if [ -z "$BRUNO_ENV" ]; then
    echo "❌ TEST_PARAMS.env is required"
    return 1
  fi

  echo "🌍 Bruno environment: $BRUNO_ENV"

  # Extract collections
  mapfile -t COLLECTIONS < <(jq -r '.collections[]?' <<< "$TEST_PARAMS")

  if [ "${#COLLECTIONS[@]}" -eq 0 ]; then
    echo "❌ No collections found in TEST_PARAMS"
    return 1
  fi

  echo "📦 Collections to execute (${#COLLECTIONS[@]}):"
  for c in "${COLLECTIONS[@]}"; do
    echo "   - $c"
  done
  echo "=================================================="

  # Extract flags
  BRUNO_FLAGS=$(jq -r '.flags[]?' <<< "$TEST_PARAMS" | xargs)
  echo "🏁 Bruno flags: $BRUNO_FLAGS"
  echo "=================================================="

  # Prepare folders
  mkdir -p "$TMP_DIR/attachments"
  mkdir -p "$TMP_DIR/allure-results"

  TOTAL_FAILED=0

  # Execute collections
  for COL in "${COLLECTIONS[@]}"; do

    echo ""
    echo "##################################################"
    echo "🚀 Starting collection: $COL"
    echo "##################################################"

    if [ ! -d "$COL" ]; then
      echo "❌ Collection directory not found: $COL"
      TOTAL_FAILED=1
      continue
    fi

    COLLECTION_NAME=$(basename "$COL")
    BRUNO_REPORT_PATH="$TMP_DIR/attachments/${COLLECTION_NAME}-result.json"

    echo "📂 Entering directory: $COL"

    pushd "$COL" > /dev/null || {
      echo "❌ Failed to enter directory: $COL"
      TOTAL_FAILED=1
      continue
    }

    echo "▶ Running command:"
    echo "bru run . --env \"$BRUNO_ENV\" $BRUNO_FLAGS --reporter-json \"$BRUNO_REPORT_PATH\" --verbose"
    echo "--------------------------------------------------"

    if ! bru run . \
      --env "$BRUNO_ENV" \
      $BRUNO_FLAGS \
      --reporter-json "$BRUNO_REPORT_PATH" \
      --verbose; then

      echo "❌ Bruno FAILED for: $COLLECTION_NAME"
      TOTAL_FAILED=1
    else
      echo "✅ Bruno SUCCEEDED for: $COLLECTION_NAME"
    fi

    echo "--------------------------------------------------"
    echo "🔄 Converting Bruno JSON to Allure..."

    if [ -f "$BRUNO_REPORT_PATH" ]; then
      node /tools/bruno-to-allure.js \
        "$BRUNO_REPORT_PATH" \
        "$TMP_DIR/allure-results"
      echo "✅ Allure conversion completed"
    else
      echo "⚠️ Bruno report file not found: $BRUNO_REPORT_PATH"
      TOTAL_FAILED=1
    fi

    popd > /dev/null

    echo "##################################################"
    echo "🏁 Finished collection: $COLLECTION_NAME"
    echo "##################################################"

  done

  echo ""
  echo "=================================================="
  echo "📊 Bruno execution finished"
  echo "=================================================="

  if [ "$TOTAL_FAILED" -ne 0 ]; then
    echo "❌ Some collections FAILED"
    return 1
  else
    echo "✅ All collections executed successfully"
    return 0
  fi
}