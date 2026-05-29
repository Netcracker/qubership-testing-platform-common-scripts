#!/bin/bash

run_tests() {
  echo "▶ Starting test execution..."

  # shellcheck disable=SC1091
  if [ -f "/app/scripts/upload-monitor.sh" ]; then
    source "/app/scripts/upload-monitor.sh"
  elif [ -f "/scripts/upload-monitor.sh" ]; then
    source "/scripts/upload-monitor.sh"
  else
    fail "upload-monitor.sh not found"
  fi

  extract_test_type "$TEST_PARAMS" "TEST_TYPE"

  echo "📁 Creating Allure results directory..."
  mkdir -p "$TMP_DIR/allure-results"

  echo "🔐 Clearing sensitive environment variables before tests..."
  clear_sensitive_vars

  if [ "$TEST_TYPE" = "collection" ]; then
    if [ -d "./collections" ]; then
      echo "ℹ️ collections/ detected — running Bruno runner"
      run_bruno_from_test_params || TEST_EXIT_CODE=$?
    else
      fail "❌ collections/ directory not found"
    fi

  elif [ "$TEST_TYPE" = "scope" ] || [ "$TEST_TYPE" = "test" ]; then
    if [ -f "./start_tests.sh" ]; then
      echo "🚀 Running test suite..."
      chmod +x start_tests.sh
      ./start_tests.sh 2>&1 | tee "${TMP_DIR:-/tmp}/test-execution.log"
      TEST_EXIT_CODE=${PIPESTATUS[0]}
    else
      fail "❌ start_tests.sh not found"
    fi
  else
    fail "❌ Invalid test type: $TEST_TYPE"
  fi

  TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}
  echo "ℹ️ Test script exited with code: $TEST_EXIT_CODE"
  echo "✅ Test execution completed"

  return "$TEST_EXIT_CODE"
}