#!/bin/bash

# Event-based upload monitoring module
start_upload_monitoring() {
    echo "📡 Starting event-based upload monitoring..."
    
    # Prepare common S3 paths
    RESULTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    REPORTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    ATTACHMENTS_S3_PATH="${REPORTS_S3_PATH}attachments/"

    # Create attachments directory
    mkdir -p $TMP_DIR/allure-results
    mkdir -p $TMP_DIR/attachments
    
    # Store credentials for background processes (local variables, not exported)
    _BACKGROUND_S3_KEY="$_LOCAL_S3_KEY"
    _BACKGROUND_S3_SECRET="$_LOCAL_S3_SECRET"
    
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
    inotifywait -m -e close_write,create --format '%w%f' "$WATCH_DIR" | while read NEW_FILE; do
        FILE_NAME=$(basename "$NEW_FILE")
        if [[ "$FILE_NAME" == $FILE_PATTERN ]]; then
            echo "🆕 Matching file: $FILE_NAME"
            upload_file_to_s3 "$NEW_FILE" "$DEST_PATH"
        else
            echo "⚠️ Ignored file: $FILE_NAME"
        fi
    done &
    
    # Store the background process PID
    INOTIFY_PID=$!
    echo "📡 Inotify process started with PID: $INOTIFY_PID"
}

# Upload file to S3/MinIO
upload_file_to_s3() {
    local FILE_PATH="$1"
    local DEST_PATH="$2"
    
    # Use background credentials for upload
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        AWS_ACCESS_KEY_ID="$_BACKGROUND_S3_KEY" AWS_SECRET_ACCESS_KEY="$_BACKGROUND_S3_SECRET" s5cmd --no-verify-ssl cp "$FILE_PATH" "$DEST_PATH" > /dev/null
    elif [[ "$ATP_STORAGE_PROVIDER" == "minio" || "$ATP_STORAGE_PROVIDER" == "s3" ]]; then
        AWS_ACCESS_KEY_ID="$_BACKGROUND_S3_KEY" AWS_SECRET_ACCESS_KEY="$_BACKGROUND_S3_SECRET" s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" cp "$FILE_PATH" "$DEST_PATH" > /dev/null
    fi
}

# Sync-based uploader function (triggered by inotifywait)
start_sync_uploader() {
    WATCH_DIR="$1"
    DEST_PATH="$2"
    FILE_PATTERN="${3:-*}"  # Optional filename filter

    echo "🔄 Starting sync uploader for $WATCH_DIR => $DEST_PATH (filter: $FILE_PATTERN)"

    # Pass credentials as environment variables only for this process
    inotifywait -m -e close_write,create --format '%w%f' "$WATCH_DIR" | while read NEW_FILE; do
        FILE_NAME=$(basename "$NEW_FILE")
        if [[ "$FILE_NAME" == $FILE_PATTERN ]]; then
            echo "🆕 Matching file: $FILE_NAME - triggering sync"
            sync_directory_to_s3 "$WATCH_DIR" "$DEST_PATH"
        #else
        #    echo "⚠️ Ignored file: $FILE_NAME"
        fi
    done &
    
    # Store the background process PID
    SYNC_PID=$!
    echo "🔄 Sync process started with PID: $SYNC_PID"
}

# Sync directory to S3/MinIO
sync_directory_to_s3() {
    local SOURCE_DIR="$1"
    local DEST_PATH="$2"
    
    # Use background credentials for sync
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        AWS_ACCESS_KEY_ID="$_BACKGROUND_S3_KEY" AWS_SECRET_ACCESS_KEY="$_BACKGROUND_S3_SECRET" s5cmd --no-verify-ssl sync "$SOURCE_DIR/" "$DEST_PATH" > /dev/null
    elif [[ "$ATP_STORAGE_PROVIDER" == "minio" || "$ATP_STORAGE_PROVIDER" == "s3" ]]; then
        AWS_ACCESS_KEY_ID="$_BACKGROUND_S3_KEY" AWS_SECRET_ACCESS_KEY="$_BACKGROUND_S3_SECRET" s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" sync "$SOURCE_DIR/" "$DEST_PATH" > /dev/null
    fi
}

# Finalize upload after tests
finalize_upload() {
    echo "🔄 Finalizing upload operations..."
    
    # Prepare common S3 paths
    RESULTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    REPORTS_S3_PATH="s3://${ATP_STORAGE_BUCKET}/Report/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/"
    ATTACHMENTS_S3_PATH="${REPORTS_S3_PATH}attachments/"

    # Restore credentials for final operations
    restore_aws_credentials

    # Final sync to ensure all files are captured
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        s5cmd --no-verify-ssl sync "$TMP_DIR/allure-results/" "${RESULTS_S3_PATH}allure-results/" > /dev/null
        s5cmd --no-verify-ssl sync "$TMP_DIR/attachments/" "$ATTACHMENTS_S3_PATH" > /dev/null
        s5cmd --no-verify-ssl sync "$TMP_DIR/scripts/email-notification-generated/" "${RESULTS_S3_PATH}email-notification-generated/" > /dev/null
    elif [[ "$ATP_STORAGE_PROVIDER" == "minio" || "$ATP_STORAGE_PROVIDER" == "s3" ]]; then
        s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" sync "$TMP_DIR/allure-results/" "${RESULTS_S3_PATH}allure-results/" > /dev/null
        s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" sync "$TMP_DIR/attachments/" "$ATTACHMENTS_S3_PATH" > /dev/null
        s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" sync "$TMP_DIR/scripts/email-notification-generated/" "${RESULTS_S3_PATH}email-notification-generated/" > /dev/null
    fi

    # Upload marker file
    echo "${ENABLE_JIRA_INTEGRATION:-false}" > $TMP_DIR/allure-results.uploaded
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        s5cmd --no-verify-ssl cp "$TMP_DIR/allure-results.uploaded" "${RESULTS_S3_PATH}allure-results.uploaded" > /dev/null
    elif [[ "$ATP_STORAGE_PROVIDER" == "minio" || "$ATP_STORAGE_PROVIDER" == "s3" ]]; then
        s5cmd --no-verify-ssl --endpoint-url "$ATP_STORAGE_SERVER_URL" cp "$TMP_DIR/allure-results.uploaded" "${RESULTS_S3_PATH}allure-results.uploaded" > /dev/null
    fi

    notify_allure_proc

    # Generate result URLs
    generate_result_urls

    # Final cleanup
    final_cleanup

    echo ""
    echo "Results are available at: ${RESULTS_URL}"
    echo "Reports are available at: ${REPORTS_URL}"
    echo "Report view is available at: ${ATP_REPORT_VIEW_UI_URL}/${REPORTS_FOLDER_PATH}index.html"
    
    echo "✅ Upload finalization completed"
}

# Ask allure-proc to generate the report. /transform answers only after generation
# finishes; a client timeout means the body was sent and work continues there.
notify_allure_proc() {
    if [[ -z "${ATP_ALLURE_PROC_HOST:-}" ]]; then
        return 0
    fi

    local host="${ATP_ALLURE_PROC_HOST%/}"
    local transform_url="${host}/transform"
    local storage_key="${ATP_STORAGE_BUCKET}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/allure-results.uploaded"
    local payload
    payload=$(printf '{"EventName":"s3:ObjectCreated:Put","Key":"%s"}' "$storage_key")

    echo "📡 Notifying allure-proc: ${transform_url}"

    local attempt http_code curl_status
    local max_attempts=3
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        http_code=""
        curl_status=0
        http_code=$(curl --silent --show-error --max-time 10 \
            --header "Content-Type: application/json" \
            --data "$payload" \
            --output /dev/null \
            --write-out "%{http_code}" \
            "$transform_url") || curl_status=$?

        if [[ "$curl_status" -eq 0 && "$http_code" == "200" ]]; then
            echo "✅ allure-proc transform completed"
            return 0
        fi
        # Timeout means the body was sent; another POST would start a second run.
        if [[ "$curl_status" -eq 28 ]]; then
            echo "ℹ️ allure-proc still running after client timeout; generation continues"
            return 0
        fi

        echo "⚠️ allure-proc notification failed (attempt ${attempt}/${max_attempts}, curl=${curl_status}, http=${http_code:-none})"
        if [[ "$attempt" -lt "$max_attempts" ]]; then
            sleep 2
        fi
    done
    return 0
}

# Generate URLs for results
generate_result_urls() {
    if [[ "$ATP_STORAGE_PROVIDER" == "aws" ]]; then
        RESULT_URL="${ATP_STORAGE_BUCKET}.${ATP_STORAGE_SERVER_UI_URL}/Result/${ENVIRONMENT_NAME}/${CURRENT_DATE}/${CURRENT_TIME}/allure-results/"
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