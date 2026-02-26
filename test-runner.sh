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

  echo "================= BRUNO DEBUG START ================="

  echo "📍 PWD: $(pwd)"
  echo "📍 Bruno path: $(which bru)"
  echo "📍 Bruno version: $(bru --version)"
  echo "📍 Node version: $(node --version)"
  echo "📍 NPM version: $(npm --version)"

  echo "📦 TEST_PARAMS RAW:"
  echo "$TEST_PARAMS"

  if ! jq . <<< "$TEST_PARAMS" >/dev/null 2>&1; then
      echo "❌ TEST_PARAMS invalid JSON"
      return 1
  fi

  jq . <<< "$TEST_PARAMS" > /tmp/test_params.json

  echo "📦 Parsed TEST_PARAMS:"
  cat /tmp/test_params.json

  BRUNO_ENV=$(jq -r '.env // empty' /tmp/test_params.json)
  echo "🔧 BRUNO_ENV=$BRUNO_ENV"

  mapfile -t COLLECTIONS < <(jq -r '.collections[]? // empty' /tmp/test_params.json)

  echo "📦 COLLECTIONS:"
  printf '%s\n' "${COLLECTIONS[@]}"

  BRUNO_FLAGS=$(jq -r '.flags[]? // empty' /tmp/test_params.json | xargs)
  echo "🔧 BRUNO_FLAGS=[$BRUNO_FLAGS]"

  for COL in "${COLLECTIONS[@]}"; do

      echo "=================================================="
      echo "🚀 Running collection: $COL"

      if [ ! -d "$COL" ]; then
          echo "❌ Collection not found"
          return 1
      fi

      echo "📂 Listing collection folder:"
      ls -la "$COL"

      COLLECTION_NAME=$(basename "$COL")
      BRUNO_REPORT_PATH="$TMP_DIR/attachments/${COLLECTION_NAME}-result.json"

      mkdir -p "$TMP_DIR/attachments"
      mkdir -p "$TMP_DIR/allure-results"

      echo "📄 Report path: $BRUNO_REPORT_PATH"

      echo "🧪 EXECUTING:"
      echo "bru run \"$COL\" --env \"$BRUNO_ENV\" $BRUNO_FLAGS --reporter-json \"$BRUNO_REPORT_PATH\" --verbose"

      bru run "$COL" \
        --env "$BRUNO_ENV" \
        $BRUNO_FLAGS \
        --reporter-json "$BRUNO_REPORT_PATH" \
        --verbose

      BRU_EXIT=$?
      echo "🔎 Bruno exit code: $BRU_EXIT"

      echo "📂 Attachments after run:"
      ls -la "$TMP_DIR/attachments"

      if [ ! -f "$BRUNO_REPORT_PATH" ]; then
          echo "❌ REPORT FILE NOT CREATED"
      else
          echo "✅ REPORT FILE EXISTS"
      fi

      if [ $BRU_EXIT -ne 0 ]; then
          echo "❌ Bruno failed. STOP."
          return $BRU_EXIT
      fi

      echo "🔄 Converting to Allure..."
      node /tools/bruno-to-allure.js \
        "$BRUNO_REPORT_PATH" \
        "$TMP_DIR/allure-results"

      echo "📂 Allure folder:"
      ls -la "$TMP_DIR/allure-results"

  done

  echo "================= BRUNO DEBUG END ================="
}