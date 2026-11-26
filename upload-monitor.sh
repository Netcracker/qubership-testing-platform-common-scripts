#!/bin/bash

# Event-based upload monitoring module
#
# Supported ATP_STORAGE_PROVIDER values:
#   aws   - Amazon S3 (default endpoint)
#   minio - MinIO (custom endpoint, MinIO-style UI links)
#   s3    - generic S3-compatible storage (custom endpoint, MinIO-style UI links)
#   gcs   - Google Cloud Storage through the S3-compatible (HMAC) API;
#           UI links point to the Google Cloud console
#
# Extra variables:
#   DEBUG_MODE=true | STORAGE_DEBUG=true  - verbose s5cmd output (nothing is discarded)
#   STORAGE_PREFLIGHT=true                - upload a tiny probe file before the tests start
#   ATP_STORAGE_GCS_PROJECT               - optional, appended to GCS console links (?project=...)
#   ATP_STORAGE_GCS_CONSOLE_URL           - optional, overrides the GCS console base URL

# True for providers that talk to a custom S3-compatible endpoint
_storage_uses_endpoint() {
    case "${ATP_STORAGE_PROVIDER:-}" in
        minio|s3|gcs) return 0 ;;
        *) return 1 ;;
    esac
}

_storage_debug() {
    [[ "${DEBUG_MODE:-false}" == "true" || "${STORAGE_DEBUG:-false}" == "true" ]]
}

# Single entry point for every s5cmd call. Credentials come from the environment
# (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY), the caller sets them per call.
# Errors are always printed (stderr); regular output is hidden unless debug is on.
_storage_s5cmd() {
    local -a args=(--no-verify-ssl)
    local rc

    case "${ATP_STORAGE_PROVIDER:-}" in
        aws) ;;
        minio|s3|gcs) args+=(--endpoint-url "${ATP_STORAGE_SERVER_URL:-}") ;;
        *)
            echo "❌ Unsupported ATP_STORAGE_PROVIDER='${ATP_STORAGE_PROVIDER:-}' (expected: aws, minio, s3, gcs). Nothing is uploaded: s5cmd $1 ${*:2}" >&2
            return 1
            ;;
    esac

    if _storage_debug; then
        args+=(--log debug)
        echo "🔎 s5cmd ${args[*]} $*" >&2
        s5cmd "${args[@]}" "$@"
        rc=$?
    else
        s5cmd "${args[@]}" "$@" > /dev/null
        rc=$?
    fi

    if [[ $rc -ne 0 ]]; then
        echo "❌ s5cmd $1 failed (rc=$rc): ${*:2}" >&2
        if [[ "${ATP_STORAGE_PROVIDER:-}" == "gcs" ]]; then
            echo "💡 GCS hint: SignatureDoesNotMatch => check the HMAC access key/secret (ATP_STORAGE_USERNAME/PASSWORD); AccessDenied => the HMAC service account needs write access to bucket '${ATP_STORAGE_BUCKET:-}'." >&2
        fi
    fi
    return $rc
}

# Prints the effective storage configuration (no secrets) and warns about typical mistakes
log_storage_config() {
    local key="${_LOCAL_S3_KEY:-}"
    local secret="${_LOCAL_S3_SECRET:-}"

    echo "☁️ Storage configuration:"
    echo "   provider      = ${ATP_STORAGE_PROVIDER:-<unset>}"
    echo "   endpoint      = ${ATP_STORAGE_SERVER_URL:-<default>}"
    echo "   bucket        = ${ATP_STORAGE_BUCKET:-<unset>}"
    echo "   region        = ${AWS_REGION:-<empty>}"
    echo "   environment   = ${ENVIRONMENT_NAME:-}"
    echo "   access key    = length ${#key}$([[ "$key" == GOOG1* ]] && echo ', GOOG1* (HMAC format)')"
    echo "   secret key    = length ${#secret}"
    echo "   debug output  = $(_storage_debug && echo on || echo off)"

    if [[ "$key" =~ [[:space:]] || "$secret" =~ [[:space:]] ]]; then
        echo "⚠️ Access key or secret contains whitespace/newline characters: signature errors are expected"
    fi

    if [[ "${ATP_STORAGE_PROVIDER:-}" == "gcs" ]]; then
        if [[ "${ATP_STORAGE_SERVER_URL:-}" != "https://storage.googleapis.com" ]]; then
            echo "⚠️ GCS: ATP_STORAGE_SERVER_URL is '${ATP_STORAGE_SERVER_URL:-}', expected https://storage.googleapis.com"
        fi
        if [[ "$key" != GOOG1* ]]; then
            echo "⚠️ GCS: access key does not start with 'GOOG1' - it is probably not an HMAC key (Cloud Storage > Settings > Interoperability)"
        fi
        if [[ ${#secret} -ne 40 ]]; then
            echo "⚠️ GCS: HMAC secret is normally 40 characters, got ${#secret}"
        fi
    fi
}

# Optional (STORAGE_PREFLIGHT=true): upload a tiny file to fail fast and visibly on bad credentials
_storage_preflight() {
    local probe="$TMP_DIR/.storage-preflight.txt"
    echo "preflight $(date -u +%FT%TZ)" > "$probe"
    echo "🧪 Storage preflight: uploading probe to ${RESULTS_S3_PATH}preflight.txt"
    if AWS_ACCESS_KEY_ID="$_LOCAL_S3_KEY" AWS_SECRET_ACCESS_KEY="$_LOCAL_S3_SECRET" \
        _storage_s5cmd cp "$probe" "${RESULTS_S3_PATH}preflight.txt"; then
        echo "✅ Storage preflight passed: credentials, endpoint and bucket permissions are OK"
    else
        echo "❌ Storage preflight FAILED: uploads during this run will fail the same way"
    fi
    rm -f "$probe"
}

start_upload_monitoring() {
    # Storage not configured (local run): keep results in TMP_DIR, no uploaders
    if ! storage_enabled; then
        mkdir -p "$TMP_DIR/allure-results" "$TMP_DIR/attachments"
        echo "ℹ️ Skipping upload monitoring: S3 storage is not configured"
        return 0
    fi

    echo "📡 Starting event-based upload monitoring..."

    # Prepare common S3 paths
    RESULTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    REPORTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    ATTACHMENTS_S3_PATH="${REPORTS_S3_PATH}attachments/"

    # Create attachments directory
    mkdir -p "$TMP_DIR/allure-results"
    mkdir -p "$TMP_DIR/attachments"

    # Store credentials for background processes (local variables, not exported)
    _BACKGROUND_S3_KEY="$_LOCAL_S3_KEY"
    _BACKGROUND_S3_SECRET="$_LOCAL_S3_SECRET"

    log_storage_config
    if ! _storage_uses_endpoint && [[ "${ATP_STORAGE_PROVIDER:-}" != "aws" ]]; then
        echo "❌ Unsupported ATP_STORAGE_PROVIDER='${ATP_STORAGE_PROVIDER:-}' (expected: aws, minio, s3, gcs): files will NOT be uploaded"
    fi
    echo "   results path  = ${RESULTS_S3_PATH}"
    echo "   reports path  = ${REPORTS_S3_PATH}"

    if [[ "${STORAGE_PREFLIGHT:-false}" == "true" ]]; then
        _storage_preflight
    fi

    # Choose upload method based on environment variable
    if [[ "${UPLOAD_METHOD:-cp}" == "sync" ]]; then
        echo "🔄 Using sync-based upload monitoring (inotifywait + sync)"
        start_sync_uploader "$TMP_DIR/allure-results" "${RESULTS_S3_PATH}allure-results/" "*result.json" &
        start_sync_uploader "$TMP_DIR/attachments" "$ATTACHMENTS_S3_PATH" &
    else
        echo "📁 Using file-based upload monitoring (inotifywait + cp)"
        start_inotify_uploader "$TMP_DIR/allure-results" "${RESULTS_S3_PATH}allure-results/" "*result.json" &
        start_inotify_uploader "$TMP_DIR/attachments" "$ATTACHMENTS_S3_PATH" &
    fi

    echo "✅ Upload monitoring started"
}

# Inotify uploader function
start_inotify_uploader() {
    WATCH_DIR="$1"
    DEST_PATH="$2"
    FILE_PATTERN="${3:-*}"  # Optional filename filter (e.g. *result.json)

    echo "📡 Starting inotify uploader for $WATCH_DIR => $DEST_PATH (filter: $FILE_PATTERN)"

    # Pass credentials as environment variables only for this process
    inotifywait -m -e close_write,create --format '%w%f' "$WATCH_DIR" | while read -r NEW_FILE; do
        FILE_NAME=$(basename "$NEW_FILE")
        # FILE_PATTERN is a glob such as *result.json; quoting it would match literally.
        # shellcheck disable=SC2254
        case "$FILE_NAME" in
            $FILE_PATTERN)
                echo "🆕 Matching file: $FILE_NAME"
                upload_file_to_s3 "$NEW_FILE" "$DEST_PATH"
                ;;
            *)
                echo "⚠️ Ignored file: $FILE_NAME"
                ;;
        esac
    done &

    # Store the background process PID
    INOTIFY_PID=$!
    echo "📡 Inotify process started with PID: $INOTIFY_PID"
}

# Upload file to S3/MinIO/GCS
upload_file_to_s3() {
    local FILE_PATH="$1"
    local DEST_PATH="$2"

    # Use background credentials for upload
    if AWS_ACCESS_KEY_ID="$_BACKGROUND_S3_KEY" AWS_SECRET_ACCESS_KEY="$_BACKGROUND_S3_SECRET" \
        _storage_s5cmd cp "$FILE_PATH" "$DEST_PATH"; then
        echo "⬆️ Uploaded: $(basename "$FILE_PATH")"
    else
        echo "⚠️ Upload failed: $(basename "$FILE_PATH") => $DEST_PATH"
        return 1
    fi
}

# Sync-based uploader function (triggered by inotifywait)
start_sync_uploader() {
    WATCH_DIR="$1"
    DEST_PATH="$2"
    FILE_PATTERN="${3:-*}"  # Optional filename filter

    echo "🔄 Starting sync uploader for $WATCH_DIR => $DEST_PATH (filter: $FILE_PATTERN)"

    # Pass credentials as environment variables only for this process
    inotifywait -m -e close_write,create --format '%w%f' "$WATCH_DIR" | while read -r NEW_FILE; do
        FILE_NAME=$(basename "$NEW_FILE")
        # FILE_PATTERN is a glob such as *result.json; quoting it would match literally.
        # shellcheck disable=SC2254
        case "$FILE_NAME" in
            $FILE_PATTERN)
                echo "🆕 Matching file: $FILE_NAME - triggering sync"
                sync_directory_to_s3 "$WATCH_DIR" "$DEST_PATH"
                ;;
        esac
    done &

    # Store the background process PID
    SYNC_PID=$!
    echo "🔄 Sync process started with PID: $SYNC_PID"
}

# Sync directory to S3/MinIO/GCS
sync_directory_to_s3() {
    local SOURCE_DIR="$1"
    local DEST_PATH="$2"

    # Use background credentials for sync
    if AWS_ACCESS_KEY_ID="$_BACKGROUND_S3_KEY" AWS_SECRET_ACCESS_KEY="$_BACKGROUND_S3_SECRET" \
        _storage_s5cmd sync "$SOURCE_DIR/" "$DEST_PATH"; then
        echo "🔄 Synced: $SOURCE_DIR/ => $DEST_PATH"
    else
        echo "⚠️ Sync failed: $SOURCE_DIR/ => $DEST_PATH"
        return 1
    fi
}

# Finalize upload after tests
finalize_upload() {
    # Storage not configured (local run): nothing to upload, keep results locally.
    # Use the flag computed in init_environment: storage_enabled() would always be
    # false here because clear_sensitive_vars already unset the credentials.
    if [[ "${ATP_STORAGE_ENABLED:-false}" != "true" ]]; then
        echo "ℹ️ S3 storage is not configured: skipping upload. Results are kept locally:"
        echo "   Allure results: ${TMP_DIR}/allure-results"
        echo "   Attachments:    ${TMP_DIR}/attachments"
        final_cleanup
        return 0
    fi

    echo "🔄 Finalizing upload operations..."

    # Prepare common S3 paths
    RESULTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    REPORTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    ATTACHMENTS_S3_PATH="${REPORTS_S3_PATH}attachments/"

    # Restore credentials for final operations
    restore_aws_credentials

    echo "🔄 Copying the remaining files to S3 (provider=${ATP_STORAGE_PROVIDER:-}, endpoint=${ATP_STORAGE_SERVER_URL:-<default>}). Please wait..."
    local failed=0

    # Final sync to ensure all files are captured
    _finalize_sync "$TMP_DIR/allure-results/" "${RESULTS_S3_PATH}allure-results/" || failed=$((failed + 1))
    _finalize_sync "$TMP_DIR/attachments/" "$ATTACHMENTS_S3_PATH" || failed=$((failed + 1))
    _finalize_sync "$TMP_DIR/scripts/email-notification-generated/" "${RESULTS_S3_PATH}email-notification-generated/" || failed=$((failed + 1))

    # Upload marker file
    echo "${ENABLE_JIRA_INTEGRATION:-false}" > "$TMP_DIR/allure-results.uploaded"
    if _storage_s5cmd cp "$TMP_DIR/allure-results.uploaded" "${RESULTS_S3_PATH}allure-results.uploaded"; then
        echo "✅ Uploaded marker: ${RESULTS_S3_PATH}allure-results.uploaded"
    else
        echo "⚠️ Failed to upload marker file allure-results.uploaded"
        failed=$((failed + 1))
    fi

    # Generate result URLs
    generate_result_urls

    # Drop bulky local artifacts so Completed Job pods (TTL up to 12h) do not
    # keep clone traces/Allure data on the node after S3 already has a copy.
    # release_ephemeral_disk

    # Final cleanup
    final_cleanup

    echo ""
    if [[ $failed -gt 0 ]]; then
        echo "❌ ${failed} upload operation(s) failed: the links below may be empty or incomplete. See the ❌/ERROR lines above."
    elif [[ -z "${RESULTS_URL:-}" ]]; then
        echo "⚠️ Result links were not generated (provider='${ATP_STORAGE_PROVIDER:-}' is not one of aws, minio, s3, gcs)"
    fi
    echo "Storage path: ${RESULTS_S3_PATH}"
    echo "Results are available at: ${RESULTS_URL}"
    echo "Reports are available at: ${REPORTS_URL}"
    echo "Report view is available at: ${ATP_REPORT_VIEW_UI_URL}/${REPORTS_FOLDER_PATH}index.html"

    echo "✅ Upload finalization completed"
    return 0
}

# Sync one local directory during finalization (skipped quietly when it does not exist)
_finalize_sync() {
    local src="$1"
    local dst="$2"

    if [[ ! -d "$src" ]]; then
        echo "ℹ️ Skip sync, directory does not exist: $src"
        return 0
    fi

    if _storage_s5cmd sync "$src" "$dst"; then
        echo "✅ Synced: $src => $dst"
    else
        echo "⚠️ Sync failed: $src => $dst"
        return 1
    fi
}

# Generate URLs for results
generate_result_urls() {
    RESULTS_FOLDER_PATH="Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/allure-results/"
    REPORTS_FOLDER_PATH="Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/allure-report/"
    RESULTS_URL=""
    REPORTS_URL=""

    case "${ATP_STORAGE_PROVIDER:-}" in
        aws)
            RESULTS_URL="${ATP_STORAGE_BUCKET}.${ATP_STORAGE_SERVER_UI_URL}/${RESULTS_FOLDER_PATH}"
            REPORTS_URL="${ATP_STORAGE_BUCKET}.${ATP_STORAGE_SERVER_UI_URL}/${REPORTS_FOLDER_PATH}"
            ;;
        minio|s3)
            # Base64-encoded paths for the MinIO UI
            RESULTS_ENCODED_PATH=$(echo -n "${RESULTS_FOLDER_PATH}" | base64)
            RESULTS_URL="${ATP_STORAGE_SERVER_UI_URL}/browser/${ATP_STORAGE_BUCKET}/${RESULTS_ENCODED_PATH}"

            REPORTS_ENCODED_PATH=$(echo -n "${REPORTS_FOLDER_PATH}" | base64)
            REPORTS_URL="${ATP_STORAGE_SERVER_UI_URL}/browser/${ATP_STORAGE_BUCKET}/${REPORTS_ENCODED_PATH}"
            ;;
        gcs)
            # Google Cloud console: <base>/<bucket>/<prefix>[?project=<id>]
            local base="${ATP_STORAGE_GCS_CONSOLE_URL:-https://console.cloud.google.com/storage/browser}"
            local suffix=""
            if [[ -n "${ATP_STORAGE_GCS_PROJECT:-}" ]]; then
                suffix="?project=${ATP_STORAGE_GCS_PROJECT}"
            fi
            RESULTS_URL="${base%/}/${ATP_STORAGE_BUCKET}/${RESULTS_FOLDER_PATH}${suffix}"
            REPORTS_URL="${base%/}/${ATP_STORAGE_BUCKET}/${REPORTS_FOLDER_PATH}${suffix}"
            ;;
    esac
    echo "🔗 Result links generated for provider '${ATP_STORAGE_PROVIDER:-}'"
}

# Clear sensitive environment variables
clear_sensitive_vars() {
    echo "🔐 Clearing sensitive environment variables..."
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset ATP_STORAGE_USERNAME
    unset ATP_STORAGE_PASSWORD
}

# Restore AWS credentials for final operations
restore_aws_credentials() {
    echo "🔑 Restoring AWS credentials for final operations..."
    export AWS_ACCESS_KEY_ID="$_LOCAL_S3_KEY"
    export AWS_SECRET_ACCESS_KEY="$_LOCAL_S3_SECRET"
}

# Final cleanup of all credentials
final_cleanup() {
    echo "🧹 Final cleanup of all credentials..."
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset _LOCAL_S3_KEY
    unset _LOCAL_S3_SECRET
    unset _BACKGROUND_S3_KEY
    unset _BACKGROUND_S3_SECRET
}
