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

  echo "📍 Current working directory: $(pwd)"
  echo "📍 TMP_DIR: $TMP_DIR"
  echo "🔧 Bruno version: $(bru --version 2>/dev/null || echo 'not found')"
  echo "🔧 Node version: $(node --version)"
  echo "🔧 NPM version: $(npm --version)"
  echo ""

  if ! echo "$TEST_PARAMS" | jq . >/dev/null 2>&1; then
    echo "❌ TEST_PARAMS is not valid JSON"
    return 1
  fi

  echo "$TEST_PARAMS" | jq . > /tmp/test_params.json

  BRUNO_ENV=$(jq -r '.env // empty' /tmp/test_params.json)
  if [ -z "$BRUNO_ENV" ]; then
    echo "❌ TEST_PARAMS.env is required"
    return 1
  fi

  echo "🔧 Using Bruno environment: $BRUNO_ENV"

  mapfile -t COLLECTIONS < <(jq -r '.collections[]? // empty' /tmp/test_params.json)
  if [ ${#COLLECTIONS[@]} -eq 0 ]; then
    echo "❌ No collections provided"
    return 1
  fi

  BRUNO_FLAGS=$(jq -r '.flags[]? // empty' /tmp/test_params.json | xargs)


  echo "🔄 Syncing EnvGene variables to Bruno..."

  BRIDGE_VARS=(
    PUBLIC_GATEWAY_URL
    PRIVATE_GATEWAY_URL
    INTERNAL_GATEWAY_URL
    OPENSEARCH_URL
    HUAWEI_URL
    MONITORING_ALARM_ENGINE_URL
    KAFKA_PLATFORM_URL
  )

  for var in "${BRIDGE_VARS[@]}"; do
    value=$(printenv "$var")
    if [ -n "$value" ]; then
      bru set env "$var" "$value" --env "$BRUNO_ENV" >/dev/null 2>&1

      lower=$(echo "$var" | tr '[:upper:]' '[:lower:]')
      bru set env "$lower" "$value" --env "$BRUNO_ENV" >/dev/null 2>&1

      echo "   ✔ $var synced (with lowercase alias)"
    fi
  done

  echo ""

  for COL in "${COLLECTIONS[@]}"; do

    echo "--------------------------------------------------"
    echo "🚀 Running collection: $COL"

    if [ ! -d "$COL" ]; then
      echo "❌ Collection not found: $COL"
      return 1
    fi

    (
      cd "$COL" || exit 1
      bru run . --env "$BRUNO_ENV" $BRUNO_FLAGS --verbose
    ) || return 1

  done

  echo "✅ Bruno tests completed successfully"
}