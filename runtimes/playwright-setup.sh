#!/bin/bash

# Playwright runtime environment setup module
setup_runtime_environment() {
    echo "🔧 Setting up Playwright runtime environment..."
    
    # Node.js runtime setup.
    # /app/node_modules is included as a fallback resolution path (not just copied below):
    # a test suite's own start_tests.sh commonly runs its own `npm ci`/`npm install`, which
    # wipes and rebuilds the copy from its own package.json — one with no knowledge of the
    # runner-provided packages (e.g. atp-b3-trace) that were never meant to be published to a
    # registry. NODE_PATH survives that, since it points at a directory the test suite never
    # touches.
    export NODE_PATH="${PROJECT_DIR:-$TMP_DIR}/tests:/app/node_modules:$NODE_PATH"
    echo "📦 Node.js path set to: $NODE_PATH"
    
    # Copy node_modules from container to temp directory (Playwright-specific)
    echo "🔧 Copying dependencies from container..."
    cp -r /app/node_modules "${PROJECT_DIR:-$TMP_DIR}/node_modules"
    
    echo "✅ Playwright runtime environment setup completed"
} 