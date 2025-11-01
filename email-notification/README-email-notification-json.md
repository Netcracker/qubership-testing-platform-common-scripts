# JSON Test Results Generator

This set of scripts analyzes test results from the `allure-results` folder and generates JSON files with test outcomes in a predefined format.

## Files

### Main Scripts

1. **`calculate-email-notification-variables.sh`** – Main script for calculating test pass rate (shared with the text version)
2. **`generate-email-notification-json.sh`** – Script for generating JSON files with test results

## Requirements

- Git Bash (for Windows) or Linux/macOS with bash
- `jq` (for JSON parsing)
- `awk` (for calculations and placeholder substitution)

## Usage

### 1. Generate JSON Results

```bash
# Using Git Bash on Windows
& "C:\Program Files\Git\bin\bash.exe" email-notification/generate-email-notification-json.sh

# On Linux/macOS
./email-notification/generate-email-notification-json.sh
```

### 2. Combined Usage

```bash
# First calculate the pass rate
& "C:\Program Files\Git\bin\bash.exe" email-notification/calculate-email-notification-variables.sh

# Then generate the JSON
& "C:\Program Files\Git\bin\bash.exe" email-notification/generate-email-notification-json.sh
```

## Exported Variables

After running `generate-email-notification-json.sh`, these environment variables are available:

- `GENERATED_JSON` – Content of the generated JSON file
- `JSON_FILE` – Path to the generated JSON file

## Environment Variables Used

The script uses the following environment variables to generate JSON:

- `TEST_OVERALL_STATUS` – Overall status
- `TEST_PASS_RATE` – Pass rate in percent (number)
- `TEST_PASS_RATE_ROUNDED` – Rounded pass rate (number)
- `TEST_TOTAL_COUNT` – Total number of tests
- `TEST_PASSED_COUNT` – Passed tests count
- `TEST_FAILED_COUNT` – Failed tests count
- `TEST_SKIPPED_COUNT` – Skipped tests count
- `TEST_FAILURE_RATE` – Failure percentage
- `TEST_COVERAGE` – Test coverage
- `EXECUTION_DATE` – Execution date
- `ENV_NAME` – Environment name
- `REPORT_VIEW_HOST_URL` – Report viewer host
- `ALLURE_REPORT_URL` – Allure report URL
- `TIMESTAMP` – Timestamp
- `TEST_DETAILS_STRING` – String with test details (converted to JSON array)

## JSON Output Structure

```json
{
  "test_results": {
    "overall_status": "PARTIAL",
    "pass_rate": 85.50,
    "pass_rate_rounded": 86,
    "total_count": 20,
    "passed_count": 17,
    "failed_count": 2,
    "skipped_count": 1,
    "failure_rate": 10.00,
    "coverage": 100.00
  },
  "execution_info": {
    "execution_date": "2024-01-15 14:30:25",
    "timestamp": "2024-01-15 14:30:25 UTC",
    "env_name": "staging",
    "report_view_host_url": "https://reports.example.com",
    "allure_report_url": "https://reports.example.com/Report/staging/2024-01-15/14-30-25/allure-report/index.html"
  },
  "test_details": [
    {
      "status": "PASSED",
      "test_name": "User Login Test",
      "emoji": "✅"
    }
  ],
  "environment_variables": { "token1": "value1", "token2": "value2" },
  "environment_variables_description": { "token1": "value1", "token2": "value2" },
  "status_logic": { "token1": "value1", "token2": "value2" }
}
```

## Integration with Other Scripts

Scripts can be integrated into other bash scripts:

### Option 1: Using the function (recommended)

```bash
#!/bin/bash

# Load the script with the function
source ./email-notification/generate-email-notification-json.sh

# Call the function
json_content=$(generate_email_notification_json)

# Use the result
echo "$json_content"

# Or use exported variables
echo "JSON file: $JSON_FILE"
echo "Content: $GENERATED_JSON"

# The file will be saved in: ../email-notification-generated/email-notification-results-generated.json
```

### Function Parameters

The `generate_email_notification_json` function takes no parameters.

**Note:**
- The `./allure-results` folder is used by default.
- The output file is always named `email-notification-results-generated.json` and is saved in the `email-notification-generated` directory one level above the `email-notification` folder.

### Return Values

The function returns:
- **Contents of the generated JSON** (output to stdout)
- **Environment variable `GENERATED_JSON`** - JSON content
- **Environment variable `JSON_FILE`** - path to the JSON file

## Differences from the Text Version

1. **Output Format**: JSON instead of plain text
2. **Structured Data**: Organized into logical sections
3. **Test Array**: Each test represented as a JSON object
4. **Data Types**: Numeric values kept as numbers, not strings
5. **Metadata**: Includes variable descriptions and status logic
6. **No Templates**: JSON generated directly, no text templates used
