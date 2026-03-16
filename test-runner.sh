#!/bin/bash

# Test execution module
run_tests() {
    log "▶ Starting test execution..."
    
    # Import upload monitoring module for security functions
    # A temporary solution: after moving all runner files to the app directory, you need to delete /scripts/upload-monitor.sh in all runners and leave only /app/scripts/upload-monitor.sh
    # shellcheck disable=1091
    if [ -f "/app/scripts/upload-monitor.sh" ]; then
        source "/app/scripts/upload-monitor.sh"
    elif [ -f "/scripts/upload-monitor.sh" ]; then
        source "/scripts/upload-monitor.sh"
    else
        log "❌ upload-monitor.sh not found!"
        exit 1
    fi
    
    # Create Allure results directory
    log "📁 Creating Allure results directory..."
    mkdir -p "$TMP_DIR"/allure-results

    # Clear sensitive variables before tests
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
    chmod +x start_tests.sh
    ./start_tests.sh || TEST_EXIT_CODE=$?

    TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}
    log "ℹ️ Test script exited with code: $TEST_EXIT_CODE (but continuing...)"
    
    log "✅ Test execution completed"
} 
