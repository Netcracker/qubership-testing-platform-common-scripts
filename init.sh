#!/bin/bash

# Environment initialization module
init_environment() {
    echo "🔧 Initializing environment..."
    
    # Compute current date and time
    if [[ -z "${CURRENT_DATE}" ]]; then
        CURRENT_DATE=$(date +%F)         # e.g., 2025-04-07
    fi
    if [[ -z "${CURRENT_TIME}" ]]; then
        CURRENT_TIME=$(date +%H-%M-%S)  # e.g., 11-48-00
    fi

    # Configure AWS S3 parameters (required) - using local variables for security
    if [[ -z "${ATP_STORAGE_USERNAME}" ]]; then
        echo "❌ ATP_STORAGE_USERNAME is required but not set"
        return 1
    fi
    if [[ -z "${ATP_STORAGE_PASSWORD}" ]]; then
        echo "❌ ATP_STORAGE_PASSWORD is required but not set"
        return 1
    fi
    
    # Store credentials in local variables (not exported to environment)
    _LOCAL_S3_KEY="$ATP_STORAGE_USERNAME"
    _LOCAL_S3_SECRET="$ATP_STORAGE_PASSWORD"
    export AWS_ACCESS_KEY_ID="$_LOCAL_S3_KEY"
    export AWS_SECRET_ACCESS_KEY="$_LOCAL_S3_SECRET"

    # Configure additional s5cmd settings for MinIO only
    if [[ "${ATP_STORAGE_PROVIDER}" == "minio" || "${ATP_STORAGE_PROVIDER}" == "s3" ]]; then
        export AWS_ENDPOINT_URL="${ATP_STORAGE_SERVER_URL}"
        export AWS_REGION="${ATP_STORAGE_REGION}"             # Required by s5cmd even for MinIO
        export AWS_NO_VERIFY_SSL="true"           # Optional: disable SSL verification
    fi

    # Define temp clone path
    export TMP_DIR="/tmp/clone"
    mkdir -p "$TMP_DIR"

    # PROJECT_ID/RUN_ID are supplied by the orchestrator and used to build the
    # X-B3-TraceId propagated to systems under test (informational only: a
    # missing value disables B3 header generation, it does not fail the run).
    if [[ -z "${PROJECT_ID:-}" || -z "${RUN_ID:-}" ]]; then
        echo "⚠️ PROJECT_ID/RUN_ID not set — B3 trace/span headers will not be propagated"
    fi

    echo "✅ Environment initialized successfully"
}
