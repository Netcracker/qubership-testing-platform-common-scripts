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

        # ENVIRONMENT_NAME is only a label in S3 paths/reports; default it for local runs
        export ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-local}"

        # Result folder in S3: "<CLUSTER_NAME>-<ENVIRONMENT_NAME>" when CLUSTER_NAME is set,
        # otherwise just "<ENVIRONMENT_NAME>". CLUSTER_NAME must not contain a dash, so the
        # dash separator stays unambiguous.
        if [[ -n "${CLUSTER_NAME:-}" ]]; then
            if [[ "$CLUSTER_NAME" == *-* ]]; then
                echo "❌ CLUSTER_NAME must not contain a dash: '$CLUSTER_NAME'" >&2
                return 1
            fi
            export RESULT_FOLDER_NAME="${CLUSTER_NAME}-${ENVIRONMENT_NAME}"
        else
            export RESULT_FOLDER_NAME="${ENVIRONMENT_NAME}"
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

    echo "✅ Environment initialized successfully"
}
