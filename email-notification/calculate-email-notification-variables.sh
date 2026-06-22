#!/bin/bash

# Calculate Test Pass Rate from Allure Results
# 
# This script analyzes test results from allure-results directory
# and calculates the overall pass rate, then exports it as environment variable
#
# Dependencies:
# - jq (for JSON parsing)
# - bc (for floating point calculations)

# Logging functions
log_info() {
    echo "ℹ️ $1"
}

log_success() {
    echo "✅ $1"
}
# shellcheck disable=SC2329
log_warning() {
    echo "⚠️ $1"
}
# shellcheck disable=SC2329
log_error() {
    echo "❌ $1"
}
# shellcheck disable=SC2034
# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default allure-results directory (now in parent directory)
ALLURE_RESULTS_DIR="${1:-/tmp/clone/allure-results}"

# Check if allure-results directory exists
if [ ! -d "$ALLURE_RESULTS_DIR" ]; then
    log_error "Allure results directory not found: $ALLURE_RESULTS_DIR"
    return 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    log_error "jq is required but not installed. Please install jq to parse JSON files."
    return 1
fi

# Check if bc is available, if not we'll use awk for calculations
BC_AVAILABLE=false
if command -v bc &> /dev/null; then
    BC_AVAILABLE=true
fi

log_info "Analyzing test results from: $ALLURE_RESULTS_DIR"

# Initialize counters
total_tests=0
passed_tests=0
failed_tests=0
skipped_tests=0

# Initialize test details arrays
declare -a test_details=()
# Add table header
test_details+=("$(printf "%-12s" "Status") | Test Name")
test_details+=("------------ | ------------------------------------------------------------")

# Aggregate results: group retries by historyId, use latest attempt (matches Allure report)
shopt -s nullglob
result_files=("$ALLURE_RESULTS_DIR"/*-result.json)
shopt -u nullglob

if [ ${#result_files[@]} -eq 0 ]; then
    log_error "No test results found in $ALLURE_RESULTS_DIR"
    return 1
fi

aggregated_results=$(jq -s '
  group_by(
    if (.historyId // "") != "" then .historyId
    elif (.fullName // "") != "" then .fullName
    else .uuid end
  )
  | map(
      . as $group
      | ($group | max_by(.stop // .start // 0)) as $latest
      | {
          name: ($latest.name // "Unknown Test"),
          status: ($latest.status // "unknown"),
          retries: (($group | length) - 1)
        }
    )
' "${result_files[@]}")

while IFS= read -r test_row; do
    status=$(jq -r '.status' <<< "$test_row")
    test_name=$(jq -r '.name' <<< "$test_row")
    retries=$(jq -r '.retries' <<< "$test_row")
    test_name=$(printf '%s' "$test_name" | jq -R .)
    test_name=${test_name:1:-1}

    retry_label=""
    if [ "$retries" -gt 0 ]; then
        if [ "$retries" -eq 1 ]; then
            retry_label=" (1 retry)"
        else
            retry_label=" ($retries retries)"
        fi
        log_info "Collapsed $retries retry attempt(s) for: $test_name"
    fi

    case "$status" in
        "passed")
            passed_tests=$((passed_tests + 1))
            log_success "✓ $test_name$retry_label"
            test_details+=("✅ PASSED$retry_label | $test_name")
            ;;
        "failed")
            failed_tests=$((failed_tests + 1))
            log_error "✗ $test_name$retry_label"
            test_details+=("❌ FAILED$retry_label | $test_name")
            ;;
        "skipped")
            skipped_tests=$((skipped_tests + 1))
            log_warning "⚠ $test_name$retry_label"
            test_details+=("⚠️ SKIPPED$retry_label | $test_name")
            ;;
        *)
            log_warning "? $test_name (status: $status)$retry_label"
            test_details+=("❓ UNKNOWN$retry_label | $test_name")
            ;;
    esac

    total_tests=$((total_tests + 1))
done < <(jq -c '.[]' <<< "$aggregated_results")

# Calculate pass rate
if [ $total_tests -eq 0 ]; then
    log_error "No test results found in $ALLURE_RESULTS_DIR"
    return 1
fi

# Calculate pass rate as percentage (passed / total * 100)
if [ "$BC_AVAILABLE" = true ]; then
    pass_rate=$(echo "scale=2; $passed_tests * 100 / $total_tests" | bc)
    pass_rate_rounded=$(echo "scale=0; $passed_tests * 100 / $total_tests" | bc)
else
    # Use awk for calculations if bc is not available
    pass_rate=$(awk -v p="$passed_tests" -v t="$total_tests" \
    'BEGIN { if (t > 0) printf "%.2f", p * 100 / t; else print "0.00" }')
    pass_rate_rounded=$(awk -v p="$passed_tests" -v t="$total_tests" \
    'BEGIN { if (t > 0) printf "%.0f", p * 100 / t; else print "0" }')
fi

# Determine overall status
if [ "$pass_rate_rounded" -eq 100 ]; then
    overall_status="PASSED"
elif [ "$pass_rate_rounded" -ge 80 ]; then
    overall_status="PARTIAL"
else
    overall_status="FAILED"
fi

# Export results as environment variables
export TEST_PASS_RATE="$pass_rate"
export TEST_PASS_RATE_ROUNDED="$pass_rate_rounded"
export TEST_TOTAL_COUNT="$total_tests"
export TEST_PASSED_COUNT="$passed_tests"
export TEST_FAILED_COUNT="$failed_tests"
export TEST_SKIPPED_COUNT="$skipped_tests"
export TEST_OVERALL_STATUS="$overall_status"

# Create test details string
TEST_DETAILS_STRING=""
for test_detail in "${test_details[@]}"; do
    if [ -n "$TEST_DETAILS_STRING" ]; then
        TEST_DETAILS_STRING="$TEST_DETAILS_STRING\n$test_detail"
    else
        TEST_DETAILS_STRING="$test_detail"
    fi
done

# Display summary
echo ""
log_info "=== Test Results Summary ==="
echo "Overall Status: $overall_status"
echo "Pass Rate: ${pass_rate}%"
echo "Total Tests: $total_tests"
echo "Passed: $passed_tests"
echo "Failed: $failed_tests"
echo "Skipped: $skipped_tests"
echo ""

# Export variables for use in other scripts
log_info "Environment variables exported:"
echo "TEST_PASS_RATE=$pass_rate"
echo "TEST_PASS_RATE_ROUNDED=$pass_rate_rounded"
echo "TEST_TOTAL_COUNT=$total_tests"
echo "TEST_PASSED_COUNT=$passed_tests"
echo "TEST_FAILED_COUNT=$failed_tests"
echo "TEST_SKIPPED_COUNT=$skipped_tests"
echo "TEST_OVERALL_STATUS=$overall_status"
echo "TEST_DETAILS_STRING=<multiline string with test details>"

log_success "Pass rate calculation completed successfully"
