#!/bin/bash

# Reject Bruno collection dispatch on Playwright runner images.
# Identity comes from ATP_APPLICATION_VERSION (e.g. atp3-playwright-runner:1.1.11-...).
assert_collection_allowed_for_runner() {
  case "${ATP_APPLICATION_VERSION:-}" in
    atp3-playwright-runner:*)
      fail "use bruno to run collection (runner: ${ATP_APPLICATION_VERSION})"
      ;;
  esac
}

run_tests() {
  echo "▶ Starting test execution..."

  # shellcheck disable=SC1091
  if [ -f "/app/scripts/upload-monitor.sh" ]; then
    source "/app/scripts/upload-monitor.sh"
  elif [ -f "/scripts/upload-monitor.sh" ]; then
    source "/scripts/upload-monitor.sh"
  elif [ -n "${UPLOAD_MONITOR_SCRIPT:-}" ] && [ -f "$UPLOAD_MONITOR_SCRIPT" ]; then
    # Optional override for unit tests (writable path outside the image layout).
    # shellcheck disable=SC1090
    source "$UPLOAD_MONITOR_SCRIPT"
  else
    fail "upload-monitor.sh not found"
  fi

  extract_test_type "$TEST_PARAMS" "TEST_TYPE"

  echo "📁 Creating Allure results directory..."
  mkdir -p "$TMP_DIR/allure-results"
  # allure-playwright writes ./allure-results under PROJECT_DIR CWD
  if [ -n "${PROJECT_DIR:-}" ] && [ "$PROJECT_DIR" != "$TMP_DIR" ]; then
    rm -rf "$PROJECT_DIR/allure-results"
    ln -s "$TMP_DIR/allure-results" "$PROJECT_DIR/allure-results"
  fi

  echo "🔐 Clearing sensitive environment variables before tests..."
  clear_sensitive_vars

  if [ "$TEST_TYPE" = "collection" ]; then
    assert_collection_allowed_for_runner
    if [ -d "./collections" ]; then
      echo "ℹ️ collections/ detected — running Bruno runner"
      run_bruno_from_test_params || TEST_EXIT_CODE=$?
    else
      fail "❌ collections/ directory not found"
    fi

  elif [ -f "./start_tests.sh" ]; then
    echo "🚀 Running test suite..."
    chmod +x start_tests.sh
    if [ "$TEST_TYPE" = "scope" ] || [ "$TEST_TYPE" = "test" ]; then
      ./start_tests.sh 2>&1 | tee "${TMP_DIR:-/tmp}/test-execution.log"
      TEST_EXIT_CODE=${PIPESTATUS[0]}
    else
      ./start_tests.sh || TEST_EXIT_CODE=$?
    fi
  else
    fail "❌ Invalid test type: $TEST_TYPE or start_tests.sh not found"
  fi

  TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}
  echo "ℹ️ Test script exited with code: $TEST_EXIT_CODE"
  echo "✅ Test execution completed"

  return "$TEST_EXIT_CODE"
}