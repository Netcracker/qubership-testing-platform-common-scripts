#!/usr/bin/env bash

# ============================================
# Extract Bruno collections from string separated by ',' and convert them to an array
# Args:
#   $1 - Input string
#   $2 - Name of the output variable to store the result
# ============================================
extract_bruno_collections() {
    local input="$1"
    local output_var_name="$2"
    local result_array=()

    # Retrieve the array of collections and save it to a temporary array
    local result=$(echo "$input" | jq -r '.execution_list[]?.name')
    # Split the comma-separated string into an array, trimming whitespace
    if [[ -n "$result" ]]; then
        IFS=',' read -ra result_array <<< "$result"
        # Trim leading/trailing spaces for each element
        for i in "${!result_array[@]}"; do
            result_array[$i]=$(echo "${result_array[$i]}" | xargs)
        done
    fi

    # Export the array to a variable with a specified name
    q=''
    for x in "${result_array[@]}"; do
        q+=$(printf ' %q' "$x")
    done
    eval "$output_var_name=(${q# })"

    # Log the result
    local output_message="➡️ Extracted Bruno collections:"
    for collection in "${result_array[@]}"; do
        output_message+="\n    - $collection"
    done
    echo -e "$output_message"
}

# Fill named array with collection root dirs (parent of each collection.bru) under ./collections.
# Args: $1 — name of the bash array variable to populate
discover_bruno_collections() {
    local output_var_name="$1"
    local discovered=()

    echo "🔍 Discovering Bruno collections in 'collections' directory"
    mapfile -t discovered < <(
        find collections -mindepth 2 -maxdepth 2 -type f -name "collection.bru" \
            ! -path "*/.git/*" \
            ! -path "*/node_modules/*" \
            -exec dirname {} \; | sort -u
    )

    q=''
    for x in "${discovered[@]}"; do
        q+=$(printf ' %q' "$x")
    done
    eval "$output_var_name=(${q# })"
}

extract_test_type() {
    local input="$1"
    local output_var_name="$2"
    local result=""

    result=$(echo "$input" | jq -r '.execution_list[]?.type')
    if [[ -n "$result" ]]; then
        eval "$output_var_name=\"$result\""
    fi

    local output_message="➡️ Extracted test type:"
    echo -e "$output_message $result"
}


# Extract Bruno folders from string separated by '|' and convert them to an array
# Args:
#   $1 - Input string
#   $2 - Name of the output variable to store the result
# ============================================
extract_bruno_folders() {
    local input="$1"
    local output_var_name="$2"
    local result_array=()

    # Split input by '|'
    if [[ -n "$input" ]]; then
        IFS='|' read -ra result_array <<< "$input"
        # Trim leading/trailing spaces
        for i in "${!result_array[@]}"; do
            result_array[$i]=$(echo "${result_array[$i]}" | xargs)
        done
    fi

    q=''
    for x in "${result_array[@]}"; do
        q+=$(printf ' %q' "$x")
    done
    eval "$output_var_name=(${q# })"

    local output_message="➡️ Extracted Bruno folders:"
    for folder in "${result_array[@]}"; do
        output_message+="\n    - $folder"
    done
    echo -e "$output_message"
}
