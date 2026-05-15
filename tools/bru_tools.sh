#!/usr/bin/env bash

# ============================================
# Extract Bruno collections from string separated by ',' and convert them to an array
# Args:
#   $1 - Input string
#   $2 - Name of the output variable to store the result
# ============================================
extract_bruno_collections() {
    local input="$1"
    local output_var_name="$2"
    local result_array=()

    # Retrieve the array of collections and save it to a temporary array
    local result=$(echo "$input" | jq -r '.execution_list[]?.name')
    # Split the comma-separated string into an array, trimming whitespace
    if [[ -n "$result" ]]; then
        IFS=',' read -ra result_array <<< "$result"
        # Trim leading/trailing spaces for each element
        for i in "${!result_array[@]}"; do
            result_array[$i]=$(echo "${result_array[$i]}" | xargs)
        done
    fi

    # Export the array to a variable with a specified name
    q=''
    for x in "${result_array[@]}"; do
        q+=$(printf ' %q' "$x")
    done
    eval "$output_var_name=(${q# })"

    # Log the result
    local output_message="➡️ Extracted Bruno collections:"
    for collection in "${result_array[@]}"; do
        output_message+="\n    - $collection"
    done
    echo -e "$output_message"
}



# Extract Bruno folders from string separated by '|' and convert them to an array
# Args:
#   $1 - Input string
#   $2 - Name of the output variable to store the result
# ============================================
extract_bruno_folders() {
    local input="$1"
    local output_var_name="$2"
    local result_array=()

    # Split input by '|'
    if [[ -n "$input" ]]; then
        IFS='|' read -ra result_array <<< "$input"
        # Trim leading/trailing spaces
        for i in "${!result_array[@]}"; do
            result_array[$i]=$(echo "${result_array[$i]}" | xargs)
        done
    fi

    q=''
    for x in "${result_array[@]}"; do
        q+=$(printf ' %q' "$x")
    done
    eval "$output_var_name=(${q# })"

    local output_message="➡️ Extracted Bruno folders:"
    for folder in "${result_array[@]}"; do
        output_message+="\n    - $folder"
    done
    echo -e "$output_message"
}

# Return:
#   0 — if LOCAL_RUN=true
#   1 — if LOCAL_RUN=false or value not set/empty
#   2 — if incorrect value (not true, not false)
local_run_enabled() {

  local val="${LOCAL_RUN:-}"

  if [ -z "$val" ]; then
    return 1
  fi

  # reduce it to lowercase
  val="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"

  case "$val" in
    true)  return 0 ;;
    false) return 1 ;;
    *)
      printf '❌ Incorrect value LOCAL_RUN=%s (expected true/false)\n' "$LOCAL_RUN" >&2
      return 2
      ;;
  esac
}

# Local test execution module
local_run_tests() {
    cd "$TMP_DIR" || return 1

     # Create Allure results directory
    echo "▶ Starting test execution..."
    export NODE_PATH=/app/node_modules

    cp -r "$WORK_DIR/tools" "$TMP_DIR/tools"

     # Create Allure results directory
    echo "📁 Creating Allure results directory..."
    mkdir -p "$TMP_DIR/allure-results"

    # Execute test suite
    echo "🚀 Running test suite..."
    chmod +x start_tests.sh
    ./start_tests.sh || TEST_EXIT_CODE=$?

    TEST_EXIT_CODE=${TEST_EXIT_CODE:-0}
    echo "ℹ️ Test script exited with code: $TEST_EXIT_CODE (but continuing...)"
    
    echo "✅ Test execution completed"

    cd "$WORK_DIR" || return 1
}
