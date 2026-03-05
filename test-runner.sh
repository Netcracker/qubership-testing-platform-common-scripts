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

    # Execute test suite
    log "🚀 Running test suite..."
    chmod +x start_tests.sh
    ./start_tests.sh || TEST_EXIT_CODE=$?

    TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}
    log "ℹ️ Test script exited with code: $TEST_EXIT_CODE (but continuing...)"
    
    log "✅ Test execution completed"
} 
