#!/bin/bash

# Git repository cloning module
clone_repository() {
    if [ -d "$TMP_DIR" ] && [ "$(ls -A "$TMP_DIR" 2>/dev/null)" ]; then
        echo "ℹ️ Cloning tests repository is not required, because tests are already in image..."
    else
        echo "📥 Cloning tests repository..."

        # ============================================
        # Pre-flight validation
        # ============================================
        if [ -z "${ATP_TESTS_GIT_TOKEN:-}" ]; then
            echo "❌ ERROR: ATP_TESTS_GIT_TOKEN is not set (required to download repository archive)"
            return 1
        fi
        if [ -z "${ATP_TESTS_GIT_REPO_URL:-}" ]; then
            echo "❌ ERROR: ATP_TESTS_GIT_REPO_URL is not set"
            return 1
        fi
        if [ -z "${ATP_TESTS_GIT_REPO_BRANCH:-}" ]; then
            echo "❌ ERROR: ATP_TESTS_GIT_REPO_BRANCH is not set"
            return 1
        fi
        # Basic URL sanity check (no whitespace, http/https)
        if [[ "$ATP_TESTS_GIT_REPO_URL" =~ [[:space:]] ]] || [[ ! "$ATP_TESTS_GIT_REPO_URL" =~ ^https?:// ]]; then
            echo "❌ ERROR: ATP_TESTS_GIT_REPO_URL is invalid URL: $ATP_TESTS_GIT_REPO_URL"
            return 1
        fi

        # Strip .git from URL and extract repo name
        REPO_PATH=$(echo "$ATP_TESTS_GIT_REPO_URL" | sed 's|\.git$||')
        GIT_BRANCH_CLEANED=$(echo "$ATP_TESTS_GIT_REPO_BRANCH" | sed 's|/|-|')
        REPO_NAME=$(basename "$REPO_PATH")
        ARCHIVE_URL="${REPO_PATH}/-/archive/${ATP_TESTS_GIT_REPO_BRANCH}/${REPO_NAME}-${GIT_BRANCH_CLEANED}.zip"

        if [ -z "${TMP_DIR:-}" ]; then
            echo "❌ ERROR: TMP_DIR is not set"
            return 1
        fi
        echo "📥 Downloading archive from: $ARCHIVE_URL"
        mkdir -p "$TMP_DIR" 2>/dev/null || true
        ZIP_PATH="$TMP_DIR/repo.zip"
        CURL_ERR_PATH="$TMP_DIR/curl_download.err"

        # ============================================
        # Download archive with enhanced error handling
        # - connect timeout: 30s
        # - max time: 120s
        # ============================================
        HTTP_CODE="$(
            curl -sS -L \
                --connect-timeout 30 \
                --max-time 120 \
                --fail \
                -H "PRIVATE-TOKEN: ${ATP_TESTS_GIT_TOKEN}" \
                "$ARCHIVE_URL" \
                -o "$ZIP_PATH" \
                -w "%{http_code}" \
                2>"$CURL_ERR_PATH"
        )"
        CURL_EXIT_CODE=$?

        # ============================================
        # Error detection and messaging
        # ============================================
        if [ "$CURL_EXIT_CODE" -ne 0 ]; then
            CURL_ERR_MSG=""
            if [ -f "$CURL_ERR_PATH" ]; then
                CURL_ERR_MSG=$(tr '\n' ' ' < "$CURL_ERR_PATH" | sed 's/[[:space:]]\+/ /g' | sed 's/[[:space:]]*$//')
            fi

            case "$CURL_EXIT_CODE" in
                6)
                    echo "❌ ERROR: Couldn't resolve host while downloading repository archive."
                    ;;
                7)
                    echo "❌ ERROR: Failed to connect to host while downloading repository archive."
                    ;;
                22)
                    # HTTP error (4xx/5xx). We'll handle using HTTP_CODE below.
                    ;;
                28)
                    echo "❌ ERROR: Download timed out (connect-timeout=30s, max-time=120s)."
                    ;;
                35)
                    echo "❌ ERROR: SSL/TLS connection error while downloading repository archive."
                    ;;
                52)
                    echo "❌ ERROR: Empty reply from server while downloading repository archive."
                    ;;
                56)
                    echo "❌ ERROR: Network receive error while downloading repository archive."
                    ;;
                *)
                    echo "❌ ERROR: Network error while downloading repository archive (curl exit code: $CURL_EXIT_CODE)."
                    ;;
            esac

            if [ -n "$CURL_ERR_MSG" ]; then
                echo "   curl: $CURL_ERR_MSG"
            fi

            # For non-HTTP curl failures, stop here (HTTP_CODE may be empty/undefined).
            if [ "$CURL_EXIT_CODE" -ne 22 ]; then
                return 1
            fi
        fi

        # HTTP code interpretation (also covers curl --fail exit 22)
        if [ "$HTTP_CODE" != "200" ]; then
            case "$HTTP_CODE" in
                200)
                    # ok
                    ;;
                000)
                    echo "❌ ERROR: No HTTP response received from server (HTTP 000)."
                    echo "   Check network connectivity and URL: $ARCHIVE_URL"
                    return 1
                    ;;
                401|403)
                    echo "❌ ERROR: Authentication failed (HTTP $HTTP_CODE)."
                    echo "   Check that ATP_TESTS_GIT_TOKEN is valid and has access to the repository."
                    return 1
                    ;;
                404)
                    echo "❌ ERROR: Repository or branch not found (HTTP 404)."
                    echo "   Check URL and branch:"
                    echo "   - URL: $ATP_TESTS_GIT_REPO_URL"
                    echo "   - Branch: $ATP_TESTS_GIT_REPO_BRANCH"
                    echo "   - Archive URL: $ARCHIVE_URL"
                    return 1
                    ;;
                429)
                    echo "❌ ERROR: Rate limited by the server (HTTP 429)."
                    echo "   Try again later or reduce request frequency."
                    return 1
                    ;;
                5??)
                    echo "❌ ERROR: Server error while downloading archive (HTTP $HTTP_CODE)."
                    echo "   The Git server may be temporarily unavailable."
                    return 1
                    ;;
                *)
                    echo "❌ ERROR: Failed to download repository archive (HTTP $HTTP_CODE, curl exit code: $CURL_EXIT_CODE)."
                    echo "   Archive URL: $ARCHIVE_URL"
                    return 1
                    ;;
            esac
        fi

        # ============================================
        # Downloaded archive validation
        # ============================================
        if [ ! -f "$ZIP_PATH" ] || [ ! -s "$ZIP_PATH" ]; then
            echo "❌ ERROR: Downloaded file is missing or empty: $ZIP_PATH"
            return 1
        fi

        if command -v file >/dev/null 2>&1; then
            FILE_TYPE="$(file "$ZIP_PATH" 2>/dev/null || true)"
            if ! printf '%s' "$FILE_TYPE" | grep -qi "zip archive"; then
                # Git servers sometimes return an HTML login page when the token is invalid/expired.
                if printf '%s' "$FILE_TYPE" | grep -qi "html"; then
                    echo "❌ ERROR: Downloaded an HTML login page instead of a repository."
                    echo "   Check that ATP_TESTS_GIT_TOKEN is valid and has access to the repository."
                    echo "   Check that the repository URL is correct."
                else
                    echo "❌ ERROR: Downloaded repository is not recognized as a zip archive."
                fi
                echo "   File type: $FILE_TYPE"
                return 1
            fi
        else
            echo "⚠️ 'file' command not available; skipping zip magic-byte validation."
        fi

        if command -v unzip >/dev/null 2>&1; then
            if ! unzip -t "$ZIP_PATH" > /dev/null 2>&1; then
                echo "❌ ERROR: Archive integrity test failed (unzip -t). Please retry the operation."
                return 1
            fi
        else
            echo "❌ ERROR: 'unzip' command is not available; cannot validate/extract archive."
            return 1
        fi

        echo "📦 Unzipping..."
        unzip -q "$ZIP_PATH" -d "$TMP_DIR"
        mv "$TMP_DIR"/${REPO_NAME}-${GIT_BRANCH_CLEANED}/* "$TMP_DIR"

        echo "✅ Repository extracted to: $TMP_DIR"
    fi

    # Check for either 'app/' nor 'tests/' nor 'collections/' directory (for different runtime types)
    if [ -d "$TMP_DIR/app" ]; then
        echo "✅ Validation successful. Found 'app/' directory in the repo."
    elif [ -d "$TMP_DIR/tests" ]; then
        echo "✅ Validation successful. Found 'tests/' directory in the repo."
    elif find "$TMP_DIR" -mindepth 1 -type f -iname "*postman_collection*" -print -quit | grep -q .; then
        echo "✅ Validation successful. Found 'postman_collection' files in the repo."
    elif [ -d "$TMP_DIR/collections" ]; then
        echo "✅ Validation successful. Found 'collections/' directory in the repo."
    else
        echo "❌ ERROR: Neither 'app/' nor 'tests/' nor 'collections/' directory nor 'postman_collection' file found in the cloned repo!"
        return 1
    fi

    # Move into the work directory
    cd "$TMP_DIR"

    # List contents to verify
    if [ -d "$TMP_DIR/app" ]; then
        echo "📋 Contents of $TMP_DIR/app directory:"
        ls -la app
    elif [ -d "$TMP_DIR/tests" ]; then
        echo "📋 Contents of $TMP_DIR/tests directory:"
        ls -la tests
    fi


    # Clear Git token from environment for security
    unset ATP_TESTS_GIT_TOKEN
    echo "🔐 Git token cleared from environment"
    echo "✅ Tests repository prepared successfully"
} 
