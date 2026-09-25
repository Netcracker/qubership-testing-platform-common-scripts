#!/bin/bash

# Generate and publish an Allure report in the runner container.

ALLURE_CLI="${ALLURE_CLI:-/app/node_modules/.bin/allure}"
ALLURE_PLACEHOLDER="${ALLURE_PLACEHOLDER:-/scripts/resources/report-generating.html}"

allure_report_url() {
    local base_url="${ATP_REPORT_VIEW_UI_URL%/}"
    printf '%s/Report/%s/%s/%s/allure-report/index.html' \
        "$base_url" "$ENVIRONMENT_NAME" "$CURRENT_DATE" "$CURRENT_TIME"
}

patch_allure_report_styles() {
    local report_dir="$1"
    local trend_hide_css=".duration-trend, .retry-trend, .categories-trend, .history-trend { display: none; }"

    if [[ -f "$report_dir/styles.css" ]]; then
        printf '\n%s\n' "$trend_hide_css" >> "$report_dir/styles.css"
    elif [[ -f "$report_dir/index.html" ]] && grep -q '</head>' "$report_dir/index.html"; then
        sed -i "s|</head>|<style>${trend_hide_css}</style></head>|" "$report_dir/index.html"
    else
        echo "⚠️ Allure style patch skipped: no styles.css or usable index.html"
    fi
}

generate_allure_report() {
    local results_dir="${1:-$TMP_DIR/allure-results}"
    local report_dir="${2:-$TMP_DIR/allure-report}"
    local output

    if [[ ! -x "$ALLURE_CLI" ]]; then
        echo "❌ Allure CLI is unavailable: $ALLURE_CLI"
        return 1
    fi
    if ! compgen -G "$results_dir/*-result.json" > /dev/null 2>&1; then
        echo "⚠️ No Allure result files found in $results_dir; report generation skipped"
        return 0
    fi

    rm -rf -- "$report_dir"
    echo "📊 Generating Allure report..."
    if ! output=$("$ALLURE_CLI" generate "$results_dir" -o "$report_dir" --clean 2>&1); then
        echo "❌ Allure report generation failed"
        echo "$output"
        return 1
    fi

    patch_allure_report_styles "$report_dir"
    echo "✅ Allure report generated"
}

upload_allure_placeholder() {
    if [[ ! -f "$ALLURE_PLACEHOLDER" ]]; then
        echo "⚠️ Allure generation placeholder is unavailable: $ALLURE_PLACEHOLDER"
        return 0
    fi
    s3_upload_file "$ALLURE_PLACEHOLDER" "${REPORTS_S3_PATH}allure-report/index.html"
}

upload_allure_report() {
    local report_dir="${1:-$TMP_DIR/allure-report}"
    local link_file="$TMP_DIR/link_to_report_viewer.txt"

    if [[ ! -d "$report_dir" ]]; then
        echo "ℹ️ No generated Allure report to upload"
        return 0
    fi

    echo "📤 Uploading Allure report..."
    s3_sync_directory "$report_dir" "${REPORTS_S3_PATH}allure-report/" || return 1

    allure_report_url > "$link_file"
    s3_upload_file "$link_file" "${RESULTS_S3_PATH}link_to_report_viewer.txt" || return 1
    echo "✅ Allure report and viewer link uploaded"
}

generate_and_upload_allure_report() {
    if ! compgen -G "$TMP_DIR/allure-results/*-result.json" > /dev/null 2>&1; then
        echo "⚠️ No Allure result files found; runner report generation skipped"
        return 0
    fi
    upload_allure_placeholder || return 1
    generate_allure_report || return 1
    upload_allure_report || return 1
}
