#!/bin/bash

# Newman runtime environment setup module
setup_runtime_environment() {
    echo "🔧 Setting up Newman runtime environment..."

    # Node.js runtime setup
    export NODE_PATH="${PROJECT_DIR:-$TMP_DIR}:$NODE_PATH"
    echo "📦 Node.js path set to: $NODE_PATH"

    # Copy node_modules from container to temp directory (Newman-specific)
    echo "🔧 Copying dependencies from container..."
    cp -r /app/node_modules "${PROJECT_DIR:-$TMP_DIR}/node_modules"

    echo "✅ Newman runtime environment setup completed"
}
