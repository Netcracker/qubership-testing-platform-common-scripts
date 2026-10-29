#!/bin/bash

# Bruno runtime environment setup module
setup_runtime_environment() {
    echo "🔧 Setting up Bruno runtime environment..."

    # Node.js runtime setup
    export NODE_PATH="${PROJECT_DIR:-$TMP_DIR}:$NODE_PATH"
    echo "📦 Node.js path set to: $NODE_PATH"

    # Symlink instead of copy: /app/node_modules lives in the image layer and does not
    # count against ephemeral-storage, a copy would write ~300M into the writable layer.
    echo "🔗 Linking dependencies from container..."
    local target="${PROJECT_DIR:-$TMP_DIR}/node_modules"
    if [ ! -e "$target" ]; then
        ln -s /app/node_modules "$target"
    else
        echo "ℹ️ $target already exists, keeping repository node_modules"
    fi

    echo "✅ Bruno runtime environment setup completed"
}
