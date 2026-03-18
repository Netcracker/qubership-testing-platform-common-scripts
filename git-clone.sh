#!/bin/bash

# Git repository cloning module
clone_repository() {
    if [ -d "$TMP_DIR" ] && [ "$(ls -A "$TMP_DIR" 2>/dev/null)" ]; then
        echo "ℹ️ Cloning tests repository is not required, because tests are already in image..."
        return 0
    fi

    echo "📥 Preparing tests repository..."

    REPO_PATH=$(echo "$ATP_TESTS_GIT_REPO_URL" | sed 's|\.git$||')
    GIT_BRANCH_CLEANED=$(echo "$ATP_TESTS_GIT_REPO_BRANCH" | sed 's|/|-|')
    REPO_NAME=$(basename "$REPO_PATH")
    ARCHIVE_URL="${REPO_PATH}/-/archive/${ATP_TESTS_GIT_REPO_BRANCH}/${REPO_NAME}-${GIT_BRANCH_CLEANED}.zip"

    fetch_by_clone_with_submodules() {
        if ! command -v git >/dev/null 2>&1; then
            echo "❌ git is not installed in the container, cannot clone repository with submodules"
            return 1
        fi

        echo "📥 .gitmodules detected — switching to git clone with submodules..."

        rm -rf "$TMP_DIR"

        AUTH_REPO_URL="$ATP_TESTS_GIT_REPO_URL"
        if [[ "$AUTH_REPO_URL" =~ ^https:// ]]; then
            AUTH_REPO_URL=$(echo "$AUTH_REPO_URL" | sed "s|^https://|https://oauth2:${ATP_TESTS_GIT_TOKEN}@|")
        fi

        git clone \
            --branch "$ATP_TESTS_GIT_REPO_BRANCH" \
            --single-branch \
            "$AUTH_REPO_URL" \
            "$TMP_DIR" || return 1

        cd "$TMP_DIR" || return 1

        if [ -f .gitmodules ]; then
            echo "🔧 Rewriting submodule URLs to use token authentication..."

            git config --file=.gitmodules --get-regexp '^submodule\..*\.url$' | while read -r key url; do
                if [[ "$url" =~ ^https://YOUR_GIT_HOST/ ]]; then
                    auth_url=$(echo "$url" | sed "s|^https://|https://oauth2:${ATP_TESTS_GIT_TOKEN}@|")
                    echo "   $key -> authenticated YOUR_GIT_HOST URL"
                    git config --file=.gitmodules "$key" "$auth_url"
                fi
            done
        fi

        git submodule sync --recursive
        git submodule update --init --recursive || return 1
        echo "📋 Submodule status after initialization:"
        git submodule status || true

        echo "✅ Repository cloned with submodules to: $TMP_DIR"
    }

    echo "📥 Downloading repository archive from: $ARCHIVE_URL"
    curl -sSL --fail \
        -H "PRIVATE-TOKEN: ${ATP_TESTS_GIT_TOKEN}" \
        "$ARCHIVE_URL" \
        -o "$TMP_DIR/repo.zip" || {
            echo "❌ Failed to download repository archive"
            exit 1
        }

    echo "📦 Unzipping..."
    unzip -q "$TMP_DIR/repo.zip" -d "$TMP_DIR" || {
        echo "❌ Failed to unzip repository archive"
        exit 1
    }

    extracted_dir="$TMP_DIR/${REPO_NAME}-${GIT_BRANCH_CLEANED}"

    if [ -f "$extracted_dir/.gitmodules" ]; then
        rm -rf "$extracted_dir"
        rm -f "$TMP_DIR/repo.zip"

        fetch_by_clone_with_submodules || {
            echo "❌ Failed to clone repository with submodules"
            exit 1
        }
    else
        shopt -s dotglob
        mv "$extracted_dir"/* "$TMP_DIR" || {
            shopt -u dotglob
            echo "❌ Failed to move extracted repository contents"
            exit 1
        }
        shopt -u dotglob

        rm -rf "$extracted_dir"
        rm -f "$TMP_DIR/repo.zip"

        echo "✅ Repository extracted to: $TMP_DIR"
    fi

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
        exit 1
    fi

    cd "$TMP_DIR" || exit 1

    if [ -d "$TMP_DIR/app" ]; then
        echo "📋 Contents of $TMP_DIR/app directory:"
        ls -la app
    elif [ -d "$TMP_DIR/tests" ]; then
        echo "📋 Contents of $TMP_DIR/tests directory:"
        ls -la tests
    fi

    if [ -f "$TMP_DIR/.gitmodules" ]; then
        echo "📋 .gitmodules detected:"
        cat "$TMP_DIR/.gitmodules"

        if command -v git >/dev/null 2>&1; then
            echo "📋 Submodule status:"
            git submodule status || true
        fi
    fi

    unset ATP_TESTS_GIT_TOKEN
    echo "🔐 Git token cleared from environment"
    echo "✅ Tests repository prepared successfully"
}