#!/bin/bash
# Event-based upload monitoring module
start_upload_monitoring() {
    echo "📡 Starting event-based upload monitoring..."
    
    RESULTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    REPORTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    ATTACHMENTS_S3_PATH="${REPORTS_S3_PATH}attachments/"

    mkdir -p "$TMP_DIR/allure-results"
    mkdir -p "$TMP_DIR/attachments"
    
    _BACKGROUND_S3_KEY="$_LOCAL_S3_KEY"
    _BACKGROUND_S3_SECRET="$_LOCAL_S3_SECRET"
    
    if [[ "${UPLOAD_METHOD:-cp}" == "sync" ]]; then
        start_sync_uploader "$TMP_DIR/allure-results" "${RESULTS_S3_PATH}allure-results/" "*result.json" &
        start_sync_uploader "$TMP_DIR/attachments" "$ATTACHMENTS_S3_PATH" &
    else
        start_inotify_uploader "$TMP_DIR/allure-results" "${RESULTS_S3_PATH}allure-results/" "*result.json" &
        start_inotify_uploader "$TMP_DIR/attachments" "$ATTACHMENTS_S3_PATH" &
    fi
    
    echo "✅ Upload monitoring started"
}

start_inotify_uploader() {
    WATCH_DIR="$1"
    DEST_PATH="$2"
    FILE_PATTERN="${3:-*}"

    inotifywait -m -e close_write,create --format '%w%f' "$WATCH_DIR" | while read -r NEW_FILE; do
        FILE_NAME=$(basename "$NEW_FILE")
        # shellcheck disable=SC2053
        if [[ "$FILE_NAME" == $FILE_PATTERN ]]; then
            upload_file_to_s3 "$NEW_FILE" "$DEST_PATH"
        fi
    done &
}

upload_file_to_s3() {
    local FILE_PATH="$1"
    local DEST_PATH="$2"
    
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        AWS_ACCESS_KEY_ID="$_BACKGROUND_S3_KEY" AWS_SECRET_ACCESS_KEY="$_BACKGROUND_S3_SECRET" \
        s5cmd --no-verify-ssl cp "$FILE_PATH" "$DEST_PATH" > /dev/null 2>&1
    else
        AWS_ACCESS_KEY_ID="$_BACKGROUND_S3_KEY" AWS_SECRET_ACCESS_KEY="$_BACKGROUND_S3_SECRET" \
        s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" cp "$FILE_PATH" "$DEST_PATH" > /dev/null 2>&1
    fi
}

start_sync_uploader() {
    WATCH_DIR="$1"
    DEST_PATH="$2"
    FILE_PATTERN="${3:-*}"

    inotifywait -m -e close_write,create --format '%w%f' "$WATCH_DIR" | while read -r NEW_FILE; do
        FILE_NAME=$(basename "$NEW_FILE")
        # shellcheck disable=SC2053
        if [[ "$FILE_NAME" == $FILE_PATTERN ]]; then
            sync_directory_to_s3 "$WATCH_DIR" "$DEST_PATH"
        fi
    done &
}

sync_directory_to_s3() {
    local SOURCE_DIR="$1"
    local DEST_PATH="$2"
    
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        AWS_ACCESS_KEY_ID="$_BACKGROUND_S3_KEY" AWS_SECRET_ACCESS_KEY="$_BACKGROUND_S3_SECRET" \
        s5cmd --no-verify-ssl sync "$SOURCE_DIR/" "$DEST_PATH" > /dev/null 2>&1
    else
        AWS_ACCESS_KEY_ID="$_BACKGROUND_S3_KEY" AWS_SECRET_ACCESS_KEY="$_BACKGROUND_S3_SECRET" \
        s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" sync "$SOURCE_DIR/" "$DEST_PATH" > /dev/null 2>&1
    fi
}
finalize_upload() {
    set -x 

    echo "🔄 FINALIZE_UPLOAD START"
    date
    echo "TMP_DIR: $TMP_DIR"
    echo "ATP_STORAGE_PROVIDER: $ATP_STORAGE_PROVIDER"
    echo "ATP_STORAGE_SERVER_URL: $ATP_STORAGE_SERVER_URL"
    echo "ATP_STORAGE_BUCKET: $ATP_STORAGE_BUCKET"
    echo "=================================================="

    RESULTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    REPORTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    ATTACHMENTS_S3_PATH="${REPORTS_S3_PATH}attachments/"

    echo "📂 RESULTS_S3_PATH: $RESULTS_S3_PATH"
    echo "📂 REPORTS_S3_PATH: $REPORTS_S3_PATH"
    echo "📂 ATTACHMENTS_S3_PATH: $ATTACHMENTS_S3_PATH"

    echo "🔑 Restoring AWS credentials..."
    restore_aws_credentials

    echo "📊 Local directory sizes:"
    du -sh "$TMP_DIR/allure-results" || true
    du -sh "$TMP_DIR/allure-report" || true
    du -sh "$TMP_DIR/attachments" || true
    du -sh "$TMP_DIR/scripts/email-notification-generated" || true

    echo "🚀 Uploading allure-results..."
    date
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        s5cmd -v --no-verify-ssl sync "$TMP_DIR/allure-results/" "${RESULTS_S3_PATH}allure-results/"
    else
        s5cmd -v --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" \
        sync "$TMP_DIR/allure-results/" "${RESULTS_S3_PATH}allure-results/"
    fi
    echo "✅ Done allure-results"
    date

    echo "🚀 Uploading attachments..."
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        s5cmd -v --no-verify-ssl sync "$TMP_DIR/attachments/" "$ATTACHMENTS_S3_PATH"
    else
        s5cmd -v --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" \
        sync "$TMP_DIR/attachments/" "$ATTACHMENTS_S3_PATH"
    fi
    echo "✅ Done attachments"
    date

    echo "🚀 Uploading allure-report..."
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        s5cmd -v --no-verify-ssl sync "$TMP_DIR/allure-report/" "${REPORTS_S3_PATH}allure-report/"
    else
        s5cmd -v --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" \
        sync "$TMP_DIR/allure-report/" "${REPORTS_S3_PATH}allure-report/"
    fi
    echo "✅ Done allure-report"
    date

    echo "🚀 Uploading email notification..."
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        s5cmd -v --no-verify-ssl sync "$TMP_DIR/scripts/email-notification-generated/" \
        "${RESULTS_S3_PATH}email-notification-generated/"
    else
        s5cmd -v --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" \
        sync "$TMP_DIR/scripts/email-notification-generated/" \
        "${RESULTS_S3_PATH}email-notification-generated/"
    fi
    echo "✅ Done email notification"
    date

    echo "📄 Creating upload marker..."
    echo "${ENABLE_JIRA_INTEGRATION:-false}" > "$TMP_DIR/allure-results.uploaded"

    echo "🚀 Uploading marker file..."
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        s5cmd -v --no-verify-ssl cp "$TMP_DIR/allure-results.uploaded" \
        "${RESULTS_S3_PATH}allure-results.uploaded"
    else
        s5cmd -v --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" \
        cp "$TMP_DIR/allure-results.uploaded" \
        "${RESULTS_S3_PATH}allure-results.uploaded"
    fi

    echo "🔗 Generating URLs..."
    generate_result_urls

    echo "🛑 Killing background watchers..."
    pkill -f inotifywait || true
    jobs -p | xargs -r kill || true

    echo "🧹 Cleaning credentials..."
    final_cleanup

    echo ""
    echo "Results are available at: ${RESULTS_URL}"
    echo "Reports are available at: ${REPORTS_URL}"
    echo "✅ FINALIZE_UPLOAD DONE"
    echo "=================================================="

    set +x
}
generate_result_urls() {
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        RESULTS_URL="${ATP_STORAGE_BUCKET}.${ATP_STORAGE_SERVER_UI_URL}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/allure-results/"
    elif [[ "$ATP_STORAGE_PROVIDER" == "minio" || "$ATP_STORAGE_PROVIDER" == "s3" ]]; then
        # Generate base64-encoded URLs for MinIO UI
        RESULTS_FOLDER_PATH="Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/allure-results/"
        RESULTS_ENCODED_PATH=$(echo -n "${RESULTS_FOLDER_PATH}" | base64)
        RESULTS_URL="${ATP_STORAGE_SERVER_UI_URL}/browser/${ATP_STORAGE_BUCKET}/${RESULTS_ENCODED_PATH}"

        REPORTS_FOLDER_PATH="Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/allure-report/"
        REPORTS_ENCODED_PATH=$(echo -n "${REPORTS_FOLDER_PATH}" | base64)
        REPORTS_URL="${ATP_STORAGE_SERVER_UI_URL}/browser/${ATP_STORAGE_BUCKET}/${REPORTS_ENCODED_PATH}"
    fi
}

clear_sensitive_vars() {
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset ATP_STORAGE_USERNAME
    unset ATP_STORAGE_PASSWORD
}

restore_aws_credentials() {
    export AWS_ACCESS_KEY_ID="$_LOCAL_S3_KEY"
    export AWS_SECRET_ACCESS_KEY="$_LOCAL_S3_SECRET"
}

final_cleanup() {
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset _LOCAL_S3_KEY
    unset _LOCAL_S3_SECRET
    unset _BACKGROUND_S3_KEY
    unset _BACKGROUND_S3_SECRET
}