#!/bin/bash

# Python runtime environment setup module
setup_runtime_environment() {
    log "🔧 Setting up Python runtime environment..."
    
    # Python runtime setup
    export PYTHONPATH=$TMP_DIR/app:$PYTHONPATH
    log "🔍 Python path set to: $PYTHONPATH"
    
    # Install dependencies if requirements.txt exists
    if [ -f "$TMP_DIR/app/requirements.txt" ]; then
        log "📦 Installing Python dependencies..."
        cd $TMP_DIR/app
        pip install -r requirements.txt
    fi
    
    log "✅ Python runtime environment setup completed"
} 