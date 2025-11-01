#!/bin/bash

# Playwright runtime environment setup module
setup_runtime_environment() {
    echo "🔧 Setting up Playwright runtime environment..."
    
    # Node.js runtime setup
    export NODE_PATH=$TMP_DIR/tests:$NODE_PATH
    echo "📦 Node.js path set to: $NODE_PATH"
    
    # Copy node_modules from container to temp directory (Playwright-specific)
    echo "🔧 Copying dependencies from container..."
    cp -r /app/node_modules $TMP_DIR/node_modules
    
    echo "✅ Playwright runtime environment setup completed"
} 