#!/bin/bash

# Test execution module
run_tests() {
    echo "▶ Starting test execution..."
    
    # Import upload monitoring module for security functions
    # A temporary solution: after moving all runner files to the app directory, you need to delete /scripts/upload-monitor.sh in all runners and leave only /app/scripts/upload-monitor.sh
    # shellcheck disable=1091
    if [ -f "/app/scripts/upload-monitor.sh" ]; then
        source "/app/scripts/upload-monitor.sh"
    elif [ -f "/scripts/upload-monitor.sh" ]; then
        source "/scripts/upload-monitor.sh"
    else
        fail "upload-monitor.sh not found"
    fi
    
    # Create Allure results directory
    echo "📁 Creating Allure results directory..."
    mkdir -p "$TMP_DIR"/allure-results

    # Clear sensitive variables before tests
    echo "🔐 Clearing sensitive environment variables before tests..."
    clear_sensitive_vars

    # Execute test suite
    echo "🚀 Running test suite..."
    chmod +x start_tests.sh
    ./start_tests.sh || TEST_EXIT_CODE=$?

    TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}
    if [ $TEST_EXIT_CODE -ne 0 ]; then
        fail "Test suite failed with code: $TEST_EXIT_CODE"
    else
        echo "✅ Test suite completed successfully"
    fi
} 