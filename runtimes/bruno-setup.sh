#!/bin/bash

# Bruno runtime environment setup module
setup_runtime_environment() {
    echo "🔧 Setting up Bruno runtime environment..."

    # Node.js runtime setup
    export NODE_PATH="${PROJECT_DIR:-$TMP_DIR}:$NODE_PATH"
    echo "📦 Node.js path set to: $NODE_PATH"

    # Copy node_modules from container to temp directory (Bruno-specific)
    echo "🔧 Copying dependencies from container..."
    cp -r /app/node_modules "${PROJECT_DIR:-$TMP_DIR}"/node_modules

    echo "✅ Bruno runtime environment setup completed"
}
