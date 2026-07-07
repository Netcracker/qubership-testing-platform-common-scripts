#!/bin/bash

# Git repository cloning module
clone_repository() {
    if [ -d "$TMP_DIR" ] && [ "$(ls -A "$TMP_DIR" 2>/dev/null)" ]; then
        echo "ℹ️ Cloning tests repository is not required, because tests are already in image..."
        cd "$TMP_DIR"
        return 0
    fi

    echo "📥 Preparing tests repository..."

    # ============================================
    # Pre-flight validation
    # ============================================
    if [ -z "${ATP_TESTS_GIT_TOKEN:-}" ]; then
        echo "❌ ERROR: ATP_TESTS_GIT_TOKEN is not set (required to clone repository)"
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
    if [ -z "${TMP_DIR:-}" ]; then
        echo "❌ ERROR: TMP_DIR is not set"
        return 1
    fi

    # Basic URL sanity check (no whitespace, http/https)
    if [[ "$ATP_TESTS_GIT_REPO_URL" =~ [[:space:]] ]] || [[ ! "$ATP_TESTS_GIT_REPO_URL" =~ ^https?:// ]]; then
        echo "❌ ERROR: ATP_TESTS_GIT_REPO_URL is invalid URL: $ATP_TESTS_GIT_REPO_URL"
        return 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "❌ ERROR: git is not installed in the container"
        return 1
    fi

    export GIT_TERMINAL_PROMPT=0
    AUTH_REPO_URL=$(echo "$ATP_TESTS_GIT_REPO_URL" | sed "s|^https://|https://oauth2:${ATP_TESTS_GIT_TOKEN}@|")

    echo "📥 Cloning repository (branch: $ATP_TESTS_GIT_REPO_BRANCH)..."
    git clone \
        --depth 1 \
        --branch "$ATP_TESTS_GIT_REPO_BRANCH" \
        --single-branch \
        "$AUTH_REPO_URL" \
        "$TMP_DIR" || return 1

    cd "$TMP_DIR" || return 1

    if [ -f .gitmodules ]; then
        GIT_HOST=$(echo "$ATP_TESTS_GIT_REPO_URL" | sed 's|^https://||; s|/.*||')
        git config --global \
            "url.https://oauth2:${ATP_TESTS_GIT_TOKEN}@${GIT_HOST}/.insteadOf" \
            "https://${GIT_HOST}/"

        git submodule update --init --recursive || return 1

        git config --global --unset-all \
            "url.https://oauth2:${ATP_TESTS_GIT_TOKEN}@${GIT_HOST}/.insteadOf" 2>/dev/null || true

        echo "📋 Submodule status after initialization:"
        git submodule status || true
    fi

    echo "✅ Repository cloned to: $TMP_DIR"

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
    fi

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
}