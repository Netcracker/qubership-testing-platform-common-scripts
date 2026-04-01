#!/bin/bash
# Event-based upload monitoring module
start_upload_monitoring() {
    echo "📡 Starting event-based upload monitoring..."
    UPLOAD_MONITOR_PIDS=()
    RESULTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    REPORTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    ATTACHMENTS_S3_PATH="${REPORTS_S3_PATH}attachments/"

    mkdir -p "$TMP_DIR/allure-results"
    mkdir -p "$TMP_DIR/attachments"
    
    _BACKGROUND_S3_KEY="$_LOCAL_S3_KEY"
    _BACKGROUND_S3_SECRET="$_LOCAL_S3_SECRET"
    
    if [[ "${UPLOAD_METHOD:-cp}" == "sync" ]]; then
        start_sync_uploader "$TMP_DIR/allure-results" "${RESULTS_S3_PATH}allure-results/" "*result.json"
        start_sync_uploader "$TMP_DIR/attachments" "$ATTACHMENTS_S3_PATH"
    else
        start_inotify_uploader "$TMP_DIR/allure-results" "${RESULTS_S3_PATH}allure-results/" "*result.json" 
        start_inotify_uploader "$TMP_DIR/attachments" "$ATTACHMENTS_S3_PATH" 
    fi
    
    echo "✅ Upload monitoring started"
}

start_inotify_uploader() {
    local WATCH_DIR="$1"
    local DEST_PATH="$2"
    local FILE_PATTERN="${3:-*}"
    echo "📡 Starting inotify uploader for directory: $WATCH_DIR, pattern: $FILE_PATTERN"

    (
      inotifywait -m -e close_write,create --format '%w%f' "$WATCH_DIR" |
      while read -r NEW_FILE; do
          FILE_NAME=$(basename "$NEW_FILE")
          if [[ "$FILE_NAME" == $FILE_PATTERN ]]; then
              upload_file_to_s3 "$NEW_FILE" "$DEST_PATH"
          fi
      done
    ) </dev/null >/dev/null 2>&1 &

    UPLOAD_MONITOR_PIDS+=("$!")
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
    local WATCH_DIR="$1"
    local DEST_PATH="$2"
    local FILE_PATTERN="${3:-*}"
    echo "📡 Starting sync uploader for directory: $WATCH_DIR, pattern: $FILE_PATTERN"
    (
      inotifywait -m -e close_write,create --format '%w%f' "$WATCH_DIR" |
      while read -r NEW_FILE; do
          FILE_NAME=$(basename "$NEW_FILE")
          if [[ "$FILE_NAME" == $FILE_PATTERN ]]; then
              sync_directory_to_s3 "$WATCH_DIR" "$DEST_PATH"
          fi
      done
    ) </dev/null >/dev/null 2>&1 &

    UPLOAD_MONITOR_PIDS+=("$!")
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
    echo "🔄 Finalizing upload operations..."

    RESULTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    REPORTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    ATTACHMENTS_S3_PATH="${REPORTS_S3_PATH}attachments/"

    restore_aws_credentials

    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        echo "📤 Performing final sync to AWS S3..."
        echo "   Source: $TMP_DIR/allure-results/ -> Destination: ${RESULTS_S3_PATH}allure-results/"
        echo "   Source: $TMP_DIR/attachments/ -> Destination: $ATTACHMENTS_S3_PATH"
        echo "   Source: $TMP_DIR/allure-report/ -> Destination: ${REPORTS_S3_PATH}allure-report/"
        echo "   Source: $TMP_DIR/scripts/email-notification-generated/ -> Destination: ${RESULTS_S3_PATH}email-notification-generated/"
        s5cmd --no-verify-ssl sync "$TMP_DIR/allure-results/" "${RESULTS_S3_PATH}allure-results/"
        s5cmd --no-verify-ssl sync "$TMP_DIR/attachments/" "$ATTACHMENTS_S3_PATH"
        if [ -d "$TMP_DIR/allure-report" ]; then
            echo "📤 Uploading Allure HTML report..."
            s5cmd --no-verify-ssl sync "$TMP_DIR/allure-report/" "${REPORTS_S3_PATH}allure-report/"
        else
            echo "ℹ️ allure-report directory not found — skipping HTML upload"
        fi
        s5cmd --no-verify-ssl sync "$TMP_DIR/scripts/email-notification-generated/" "${RESULTS_S3_PATH}email-notification-generated/"
    else
        echo "📤 Performing final sync to MinIO/S3-compatible storage..."
        echo "   Source: $TMP_DIR/allure-results/ -> Destination: ${RESULTS_S3_PATH}allure-results/"    
        echo "   Source: $TMP_DIR/attachments/ -> Destination: $ATTACHMENTS_S3_PATH"
        echo "   Source: $TMP_DIR/allure-report/ -> Destination: ${REPORTS_S3_PATH}allure-report/"
        echo "   Source: $TMP_DIR/scripts/email-notification-generated/ -> Destination: ${RESULTS_S3_PATH}email-notification-generated/"
        s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" sync "$TMP_DIR/allure-results/" "${RESULTS_S3_PATH}allure-results/"
        s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" sync "$TMP_DIR/attachments/" "$ATTACHMENTS_S3_PATH"
        if [ -d "$TMP_DIR/allure-report" ]; then
            echo "📤 Uploading Allure HTML report..."
            s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" \
            sync "$TMP_DIR/allure-report/" "${REPORTS_S3_PATH}allure-report/"
        else
            echo "ℹ️ allure-report directory not found — skipping HTML upload"
        fi
        s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" sync "$TMP_DIR/scripts/email-notification-generated/" "${RESULTS_S3_PATH}email-notification-generated/"
    fi

    echo "${ENABLE_JIRA_INTEGRATION:-false}" > "$TMP_DIR/allure-results.uploaded"

    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
    echo "📤 Uploading marker file to AWS S3: ${RESULTS_S3_PATH}allure-results.uploaded"
        s5cmd --no-verify-ssl cp "$TMP_DIR/allure-results.uploaded" "${RESULTS_S3_PATH}allure-results.uploaded"
    else
    echo "📤 Uploading marker file to MinIO/S3-compatible storage: ${RESULTS_S3_PATH}allure-results.uploaded"
        s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" cp "$TMP_DIR/allure-results.uploaded" "${RESULTS_S3_PATH}allure-results.uploaded"
    fi
    echo "✅ Final sync completed, marker file uploaded"
    generate_result_urls
    final_cleanup

    echo ""
    echo "Results are available at: ${RESULTS_URL}"
    echo "Reports are available at: ${REPORTS_URL}"
    echo "Report view is available at: ${ATP_REPORT_VIEW_UI_URL}/${REPORTS_FOLDER_PATH}index.html"
    echo "✅ Upload finalization completed"
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