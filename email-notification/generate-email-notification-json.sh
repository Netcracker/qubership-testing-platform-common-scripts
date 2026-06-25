#!/bin/bash

# Generate JSON Results from Test Data (Based on generate-email-notification-file.sh)
# 
# This script generates a JSON file with test results in a predefined format
# without using templates
#
# Usage: ./generate-email-notification-json.sh
# 
# Dependencies:
# - calculate-email-notification-variables.sh (for test statistics)

# Function to generate email notification JSON results
generate_email_notification_json() {
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

    # Get script directory
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Set allure results directory to default location
    local allure_results_dir="/tmp/clone/allure-results"
    
    # Create email-notification-generated directory one level up
    local output_dir="/tmp/clone/scripts/email-notification-generated"
    mkdir -p "$output_dir"
    
    local output_file="$output_dir/email-notification-results-generated.json"

    log_info "Generating JSON results file"

    # Calculate pass rate and test details
    # shellcheck source=/home/runner/work/qubership-testing-platform-common-scripts/qubership-testing-platform-common-scripts/scripts/email-notification/calculate-email-notification-variables.sh
    source "$SCRIPT_DIR/calculate-email-notification-variables.sh" "$allure_results_dir"
    unset TEST_DETAILS_STRING

    # Calculate additional metrics
    if [ -n "${TEST_TOTAL_COUNT:-}" ] && [ "$TEST_TOTAL_COUNT" -gt 0 ]; then
        TEST_FAILURE_RATE=$(awk -v failed="$TEST_FAILED_COUNT" -v total="$TEST_TOTAL_COUNT" \
        'BEGIN { if (total > 0) printf "%.2f", failed * 100 / total; else print "0.00" }')
    else
        TEST_FAILURE_RATE="0.00"
    fi

    # Set default values for optional variables
    EXECUTION_DATE="${EXECUTION_DATE:-$(date '+%Y-%m-%d %H:%M:%S')}"
    TEST_COVERAGE="${TEST_COVERAGE:-100.00}"
    ATP_REPORT_VIEW_UI_URL="${ATP_REPORT_VIEW_UI_URL:-https://example.com}"
    if [[ "${ATP_REPORT_VIEW_UI_URL}" == Test\ not\ started* ]]; then
        ALLURE_REPORT_URL="${ATP_REPORT_VIEW_UI_URL}"
    else
        ALLURE_REPORT_URL="${ATP_REPORT_VIEW_UI_URL}/Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/allure-report/index.html"
    fi
    TIMESTAMP="${TIMESTAMP:-$(date '+%Y-%m-%d %H:%M:%S UTC')}"

    log_info "Building JSON structure..."

    # stream test_details from allure files; never round-trip TEST_DETAILS_STRING
    local test_details_json
    test_details_json=$(
        find "$allure_results_dir" -maxdepth 1 -name '*-result.json' -print0 2>/dev/null |
            xargs -0 -r cat -- |
            jq -s '[
              group_by(
                if (.historyId // "") != "" then .historyId
                elif (.fullName // "") != "" then .fullName
                else .uuid end
              )
              | .[]
              | (max_by(.stop // .start // 0)) as $w
              | {
                  status: (
                    if $w.status == "passed" then "PASSED" 
                    elif $w.status == "failed" then "FAILED" 
                    elif $w.status == "skipped" then "SKIPPED" 
                    else "UNKNOWN" end
                  ),
                  test_name: $w.name,
                  retries: (length - 1),
                  emoji: (
                    if $w.status == "passed" then "✅"
                    elif $w.status == "failed" then "❌"
                    elif $w.status == "skipped" then "⚠️"
                    else "❓" end
                  )
                }
            ]' 2>/dev/null
    )
    test_details_json="${test_details_json:-[]}"

    # Build complete JSON structure
    local json_content='{
  "test_results": {
    "overall_status": "'"$TEST_OVERALL_STATUS"'",
    "pass_rate": '"$TEST_PASS_RATE"',
    "pass_rate_rounded": '"$TEST_PASS_RATE_ROUNDED"',
    "total_count": '"$TEST_TOTAL_COUNT"',
    "passed_count": '"$TEST_PASSED_COUNT"',
    "failed_count": '"$TEST_FAILED_COUNT"',
    "skipped_count": '"$TEST_SKIPPED_COUNT"',
    "failure_rate": '"$TEST_FAILURE_RATE"',
    "coverage": '"$TEST_COVERAGE"'
  },
  "execution_info": {
    "execution_date": "'"$EXECUTION_DATE"'",
    "timestamp": "'"$TIMESTAMP"'",
    "environment_name": "'"${ENVIRONMENT_NAME:-Unknown}"'",
    "atp_report_view_ui_url": "'"$ATP_REPORT_VIEW_UI_URL"'",
    "allure_report_url": "'"$ALLURE_REPORT_URL"'"
  },
  "test_details": '"$test_details_json"',
  "environment_variables": {
    "TEST_PASS_RATE": "'"$TEST_PASS_RATE"'",
    "TEST_PASS_RATE_ROUNDED": "'"$TEST_PASS_RATE_ROUNDED"'",
    "TEST_TOTAL_COUNT": "'"$TEST_TOTAL_COUNT"'",
    "TEST_PASSED_COUNT": "'"$TEST_PASSED_COUNT"'",
    "TEST_FAILED_COUNT": "'"$TEST_FAILED_COUNT"'",
    "TEST_SKIPPED_COUNT": "'"$TEST_SKIPPED_COUNT"'",
    "TEST_OVERALL_STATUS": "'"$TEST_OVERALL_STATUS"'",
    "TEST_FAILURE_RATE": "'"$TEST_FAILURE_RATE"'",
    "TEST_COVERAGE": "'"$TEST_COVERAGE"'",
    "EXECUTION_DATE": "'"$EXECUTION_DATE"'",
    "ENVIRONMENT_NAME": "'"${ENVIRONMENT_NAME:-Unknown}"'",
    "ATP_REPORT_VIEW_UI_URL": "'"$ATP_REPORT_VIEW_UI_URL"'",
    "ALLURE_REPORT_URL": "'"$ALLURE_REPORT_URL"'",
    "TIMESTAMP": "'"$TIMESTAMP"'"
  },
  "environment_variables_description": {
    "description": "Variables used in email notification json file",
    "variables": {
      "TEST_OVERALL_STATUS": "Overall test status (PASSED/PARTIAL/FAILED)",
      "TEST_PASS_RATE": "Pass rate percentage with 2 decimal places",
      "TEST_TOTAL_COUNT": "Total number of tests",
      "TEST_PASSED_COUNT": "Number of passed tests",
      "TEST_FAILED_COUNT": "Number of failed tests",
      "TEST_SKIPPED_COUNT": "Number of skipped tests",
      "TEST_FAILURE_RATE": "Failure rate percentage",
      "TEST_COVERAGE": "Test coverage percentage",
      "EXECUTION_DATE": "Test execution date and time",
      "ENVIRONMENT_NAME": "Environment name (dev/staging/prod)",
      "ATP_REPORT_VIEW_UI_URL": "Base URL for viewing reports",
      "ALLURE_REPORT_URL": "Full URL to Allure report",
      "TIMESTAMP": "Current timestamp",
      "TEST_DETAILS": "Details of all tests"
    }
  },
  "status_logic": {
    "description": "Logic for determining overall test status",
    "rules": {
      "PASSED": "100% of tests passed successfully",
      "PARTIAL": "80-99% of tests passed successfully", 
      "FAILED": "Less than 80% of tests passed successfully"
    }
  }
}'

    # Write the generated JSON to output file
    printf "%s" "$json_content" > "$output_file"

    log_success "JSON generated successfully: $output_file"


    export JSON_FILE="$output_file"

    log_info "Environment variables exported: JSON_FILE"
    
    # Return the JSON content
    # echo "$json_content"
}