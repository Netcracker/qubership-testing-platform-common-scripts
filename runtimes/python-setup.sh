#!/bin/bash

# Python runtime environment setup module
setup_runtime_environment() {
    echo "🔧 Setting up Python runtime environment..."
    
    # Python runtime setup
    export PYTHONPATH="${PROJECT_DIR:-$TMP_DIR}/app:$PYTHONPATH"
    echo "🔍 Python path set to: $PYTHONPATH"
    
    # Install dependencies if requirements.txt exists
    if [ -f "${PROJECT_DIR:-$TMP_DIR}/app/requirements.txt" ]; then
        echo "📦 Installing Python dependencies..."
        cd "${PROJECT_DIR:-$TMP_DIR}/app"
        pip install -r requirements.txt
    fi
    
    echo "✅ Python runtime environment setup completed"
} 