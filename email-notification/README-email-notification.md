# Test Pass Rate Calculator

This set of scripts is designed to analyze test results from the `allure-results` folder and generate reports with the pass rate.

## Files

### Main Scripts

1. **`calculate-email-notification-variables.sh`** – Main script for calculating the test pass rate
2. **`generate-email-notification-file.sh`** – Script for generating a message from a template
3. **`email-notification-body-template.txt`** – Email notification template

### Auxiliary Files

- **`message-template.msg`** – Extended template with conditional blocks (not used in the final version)
- **`generate-message.sh`** – Script for generating a message from a template

## Requirements

- Git Bash (for Windows) or Linux/macOS with bash
- `jq` (for JSON parsing)
- `awk` (for calculations and placeholder replacement)

## Usage

### 1. Calculate the pass rate

```bash
# Using Git Bash in Windows
& "C:\Program Files\Git\bin\bash.exe" email-notification/calculate-email-notification-variables.sh

# On Linux/macOS
./email-notification/calculate-email-notification-variables.sh
```

The script analyzes all `*-result.json` files in the `allure-results` folder and outputs:
- Overall status (PASSED/PARTIAL/FAILED)
- Pass rate in percent
- Number of tests per status
- Exports environment variables

### 2. Generate the message

```bash
# Using Git Bash in Windows
& "C:\Program Files\Git\bin\bash.exe" email-notification/generate-email-notification-file.sh

# With a specified template
& "C:\Program Files\Git\bin\bash.exe" email-notification/generate-email-notification-file.sh "./email-notification/email-notification-body-template.txt"

# On Linux/macOS
./email-notification/generate-email-notification-file.sh
```

### 3. Combined usage

```bash
# First calculate the pass rate
& "C:\Program Files\Git\bin\bash.exe" email-notification/calculate-email-notification-variables.sh

# Then generate the message
& "C:\Program Files\Git\bin\bash.exe" email-notification/generate-email-notification-file.sh
```

## Exported Variables

After running `calculate-email-notification-variables.sh`, the following environment variables are available:

- `TEST_PASS_RATE` – Pass rate with two decimal places (e.g., “50.00”)
- `TEST_PASS_RATE_ROUNDED` – Rounded pass rate (e.g., “50”)
- `TEST_TOTAL_COUNT` – Total number of tests
- `TEST_PASSED_COUNT` – Number of passed tests
- `TEST_FAILED_COUNT` – Number of failed tests
- `TEST_SKIPPED_COUNT` – Number of skipped tests
- `TEST_OVERALL_STATUS` – Overall status (PASSED/PARTIAL/FAILED)

After running `generate-email-notification-file.sh`, the following are also available:

- `GENERATED_MESSAGE` – Content of the generated message
- `MESSAGE_FILE` – Path to the generated message file

## Template Placeholders

In file `email-notification-body-template.txt`, the following placeholders are used:

- `{{TEST_OVERALL_STATUS}}` – Overall status
- `{{TEST_PASS_RATE}}` – Pass rate (%)
- `{{TEST_TOTAL_COUNT}}` – Total number of tests
- `{{TEST_PASSED_COUNT}}` – Number of passed tests
- `{{TEST_FAILED_COUNT}}` – Number of failed tests
- `{{TEST_SKIPPED_COUNT}}` – Number of skipped tests
- `{{TEST_FAILURE_RATE}}` – Failure rate (%)
- `{{TEST_COVERAGE}}` – Test coverage
- `{{EXECUTION_DATE}}` – Execution date
- `{{ENVIRONMENT_NAME}}` – Environment name
- `{{ATP_REPORT_VIEW_UI_URL}}` – Report viewer host
- `{{ALLURE_REPORT_URL}}` – Allure report URL
- `{{TIMESTAMP}}` – Timestamp
- `{{TEST_DETAILS}}` – List of all tests with statuses

## Status Logic

- **PASSED** – 100% of tests passed successfully
- **PARTIAL** – 80–99% passed
- **FAILED** – Less than 80% passed

## Example Output

```
ℹ️ Analyzing test results from: /c/Projects/Cursor AI projects/atp3-common-scripts/allure-results
ℹ️ Processing: 1903d409-587a-44ac-ba5d-b96dfda66c20-result.json
❌ ✗ Comprehensive Jira integration test - FAILING @pipeline_job
ℹ️ Processing: 41085784-d601-466e-b9b3-929d73d12100-result.json
✅ ✓ Comprehensive Jira integration test @pipeline_job

ℹ️ === Test Results Summary ===
Overall Status: FAILED
Pass Rate: 50.00%
Total Tests: 2
Passed: 1
Failed: 1
Skipped: 0
```

## Integration with Other Scripts

Scripts can be integrated into other bash scripts:

### Option 1: Using the function (recommended)

```bash
#!/bin/bash

# Load the script with the function
source ./email-notification/generate-email-notification-file.sh

# Call the function with parameters
message_content=$(generate_email_notification_file \
    "./email-notification/email-notification-body-template.txt")

# Use the result
echo "$message_content"

# Or use exported variables
echo "Message file: $MESSAGE_FILE"
echo "Content: $GENERATED_MESSAGE"

# The file will be saved in: ../email-notification-generated/email-notification-body-template-generated.txt
```

### Option 2: Using `source` (deprecated)

```bash
#!/bin/bash

# Loading the pass rate calculation results
source ./email-notification/calculate-email-notification-variables.sh

# Using variables
echo "Pass rate: $TEST_PASS_RATE%"
echo "Status: $TEST_OVERALL_STATUS"

# Generate a message
source ./email-notification/generate-email-notification-body-message.sh

# Use the generated message
echo "$GENERATED_MESSAGE"
```

### Function Parameters

The `generate_email_notification_file` function accepts the following parameters:

1. **template_file** (optional) – path to the template file
   - Default: `./email-notification/email-notification-body-template.txt`

**Note:**
- The Allure results folder is always used by default: `./allure-results`
- The output file name is generated automatically based on the template name. The file is saved in the `email-notification-generated` directory, one level above the `email-notification` folder. For example, if the template is named `my-template.txt`, the output file will be `../email-notification-generated/my-template-generated.txt`.

### Return Values

The function returns:
- **The content of the generated message** (printed to stdout)
- **Environment variable `GENERATED_MESSAGE`** – contains the message content
- **Environment variable `MESSAGE_FILE`** – path to the generated message file
