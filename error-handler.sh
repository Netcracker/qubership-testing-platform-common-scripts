#!/bin/bash

# Centralized error handler for graceful pod termination.
# Always exits with code 0 so Argo does not hang, while propagating
# failure status to downstream pipeline stages via an error-state JSON
# written to S3 (the same path that stage 4 "get ATP report file" reads).

fail() {
    local error_message="${1:-Unknown error}"
    echo "❌ FATAL: $error_message"
    echo "⚠️  Writing error-state JSON and exiting with code 0 to prevent pod hang."

    local output_dir="/tmp/clone/scripts/email-notification-generated"
    local output_file="$output_dir/email-notification2-results-generated.json"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S UTC')"
    local execution_date
    execution_date="$(date '+%Y-%m-%d %H:%M:%S')"

    mkdir -p "$output_dir"

    # Write a minimal error-state JSON that matches the schema consumed by
    # the downstream "get ATP report file" pipeline stage.
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
  "error": "$error_message"
}
EOF

    echo "📄 Error JSON written to: $output_file"

    # Best-effort S3 upload — skip silently if credentials are unavailable.
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ] || [ -n "${_LOCAL_S3_KEY:-}" ]; then
        local results_s3_path="s3://${ATP_STORAGE_BUCKET}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
        local dest="${results_s3_path}email-notification-generated/email-notification-results-generated.json"

        # Restore credentials if they were cleared before this call.
        local upload_key="${AWS_ACCESS_KEY_ID:-$_LOCAL_S3_KEY}"
        local upload_secret="${AWS_SECRET_ACCESS_KEY:-$_LOCAL_S3_SECRET}"

        echo "📤 Uploading error JSON to S3: $dest"
        if [[ "${ATP_STORAGE_PROVIDER:-}" == "aws" ]]; then
            AWS_ACCESS_KEY_ID="$upload_key" AWS_SECRET_ACCESS_KEY="$upload_secret" \
                s5cmd --no-verify-ssl cp "$output_file" "$dest" 2>/dev/null || \
                echo "⚠️  S3 upload failed (non-fatal)."
        elif [[ "${ATP_STORAGE_PROVIDER:-}" == "minio" || "${ATP_STORAGE_PROVIDER:-}" == "s3" ]]; then
            AWS_ACCESS_KEY_ID="$upload_key" AWS_SECRET_ACCESS_KEY="$upload_secret" \
                s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" cp "$output_file" "$dest" 2>/dev/null || \
                echo "⚠️  S3 upload failed (non-fatal)."
        else
            echo "⚠️  ATP_STORAGE_PROVIDER not set or unrecognised — skipping S3 upload."
        fi
    else
        echo "⚠️  No S3 credentials available — skipping S3 upload (error visible in pod logs only)."
    fi

    echo "🏁 Exiting with code 0 to allow Argo to continue pipeline."
    exit 0
}
