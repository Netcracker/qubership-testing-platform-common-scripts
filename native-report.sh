#!/bin/bash

# Save Runner native report files to attachments
# Usage: save_native_report <source_path>
# Extracts folder name from path after $TMP_DIR and copies folder with its content to attachments
save_native_report() {
    local native_report_path="$1"
    echo "🔧 Saving native report from: ${native_report_path:-<not specified>}"

    if [ -z "$native_report_path" ]; then
        echo "❌ Error: Native report path not provided."
        return 1
    fi

    if [ -d "$native_report_path" ] && [ "$(ls -A "$native_report_path")" ]; then
      # Extract folder name from path (part after $TMP_DIR/)
      local folder_name="${native_report_path#$TMP_DIR/}"
      local dest_path="$TMP_DIR/attachments/$folder_name"
      echo "📦 Copying report files from $native_report_path to $dest_path..."
      mkdir -p "$dest_path"
      cp -r "$native_report_path/." "$dest_path/"
      echo "✅ Native report successfully copied to attachments/$folder_name."
    else
      echo "⚠️ No files found in $native_report_path or directory does not exist."
    fi
}