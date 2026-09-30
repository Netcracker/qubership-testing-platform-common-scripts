#!/bin/bash

# Playwright runtime environment setup module
setup_runtime_environment() {
    echo "🔧 Setting up Playwright runtime environment..."
    
    # Node.js runtime setup.
    # /app/node_modules is an additional resolution path, kept as a defense-in-depth fallback
    # alongside the copies below.
    export NODE_PATH="${PROJECT_DIR:-$TMP_DIR}/tests:/app/node_modules:$NODE_PATH"
    echo "📦 Node.js path set to: $NODE_PATH"

    # Copy node_modules from container to temp directory (Playwright-specific)
    echo "🔧 Copying dependencies from container..."
    cp -r /app/node_modules "${PROJECT_DIR:-$TMP_DIR}/node_modules"

    # A runner-provided helper package (e.g. atp-b3-trace) is installed as an npm "file:"
    # dependency pointing at packages/, so npm links node_modules/<name> to it rather than
    # copying it — and on at least some npm/OS combinations, that link is relative
    # (../packages/<name>). cp -r above preserves the link as-is, so without also copying
    # packages/ itself, a relative link would resolve to a packages/ directory that does not
    # exist under PROJECT_DIR.
    if [ -d /app/packages ]; then
        cp -r /app/packages "${PROJECT_DIR:-$TMP_DIR}/packages"
    fi

    echo "✅ Playwright runtime environment setup completed"
} 