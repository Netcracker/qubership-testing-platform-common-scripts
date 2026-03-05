#!/bin/bash

# Git repository cloning module
clone_repository() {
    if [ -d "$TMP_DIR" ] && [ "$(ls -A "$TMP_DIR" 2>/dev/null)" ]; then
        log "ℹ️ Cloning tests repository is not required, because tests are already in image..."
    else
        log "📥 Cloning tests repository..."

        # Strip .git from URL and extract repo name
        REPO_PATH=$(echo "$ATP_TESTS_GIT_REPO_URL" | sed 's|\.git$||')
        GIT_BRANCH_CLEANED=$(echo "$ATP_TESTS_GIT_REPO_BRANCH" | sed 's|/|-|')
        REPO_NAME=$(basename "$REPO_PATH")
        ARCHIVE_URL="${REPO_PATH}/-/archive/${ATP_TESTS_GIT_REPO_BRANCH}/${REPO_NAME}-${GIT_BRANCH_CLEANED}.zip"

        log "📥 Downloading archive from: $ARCHIVE_URL"
        curl -sSL --fail -H "PRIVATE-TOKEN: ${ATP_TESTS_GIT_TOKEN}" "$ARCHIVE_URL" -o "$TMP_DIR/repo.zip"

        if [[ $? -ne 0 ]]; then
            log "❌ Failed to download repository archive"
            exit 1
        fi

        log "📦 Unzipping..."
        unzip -q "$TMP_DIR/repo.zip" -d "$TMP_DIR"
        mv "$TMP_DIR"/${REPO_NAME}-${GIT_BRANCH_CLEANED}/* "$TMP_DIR"

        log "✅ Repository extracted to: $TMP_DIR"
    fi

    # Check for either 'app/' nor 'tests/' nor 'collections/' directory (for different runtime types)
    if [ -d "$TMP_DIR/app" ]; then
        log "✅ Validation successful. Found 'app/' directory in the repo."
    elif [ -d "$TMP_DIR/tests" ]; then
        log "✅ Validation successful. Found 'tests/' directory in the repo."
    elif find "$TMP_DIR" -mindepth 1 -type f -iname "*postman_collection*" -print -quit | grep -q .; then
        log "✅ Validation successful. Found 'postman_collection' files in the repo."
    elif [ -d "$TMP_DIR/collections" ]; then
        log "✅ Validation successful. Found 'collections/' directory in the repo."
    else
        log "❌ ERROR: Neither 'app/' nor 'tests/' nor 'collections/' directory nor 'postman_collection' file found in the cloned repo!"
        exit 1
    fi

    # Move into the work directory
    cd $TMP_DIR

    # List contents to verify
    if [ -d "$TMP_DIR/app" ]; then
        log "📋 Contents of $TMP_DIR/app directory:"
        ls -la app
    elif [ -d "$TMP_DIR/tests" ]; then
        log "📋 Contents of $TMP_DIR/tests directory:"
        ls -la tests
    fi

    # Clear Git token from environment for security
    unset ATP_TESTS_GIT_TOKEN
    log "🔐 Git token cleared from environment"
    log "✅ Tests repository prepared successfully"
} 
