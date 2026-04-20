#!/bin/bash

# Centralized error handler and exit-trap for graceful pod termination.
#
# fail()         — logs the error, stores its message, and exits 1.
# finalize_once() — the single EXIT trap: writes error-state JSON when rc≠0,
#                   runs all cleanup, then always exits 0 so Argo does not hang.
#
# Register the trap in entrypoint.sh AFTER all scripts are sourced:
#   trap 'finalize_once' EXIT

# Stores the fatal error message so finalize_once can embed it in the error JSON.
FAIL_MESSAGE=""
FINALIZE_DONE=false

fail() {
    local error_message="${1:-Unknown error}"
    echo "❌ FATAL: $error_message"
    echo "⚠️  Delegating cleanup to EXIT trap (finalize_once)."
    FAIL_MESSAGE="$error_message"
    exit 1
}

#shellcheck disable=SC2329
finalize_once() {
  local rc=$?

  if [ "$FINALIZE_DONE" != "true" ]; then
    FINALIZE_DONE=true
    echo "🔄 EXIT trap triggered with rc=$rc"

    set +e

    # When fail() triggered the exit, write a minimal error-state JSON so
    # downstream pipeline stages (e.g. "get ATP report file") receive a valid
    # FAILED payload instead of finding no file at all.
    if [ "$rc" -ne 0 ]; then
      echo "⚠️  Non-zero exit detected — writing error-state JSON before cleanup."
      local output_dir="/tmp/clone/scripts/email-notification-generated"
      local output_file="$output_dir/email-notification-results-generated.json"
      local timestamp
      timestamp="$(date '+%Y-%m-%d %H:%M:%S UTC')"
      local execution_date
      execution_date="$(date '+%Y-%m-%d %H:%M:%S')"
      mkdir -p "$output_dir"
      cat > "$output_file" <<EOF
{
  "test_results": {
    "overall_status": "FAILED",
    "pass_rate": 0,
    "pass_rate_rounded": 0,
    "total_count": 0,
    "passed_count": 0,
    "failed_count": 0,
    "skipped_count": 0,
    "failure_rate": 0,
    "coverage": 0
  },
  "execution_info": {
    "execution_date": "$execution_date",
    "timestamp": "$timestamp",
    "environment_name": "${ENVIRONMENT_NAME:-Unknown}",
    "atp_report_view_ui_url": "${ATP_REPORT_VIEW_UI_URL:-}",
    "allure_report_url": ""
  },
  "test_details": [],
  "error": "${FAIL_MESSAGE:-Unknown error}"
}
EOF
      echo "📄 Error-state JSON written to: $output_file"
    fi

    generate_email_notification_json || true
    save_native_report "$TMP_DIR/${NATIVE_REPORT_DIR:-playwright-report}" || true
    finalize_upload || true
    sleep 15

    set -e
  fi

  # Always exit 0 so Argo/Kubernetes does not treat this pod as failed and hang.
  exit 0
}
