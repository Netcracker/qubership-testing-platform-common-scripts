#!/bin/bash

_has_repo_markers() {
    local dir="$1"

    [ -d "$dir/app" ] && return 0
    [ -d "$dir/tests" ] && return 0
    find "$dir" -mindepth 1 -type f -iname "*postman_collection*" -print -quit 2>/dev/null | grep -q . && return 0
    [ -d "$dir/collections" ] && return 0
    return 1
}

_is_ignore_structure() {
    local flag="${ATP_TESTS_IGNORE_STRUCTURE:-}"
    flag="${flag#"${flag%%[![:space:]]*}"}"
    flag="${flag%"${flag##*[![:space:]]}"}"
    case "${flag,,}" in
        true|1|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Apply an explicit relative ATP_TESTS_PROJECT_ROOT under tmp_dir.
_apply_project_root() {
    local tmp_dir="$1"
    local root_rel="$2"

    root_rel="${root_rel%/}"

    if [[ "$root_rel" == /* ]]; then
        echo "❌ ERROR: ATP_TESTS_PROJECT_ROOT must be a relative path, got: $root_rel"
        return 1
    fi

    if [[ "$root_rel" == ".." || "$root_rel" == ../* || "$root_rel" == */.. || "$root_rel" == */../* ]]; then
        echo "❌ ERROR: ATP_TESTS_PROJECT_ROOT must not contain '..': $root_rel"
        return 1
    fi

    local candidate="$tmp_dir/$root_rel"
    if [ ! -d "$candidate" ]; then
        echo "❌ ERROR: ATP_TESTS_PROJECT_ROOT directory not found: $candidate"
        return 1
    fi

    if command -v realpath >/dev/null 2>&1; then
        local resolved tmp_resolved
        resolved=$(realpath "$candidate")
        tmp_resolved=$(realpath "$tmp_dir")
        if [[ "$resolved" != "$tmp_resolved" && "$resolved" != "$tmp_resolved"/* ]]; then
            echo "❌ ERROR: ATP_TESTS_PROJECT_ROOT escapes clone directory: $root_rel"
            return 1
        fi
        export PROJECT_DIR="$resolved"
    else
        export PROJECT_DIR="$candidate"
    fi

    echo "✅ Project directory set to: $PROJECT_DIR"
    return 0
}

# Resolve PROJECT_DIR priorities:
# 1) ATP_TESTS_PROJECT_ROOT if set
# 2) current root when app/tests/collections/postman_collection markers exist
# 3) TestGeneration/ when present (sets ATP_TESTS_PROJECT_ROOT=TestGeneration)
# 4) otherwise clone root (validation may skip via ATP_TESTS_IGNORE_STRUCTURE)
_resolve_project_dir() {
    local tmp_dir="$1"
    local root_rel="${ATP_TESTS_PROJECT_ROOT:-}"

    root_rel="${root_rel#"${root_rel%%[![:space:]]*}"}"
    root_rel="${root_rel%"${root_rel##*[![:space:]]}"}"

    if [ -n "$root_rel" ]; then
        _apply_project_root "$tmp_dir" "$root_rel"
        return $?
    fi

    if _has_repo_markers "$tmp_dir"; then
        export PROJECT_DIR="$tmp_dir"
        echo "✅ Project directory set to: $PROJECT_DIR"
        return 0
    fi

    if [ -d "$tmp_dir/TestGeneration" ]; then
        export ATP_TESTS_PROJECT_ROOT="TestGeneration"
        _apply_project_root "$tmp_dir" "TestGeneration"
        return $?
    fi

    export PROJECT_DIR="$tmp_dir"
    echo "ℹ️ No repo markers or TestGeneration/ found; project directory remains: $PROJECT_DIR"
    return 0
}

_validate_repo_markers() {
    local dir="$1"

    if [ -d "$dir/app" ]; then
        echo "✅ Validation successful. Found 'app/' directory in the repo."
    elif [ -d "$dir/tests" ]; then
        echo "✅ Validation successful. Found 'tests/' directory in the repo."
    elif find "$dir" -mindepth 1 -type f -iname "*postman_collection*" -print -quit 2>/dev/null | grep -q .; then
        echo "✅ Validation successful. Found 'postman_collection' files in the repo."
    elif [ -d "$dir/collections" ]; then
        echo "✅ Validation successful. Found 'collections/' directory in the repo."
    else
        if _is_ignore_structure; then
            echo "⚠️ WARNING: Neither 'app/' nor 'tests/' nor 'collections/' directory nor 'postman_collection' file found."
            echo "   ATP_TESTS_IGNORE_STRUCTURE=true — skipping structure validation."
            return 0
        fi
        echo "❌ ERROR: Neither 'app/' nor 'tests/' nor 'collections/' directory nor 'postman_collection' file found in the cloned repo!"
        return 1
    fi

    return 0
}

_finalize_clone() {
    _resolve_project_dir "$TMP_DIR" || return 1
    _validate_repo_markers "$PROJECT_DIR" || return 1
    cd "$PROJECT_DIR" || return 1

    if [ -d "$PROJECT_DIR/app" ]; then
        echo "📋 Contents of $PROJECT_DIR/app directory:"
        ls -la app
    elif [ -d "$PROJECT_DIR/tests" ]; then
        echo "📋 Contents of $PROJECT_DIR/tests directory:"
        ls -la tests
    fi

    if [ -f "$TMP_DIR/.gitmodules" ]; then
        if command -v git >/dev/null 2>&1; then
            echo "📋 Submodule status:"
            git submodule status || true
        fi
    fi

    return 0
}

_clear_git_insteadOf() {
    if [ -n "${_GIT_INSTEADOF_KEY:-}" ]; then
        git config --global --unset-all "$_GIT_INSTEADOF_KEY" 2>/dev/null || true
        unset _GIT_INSTEADOF_KEY
    fi
}

_report_git_fetch_error() {
    local exit_code="$1"
    local err_file="$2"
    local operation="$3"
    local err_msg=""

    if [ -f "$err_file" ]; then
        err_msg=$(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]]\+/ /g' | sed 's/[[:space:]]*$//')
    fi

    if printf '%s' "$err_msg" | grep -qiE 'Authentication failed|could not read Username|HTTP Basic: Access denied|403|401|Invalid username or password'; then
        echo "❌ ERROR: Authentication failed while ${operation}."
        echo "   Check that ATP_TESTS_GIT_TOKEN is valid and has access to the repository."
    elif printf '%s' "$err_msg" | grep -qiE 'not found|Repository not found|Remote branch .* not found|fatal: .* does not exist'; then
        echo "❌ ERROR: Repository or branch not found while ${operation}."
        echo "   Check URL and branch:"
        echo "   - URL: $ATP_TESTS_GIT_REPO_URL"
        echo "   - Branch: $ATP_TESTS_GIT_REPO_BRANCH"
    else
        echo "❌ ERROR: Failed ${operation} (exit code: $exit_code)."
    fi

    if [ -n "$err_msg" ]; then
        echo "   git: $err_msg"
    fi

    return 1
}

# Git repository cloning module
clone_repository() {
    if [ -d "$TMP_DIR" ] && [ "$(ls -A "$TMP_DIR" 2>/dev/null)" ]; then
        echo "ℹ️ Cloning tests repository is not required, because tests are already in image..."
        _finalize_clone || return 1
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
    if ! command -v git >/dev/null 2>&1; then
        echo "❌ ERROR: git is not installed in the container, cannot clone repository"
        return 1
    fi

    # Basic URL sanity check (no whitespace, http/https)
    if [[ "$ATP_TESTS_GIT_REPO_URL" =~ [[:space:]] ]] || [[ ! "$ATP_TESTS_GIT_REPO_URL" =~ ^https?:// ]]; then
        echo "❌ ERROR: ATP_TESTS_GIT_REPO_URL is invalid URL: $ATP_TESTS_GIT_REPO_URL"
        return 1
    fi

    local git_err_path
    git_err_path="$(mktemp)"
    unset _GIT_INSTEADOF_KEY
    trap '_clear_git_insteadOf; rm -f "$git_err_path"' RETURN

    AUTH_REPO_URL="$ATP_TESTS_GIT_REPO_URL"
    if [[ "$AUTH_REPO_URL" =~ ^https:// ]]; then
        AUTH_REPO_URL=$(echo "$AUTH_REPO_URL" | sed "s|^https://|https://oauth2:${ATP_TESTS_GIT_TOKEN}@|")
    fi

    echo "📥 Cloning repository (branch=${ATP_TESTS_GIT_REPO_BRANCH}, depth=1)..."

    rm -rf "$TMP_DIR"

    git clone \
        --branch "$ATP_TESTS_GIT_REPO_BRANCH" \
        --single-branch \
        --depth 1 \
        "$AUTH_REPO_URL" \
        "$TMP_DIR" 2>"$git_err_path"
    clone_exit=$?
    if [ "$clone_exit" -ne 0 ]; then
        _report_git_fetch_error "$clone_exit" "$git_err_path" "cloning repository"
        return 1
    fi

    cd "$TMP_DIR" || return 1

    if [ -f .gitmodules ]; then
        echo "🔧 Configuring credential substitution for submodule authentication..."

        local git_host
        git_host=$(echo "$ATP_TESTS_GIT_REPO_URL" | sed 's|^https://||; s|/.*||')
        _GIT_INSTEADOF_KEY="url.https://oauth2:${ATP_TESTS_GIT_TOKEN}@${git_host}/.insteadOf"
        git config --global "$_GIT_INSTEADOF_KEY" "https://${git_host}/"

        echo "📥 Initializing submodules (depth=1)..."
        git submodule update --init --recursive --depth 1 2>"$git_err_path"
        submodule_exit=$?
        if [ "$submodule_exit" -ne 0 ]; then
            _report_git_fetch_error "$submodule_exit" "$git_err_path" "initializing submodules"
            return 1
        fi

        _clear_git_insteadOf

        echo "📋 Submodule status after initialization:"
        git submodule status || true
    fi

    echo "✅ Repository cloned to: $TMP_DIR"

    _finalize_clone || return 1

    # Clear Git token from environment for security
    unset ATP_TESTS_GIT_TOKEN
    echo "🔐 Git token cleared from environment"
    echo "✅ Tests repository prepared successfully"
}