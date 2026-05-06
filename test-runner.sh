#!/bin/bash

run_tests() {
  log "▶ Starting test execution..."

  # shellcheck disable=SC1091
  if [ -f "/app/scripts/upload-monitor.sh" ]; then
    source "/app/scripts/upload-monitor.sh"
  elif [ -f "/scripts/upload-monitor.sh" ]; then
    source "/scripts/upload-monitor.sh"
  else
    fail "upload-monitor.sh not found"
  fi

  log "📁 Creating Allure results directory..."
  mkdir -p "$TMP_DIR/allure-results"

  log "🔐 Clearing sensitive environment variables before tests..."
  clear_sensitive_vars

   # Generate trace id
    if command -v generate_trace_id > /dev/null 2>&1; then
        generate_trace_id
    else
        log "❌ generate_trace_id not found!"
        if [ -f "/app/scripts/trace-init.sh" ]; then
            source "/app/scripts/trace-init.sh"
            generate_trace_id
        else
            log "❌ trace-init.sh not found!"
        fi
        log "Skipping trace id generation..."
    fi

    # Bootstrap OTel SDK for all Node.js processes so trace headers are propagated
    # on outgoing HTTP requests.  Must be set after generate_trace_id so TRACEPARENT
    # is already exported.  The ${NODE_OPTIONS:+ ...} idiom preserves any existing
    # NODE_OPTIONS value set by the caller.
    export NODE_OPTIONS="--require /app/tracing.js${NODE_OPTIONS:+ $NODE_OPTIONS}"
    log "OTel tracing bootstrap configured via NODE_OPTIONS"

    # Execute test suite
  log "🚀 Running test suite..."

  if [ -f "./start_tests.sh" ]; then
    log "🚀 Running test suite..."
    chmod +x start_tests.sh
    ./start_tests.sh || TEST_EXIT_CODE=$?

    TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}
    if [ $TEST_EXIT_CODE -ne 0 ]; then
        fail "Test suite failed with code: $TEST_EXIT_CODE"
    else
        log "✅ Test suite completed successfully"
    fi
  elif [ -d "./collections" ]; then
    log "ℹ️ collections/ detected — running Bruno runner"
    run_bruno_from_test_params
    TEST_EXIT_CODE=$?
    if [ $TEST_EXIT_CODE -ne 0 ]; then
      fail "Bruno runner failed with code: $TEST_EXIT_CODE"
    fi
  else
    log "❌ Neither start_tests.sh nor collections/ directory found"
    exit 1
  fi

  TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}
  log "ℹ️ Test script exited with code: $TEST_EXIT_CODE"
  log "✅ Test execution completed"

  return "$TEST_EXIT_CODE"
}