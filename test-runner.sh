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
        echo "❌ upload-monitor.sh not found!"
        exit 1
    fi
    
    # Create Allure results directory
    echo "📁 Creating Allure results directory..."
    mkdir -p "$TMP_DIR"/allure-results

    # Clear sensitive variables before tests
    echo "🔐 Clearing sensitive environment variables before tests..."
    clear_sensitive_vars

    # Execute test suite
    echo "🚀 Running test suite..."

    if [ -f "./start_tests.sh" ]; then
        chmod +x ./start_tests.sh
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
  echo "🔧 TEST_PARAMS: ${TEST_PARAMS:-<empty>}"
  echo "${TEST_PARAMS:-{}}" > /tmp/test_params.json

  BRUNO_ENV=$(jq -r '.env // empty' /tmp/test_params.json)
  if [ -z "$BRUNO_ENV" ]; then
    echo "❌ TEST_PARAMS.env is required for Bruno auto-run"
    return 1
  fi
  echo "🔧 Using Bruno environment: $BRUNO_ENV"

  # Список коллекций
  mapfile -t COLLECTIONS < <(jq -r '.collections[]? // empty' /tmp/test_params.json)
  if [ ${#COLLECTIONS[@]} -eq 0 ]; then
    echo "❌ No collections provided in TEST_PARAMS"
    return 1
  fi

  # Флаги
  BRUNO_FLAGS=$(jq -r '.flags[]? // empty' /tmp/test_params.json | xargs)

  # Дополнительные env_vars → в окружение
  while IFS="=" read -r KEY VALUE; do
    [ -z "$KEY" ] && continue
    export "$KEY"="$VALUE"
  done < <(jq -r '.env_vars // {} | to_entries[] | "\(.key)=\(.value)"' /tmp/test_params.json)
  echo "✅ Env variables loaded from TEST_PARAMS"

  for COL in "${COLLECTIONS[@]}"; do
    echo "▶ bru run $COL --env $BRUNO_ENV $BRUNO_FLAGS"
    bru run "$COL" --env "$BRUNO_ENV" $BRUNO_FLAGS || return 1
  done
  echo "✅ Bruno tests completed successfully"
}