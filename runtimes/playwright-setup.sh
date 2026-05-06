#!/bin/bash

# Playwright runtime environment setup module
setup_runtime_environment() {
    log "🔧 Setting up Playwright runtime environment..."
    
    # Node.js runtime setup
    export NODE_PATH=$TMP_DIR/tests:$NODE_PATH
    log "📦 Node.js path set to: $NODE_PATH"
    
    # Copy node_modules from container to temp directory (Playwright-specific)
    log "🔧 Copying dependencies from container..."
    cp -r /app/node_modules $TMP_DIR/node_modules
    # otel-playwright-fixture is installed as an npm symlink (file: package).
    # cp -r preserves symlinks as-is, so the relative target ../lib/otel-playwright-fixture
    # would resolve to $TMP_DIR/lib which does not exist.
    # Copy lib/ to fix the symlink.
    cp -r /app/lib $TMP_DIR/lib

    log "✅ Playwright runtime environment setup completed"
} 