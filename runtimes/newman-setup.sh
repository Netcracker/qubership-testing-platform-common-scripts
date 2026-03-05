#!/bin/bash

# Newman runtime environment setup module
setup_runtime_environment() {
    log "🔧 Setting up Newman runtime environment..."

    # Node.js runtime setup
    export NODE_PATH=$TMP_DIR:$NODE_PATH
    log "📦 Node.js path set to: $NODE_PATH"

    # Copy node_modules from container to temp directory (Newman-specific)
    log "🔧 Copying dependencies from container..."
    cp -r /app/node_modules $TMP_DIR/node_modules

    log "✅ Newman runtime environment setup completed"
}
