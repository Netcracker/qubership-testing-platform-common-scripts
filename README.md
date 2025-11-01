# Qubership Testing Platform Common Scripts

ATP3 submodule for ATP3-runners that contains base bash scripts.

# Modular Test Execution Scripts

This directory contains modular scripts for test execution in containerized environments.

## Architecture Overview

The test execution process is divided into modular components that can be easily maintained and reused across different runtime environments.

### Core Modules

- **`init.sh`** - Environment initialization and secure AWS/S3 configuration
- **`git-clone.sh`** - Repository cloning and extraction (clears Git token)
- **`runtime-setup.sh`** - Runtime-specific environment setup
- **`test-runner.sh`** - Test execution and results collection (clears sensitive vars)
- **`upload-monitor.sh`** - Event-based upload monitoring and finalization
- **`native-report.sh`** - Save native runner report to attachments folder

### Runtime-Specific Modules

Located in `runtimes/` directory for different technology stacks:

- **Python**: `runtimes/python-setup.sh`
- **Playwright**: `runtimes/playwright-setup.sh`

## Usage

### Main Entrypoint

The main `entrypoint.sh` in the root directory coordinates all modules:

```bash
#!/bin/bash
set -e

# Import modular components
source /scripts/init.sh
source /scripts/git-clone.sh
source /scripts/runtime-setup.sh
source /scripts/test-runner.sh
source /scripts/upload-results.sh

# Execute main workflow
init_environment
clone_repository
setup_runtime_environment
run_tests
upload_results
```

**Benefits of root-level entrypoint:**
- Easy customization per image without conflicts
- Can add image-specific logic before/after main workflow
- Clear separation between image-specific and shared logic

### Customizing Entrypoint for Specific Images

You can create image-specific entrypoints by copying and modifying the base entrypoint:

#### Example: Custom Python Entrypoint
```bash
#!/bin/bash
set -e

# Image-specific setup
echo "🐍 Python-specific initialization..."
export PYTHONUNBUFFERED=1

# Import and execute shared modules
source /scripts/init.sh
source /scripts/git-clone.sh
source /scripts/runtime-setup.sh
source /scripts/test-runner.sh
source /scripts/upload-results.sh

# Execute main workflow
init_environment
clone_repository
setup_runtime_environment
run_tests
upload_results

# Image-specific cleanup
echo "🐍 Python-specific cleanup completed"
```

#### Example: Custom Playwright Entrypoint
```bash
#!/bin/bash
set -e

# Image-specific setup
echo "🎭 Playwright-specific initialization..."
export DISPLAY=:99

# Import and execute shared modules
source /scripts/init.sh
source /scripts/git-clone.sh
source /scripts/runtime-setup.sh
source /scripts/test-runner.sh
source /scripts/upload-results.sh

# Execute main workflow
init_environment
clone_repository
setup_runtime_environment
run_tests
upload_results

# Image-specific cleanup
echo "🎭 Playwright-specific cleanup completed"
```

### Creating Runtime-Specific Images

#### Python Image

```dockerfile
FROM python:3.9
COPY scripts/ /scripts/
COPY runtimes/python-setup.sh /scripts/runtime-setup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

#### Playwright Image

```dockerfile
FROM mcr.microsoft.com/playwright:v1.40.0
COPY scripts/ /scripts/
COPY runtimes/playwright-setup.sh /scripts/runtime-setup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

## Environment Variables

### Required Variables
- `ATP_TESTS_GIT_REPO_URL` - Git repository URL
- `ATP_TESTS_GIT_REPO_BRANCH` - Branch to clone
- `ATP_TESTS_GIT_TOKEN` - Git access token
- `ATP_STORAGE_BUCKET` - S3 bucket name
- `ATP_STORAGE_USERNAME` - S3 access key
- `ATP_STORAGE_PASSWORD` - S3 secret key
- `ENVIRONMENT_NAME` - Environment name
- `ATP_STORAGE_PROVIDER` - Storage type (`aws` or `minio` or `s3`)

### Optional Variables
- `CURRENT_DATE` - Override current date
- `CURRENT_TIME` - Override current time
- `ATP_STORAGE_SERVER_URL` - MinIO API host
- `ATP_STORAGE_SERVER_UI_URL` - S3 UI URL
- `PAUSE_BEFORE_END` - Pause before container exit
- `UPLOAD_METHOD` - Upload method: `cp` (file-based) or `sync` (directory-based, triggered by inotifywait)

## Benefits

1. **Modularity** - Each component has a single responsibility
2. **Reusability** - Common logic shared across different runtime images
3. **Maintainability** - Easy to update specific functionality
4. **Flexibility** - Easy to add new runtime support
5. **Testing** - Individual modules can be tested separately
6. **Security** - Sensitive credentials are cleared from environment during test execution
7. **Real-time upload** - Results are uploaded as they are generated using inotifywait
8. **Flexible upload methods** - Choose between file-based (cp) or directory-based (sync) upload, both triggered by inotifywait

## Adding New Runtime Support

1. Create runtime-specific setup script in `runtimes/`
2. Create runtime-specific test runner if needed
3. Update Dockerfile to copy appropriate modules
4. Test with your specific runtime environment 