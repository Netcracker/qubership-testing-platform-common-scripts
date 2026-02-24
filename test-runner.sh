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
  echo "📍 Listing root directory:"
  ls -la
  echo "📍 Listing collections directory:"
  ls -la ./collections 2>/dev/null || echo "⚠️ collections directory not found"
  echo "🔧 Bruno version:"
  bru --version || echo "⚠️ Bruno not found"
  echo "🔧 Node version:"
  node --version
  echo "🔧 NPM version:"
  npm --version
  echo ""

  echo "🔧 TEST_PARAMS raw:"
  echo "${TEST_PARAMS:-<empty>}"

  printf "%s" "${TEST_PARAMS:-{}}" > /tmp/test_params.json

  echo "🔎 Parsed TEST_PARAMS:"
  cat /tmp/test_params.json
  echo ""

  BRUNO_ENV=$(jq -r '.env // empty' /tmp/test_params.json)
  if [ -z "$BRUNO_ENV" ]; then
    echo "❌ TEST_PARAMS.env is required for Bruno auto-run"
    return 1
  fi
  echo "🔧 Using Bruno environment: $BRUNO_ENV"

  mapfile -t COLLECTIONS < <(jq -r '.collections[]? // empty' /tmp/test_params.json)
  if [ ${#COLLECTIONS[@]} -eq 0 ]; then
    echo "❌ No collections provided in TEST_PARAMS"
    return 1
  fi

  BRUNO_FLAGS=$(jq -r '.flags[]? // empty' /tmp/test_params.json | xargs)

  while IFS="=" read -r KEY VALUE; do
    [ -z "$KEY" ] && continue
    export "$KEY"="$VALUE"
  done < <(jq -r '.env_vars // {} | to_entries[] | "\(.key)=\(.value)"' /tmp/test_params.json)

  echo "✅ Env variables loaded from TEST_PARAMS"
  echo ""

  for COL in "${COLLECTIONS[@]}"; do

    echo "--------------------------------------------------"
    echo "🔎 Checking collection: $COL"

    if [ -d "$COL" ]; then
      echo "✅ Collection directory exists"
      echo "📍 Full path: $(realpath "$COL")"
    else
      echo "❌ Collection directory NOT FOUND"
      echo "📂 Available directories:"
      ls -R .
      return 1
    fi

    echo "📂 Collection structure (max depth 3):"
    find "$COL" -maxdepth 3 -type f

    ENV_FILE="$COL/environments/$BRUNO_ENV.bru"
    echo ""
    echo "🔎 Checking environment file: $ENV_FILE"

    if [ -f "$ENV_FILE" ]; then
      echo "✅ Environment file exists"
      echo "----- ENV FILE START -----"
      cat "$ENV_FILE"
      echo "----- ENV FILE END -----"
    else
      echo "❌ Environment file NOT FOUND"
      echo "📂 Available env files:"
      find "$COL/environments" -type f 2>/dev/null || echo "No environments folder"
      return 1
    fi

    echo ""
    echo "🚀 Executing:"
    echo "cd \"$COL\" && bru run . --env \"$BRUNO_ENV\" $BRUNO_FLAGS --verbose"
    echo ""

    (
      cd "$COL" || exit 1
      bru run . --env "$BRUNO_ENV" $BRUNO_FLAGS --verbose
    ) || return 1
   

  done

  echo "✅ Bruno tests completed successfully"
}