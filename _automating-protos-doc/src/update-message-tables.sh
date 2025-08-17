#!/bin/bash

set -euo pipefail

# Script to update "### <message name> fields" tables in markdown files
# with tables generated from proto definitions

TAG="${1:-}"
MESSAGE_NAME="${2:-}"

# Constants
readonly OWNER="opensearch-project"
readonly REPO="opensearch-protobufs"
readonly DOCS_DIR="_api-reference/grpc-apis"

# GitHub URLs
readonly GITHUB_BASE_URL="https://github.com"
readonly GITHUB_DOWNLOAD_URL="https://codeload.github.com"

# File extensions
readonly TARBALL_EXT=".tar.gz"
readonly PROTO_EXT=".proto"
readonly MARKDOWN_EXT=".md"

# Directory names
readonly PROTO_SUBDIR="protos"
readonly TEMP_DIR_PREFIX="temp_proto_"

# Table header pattern: generic pattern for all message fields
readonly MESSAGE_FIELDS_PATTERN='^(#+)[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*fields$'
readonly TABLE_HEADER_PATTERN='^\|[[:space:]]*Field[[:space:]]*\|[[:space:]]*Protobuf[[:space:]]*type[[:space:]]*\|[[:space:]]*Description[[:space:]]*\|'

# Proto type declarations pattern
readonly PROTO_TYPES_PATTERN='(message|enum|service|rpc)'

# Message definition pattern (for parsing message contents)
readonly MESSAGE_DEF_PATTERN='^message[[:space:]]+'

# Table header pattern for special cases: message types that use different section patterns
readonly -A SPECIAL_SECTION_PATTERNS=(
    ["IndexOperation"]="#+ Index"
    ["WriteOperation"]="#+ Create"
    ["UpdateOperation"]="#+ Update"
    ["DeleteOperation"]="#+ Delete"
)

# Global variables
PROTO_DIR=""
declare -A PROTO_LINKS      # Maps message_name, enum_name, service_name, rpc_name -> github link
declare -A PROTO_LOCATIONS  # Maps message_name, enum_name, service_name, rpc_name -> file_path:line_number

# Logging helpers
log_info() {
    echo "$@"
}

log_error() {
    echo "$@" >&2
}

log_success() {
    echo "✅ $@"
}

# Utility function for iterating file lines with callback
iterate_file_lines() {
    local file="$1"
    local start_line="${2:-1}"
    local callback_func="$3"

    local total_lines=$(wc -l < "$file")
    local current_line=$start_line

    while [[ $current_line -le $total_lines ]]; do
        local line_content=$(sed -n "${current_line}p" "$file")
        if ! "$callback_func" "$current_line" "$line_content"; then
            break
        fi
        current_line=$((current_line + 1))
    done
}

# Common error handling function
handle_result() {
    local success="$1"
    local success_value="${2:-}"
    local error_msg="${3:-}"

    if [[ "$success" == "true" ]]; then
        [[ -n "$success_value" ]] && echo "$success_value"
        return 0
    else
        [[ -n "$error_msg" ]] && log_info "$error_msg"
        return 1
    fi
}

# Function to build proto links map and locations from extracted files
build_proto_maps() {
    local version="$1"

    log_info "Building proto type map..."

    # Clear the maps first
    PROTO_LINKS=()
    PROTO_LOCATIONS=()

    if [[ -d "${PROTO_DIR}/${PROTO_SUBDIR}" ]]; then
        while IFS= read -r -d '' file; do
            local relative_path="${file#${PROTO_DIR}/}"

            # Search for message, enum, service, and rpc declarations
            local grep_result=$(grep -nE "^[[:space:]]*${PROTO_TYPES_PATTERN}[[:space:]]+" "$file" 2>/dev/null || true)
            if [[ -n "$grep_result" ]]; then
                while IFS=: read -r line_num line_content; do
                    # Use a single regex to capture the type name
                    if [[ "$line_content" =~ ^[[:space:]]*${PROTO_TYPES_PATTERN}[[:space:]]+([A-Za-z0-9_]+) ]]; then
                        local type_name="${BASH_REMATCH[2]}"
                        local github_link="${GITHUB_BASE_URL}/${OWNER}/${REPO}/blob/${version}/${relative_path}#L${line_num}"
                        PROTO_LINKS["$type_name"]="$github_link"
                        PROTO_LOCATIONS["$type_name"]="${file}:${line_num}"
                    fi
                done <<< "$grep_result"
            fi
        done < <(find "${PROTO_DIR}/${PROTO_SUBDIR}" -name "*${PROTO_EXT}" -print0)
    fi

    local count=${#PROTO_LINKS[@]}
    log_info "Found $count proto types"
}

# Function to download and extract proto files
download_proto_files() {
    local version="$1"
    local tarball="${version}${TARBALL_EXT}"

    # Set global PROTO_DIR to temp directory outside of src
    PROTO_DIR="$(cd .. && pwd)/${TEMP_DIR_PREFIX}${version}_$$"


    log_info "Downloading proto files for version $version..."
    local url="${GITHUB_DOWNLOAD_URL}/${OWNER}/${REPO}/tar.gz/${version}"

    # Download tarball
    rm -f "$tarball"
    if ! curl -L -o "$tarball" "$url"; then
        log_error "Failed to download proto files from $url"
        return 1
    fi

    # Extract tarball
    log_info "Extracting proto files..."
    mkdir -p "$PROTO_DIR"
    if ! tar -xzf "$tarball" --directory "$PROTO_DIR" --strip-components=1; then
        log_error "Failed to extract proto files from $tarball"
        rm -rf "$PROTO_DIR"
        return 1
    fi

    log_success "Proto files downloaded and extracted to $PROTO_DIR"
}

# Function to find sections for a specific message
find_specific_message_sections() {
    local file="$1"
    local message_name="$2"
    local search_pattern=""

    # Check if this is a special case and set the appropriate pattern.
    if [[ -n "${SPECIAL_SECTION_PATTERNS[$message_name]:-}" ]]; then
        search_pattern="^${SPECIAL_SECTION_PATTERNS[$message_name]}$"
    else
        # If not a special case, build a single regex to find the specific message name.
        search_pattern="^(#+)[[:space:]]+${message_name}[[:space:]]+fields$"
    fi

    # Run a single grep command with the constructed pattern.
    grep -nE "$search_pattern" "$file" || true
}


# Function to find all message field sections
find_all_message_sections() {
    local file="$1"

    # Find regular "# MessageName fields" sections
    local regular_sections=$(grep -nE "$MESSAGE_FIELDS_PATTERN" "$file" || true)

    # Combine special case patterns into a single regex
    local special_patterns_regex=$(printf "|%s" "${SPECIAL_SECTION_PATTERNS[@]}")
    special_patterns_regex="^(${special_patterns_regex:1})$"

    # Find all special case sections with a single grep command
    local special_sections=$(grep -nE "$special_patterns_regex" "$file" || true)

    # Combine results
    local all_sections=""
    if [[ -n "$regular_sections" ]]; then
        all_sections="$regular_sections"
    fi
    if [[ -n "$special_sections" ]]; then
        if [[ -n "$all_sections" ]]; then
            all_sections="${all_sections}"$'\n'"${special_sections}"
        else
            all_sections="$special_sections"
        fi
    fi

    echo "$all_sections"
}

# Function to extract message name from section header
extract_message_name_from_header() {
    local section_text="$1"

    # Check regular pattern first (# MessageName fields)
    if [[ "$section_text" =~ $MESSAGE_FIELDS_PATTERN ]]; then
        local message_name="${BASH_REMATCH[2]}"  # The message name is in the second capture group
        handle_result "true" "$message_name"
        return $?
    fi

    # Check special cases (## Index -> IndexOperation, etc.)
    for message_name in "${!SPECIAL_SECTION_PATTERNS[@]}"; do
        local pattern="${SPECIAL_SECTION_PATTERNS[$message_name]}"
        if [[ "$section_text" =~ ^${pattern}$ ]]; then
            handle_result "true" "$message_name"
            return $?
        fi
    done

    handle_result "false" "" ""
    return $?
}

# Function to find and return sections with their types
find_sections_to_process() {
    local file="$1"
    local specific_message="$2"

    local section_type sections=""
    if [[ -n "$specific_message" ]]; then
        # Handle specific message case
        section_type="${SPECIAL_SECTION_PATTERNS[$specific_message]:-"'${specific_message} fields'"}"
        sections=$(find_specific_message_sections "$file" "$specific_message")
    else
        # Handle all messages case
        section_type="message field, enum, service, rpc"
        sections=$(find_all_message_sections "$file")
    fi

    # Return both section_type and sections separated by a delimiter
    echo "${section_type}|${sections}"
}


# Function to find table sections from markdown files
find_table_sections_from_md() {
    local file="$1"
    local specific_message="$2"

    # Get sections and section type
    local result=$(find_sections_to_process "$file" "$specific_message")
    local section_type="${result%%|*}"
    local sections="${result#*|}"

    if [[ -z "$sections" ]]; then
        log_info "  No ${section_type} sections found"
        return 1
    fi

    # Sort sections by line number in descending order for bottom-up processing
    local sorted_sections=$(echo "$sections" | sort -n -r)

    # Return the sorted sections and section type
    echo "${section_type}|${sorted_sections}"
    return 0
}

# Function to update tables in markdown files
update_tables_in_md() {
    local file="$1"
    local specific_message="$2"
    local section_type="$3"
    local sorted_sections="$4"

    log_info "Processing $file..."

    local sections_found=false

    # Process each section from the bottom up
    while IFS=: read -r line_num section_text; do
        # Get message name: use specific_message if provided, otherwise extract from header
        local message_name="${specific_message:-$(extract_message_name_from_header "$section_text")}"
        [[ -n "$message_name" ]] || continue

        log_info "  Found '# ${message_name} fields' at line $line_num"
        if update_single_section "$file" "$line_num" "$message_name"; then
            sections_found=true
        fi
    done <<< "$sorted_sections"

    if [[ "$sections_found" == "false" ]]; then
        log_info "  No ${section_type} sections found"
    else
        log_info "  ✅ Processed $file"
    fi

    return 0
}

# Function to get message location from pre-built map
# Returns: "file_path:line_number" or empty string if not found
get_message_location() {
    local message_name="$1"

    if [[ -v "PROTO_LOCATIONS[$message_name]" ]]; then
        handle_result "true" "${PROTO_LOCATIONS[$message_name]}"
    else
        handle_result "false" ""
    fi
    return $?
}

# Function to generate markdown table header
generate_table_header() {
    echo "| Field | Protobuf type | Description |"
    echo "| :---- | :---- | :---- |"
}

# Function to format a table row with proper type linking
format_table_row() {
    local field_name="$1"     # field name from proto file
    local field_type="$2"     # protobuf type
    local modifier="$3"       # optional, required, repeated
    local comment="$4"        # comment from proto file

    # Clean up field_type
    field_type=$(echo "$field_type" | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')

    # Clean up comment
    comment=$(echo "$comment" | sed 's/\[optional\][[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    # Build the complete type with links
    local type_with_link=""
    if [[ -v "PROTO_LINKS[$field_type]" ]]; then
        type_with_link="[\`${field_type}\`](${PROTO_LINKS[$field_type]})"
    else
        type_with_link="\`${field_type}\`"
    fi

    local complete_type=""
    if [[ -n "$modifier" ]]; then
        complete_type="\`${modifier}\` ${type_with_link}"
    else
        complete_type="${type_with_link}"
    fi

    # Output the table row
    echo "| \`${field_name}\` | ${complete_type} | ${comment} |"
}

# Function to extract comments
extract_comment() {
    local line="$1"
    local -n pending_comment_ref="$2"  # Pass by reference

    if [[ "$line" =~ ^[[:space:]]*// ]]; then
        local comment_text="${line#*//}"
        comment_text="${comment_text# }"  # Remove leading space

        if [[ -n "$pending_comment_ref" ]]; then
            pending_comment_ref="${pending_comment_ref} ${comment_text}"
        else
            pending_comment_ref="$comment_text"
        fi
        return 0  # Comment was collected
    fi
    return 1  # Not a comment line
}

# Function to extract and process field definitions
extract_field_definition() {
    local line="$1"
    local pending_comment="$2"
    local -n pending_comment_ref="$3"  # Pass by reference to reset it

    if [[ "$line" =~ ^[[:space:]]*(optional|required|repeated)?[[:space:]]*([A-Za-z0-9_\.<>,[:space:]]+)[[:space:]]+([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*[0-9]+ ]]; then
        local modifier="${BASH_REMATCH[1]}"
        local field_type="${BASH_REMATCH[2]}"
        local field_name="${BASH_REMATCH[3]}"

        format_table_row "$field_name" "$field_type" "$modifier" "$pending_comment"

        pending_comment_ref=""  # Reset after using
        return 0  # Field was processed
    fi
    return 1  # Not a field definition
}

# Function to extract fields from message definition
extract_message_fields() {
    local message_name="$1"
    local message_file="$2"
    local start_line="$3"

    local in_message=false
    local brace_count=0
    local pending_comment=""

    # Start reading from the specific line where the message is defined
    # This is much more efficient than reading the entire file from the beginning
    while IFS= read -r line; do
        # Check if this is the start of our message
        if [[ "$line" =~ ${MESSAGE_DEF_PATTERN}${message_name}[[:space:]]*\{ ]]; then
            in_message=true
            brace_count=1
            continue
        fi

        if [[ "$in_message" == "true" ]]; then
            # Count braces to track nesting
            local open_braces=$(echo "$line" | tr -cd '{' | wc -c)
            local close_braces=$(echo "$line" | tr -cd '}' | wc -c)
            brace_count=$((brace_count + open_braces - close_braces))

            # Check if we've reached the end of the message
            if [[ $brace_count -eq 0 ]]; then
                break
            fi

            # Try to extract comments first
            if extract_comment "$line" pending_comment; then
                continue  # Comment was collected, skip to next line
            fi

            # Try to extract field definitions
            if extract_field_definition "$line" "$pending_comment" pending_comment; then
                # Field was processed, continue to next line
                continue
            fi

            # If it's neither a comment nor a field definition, reset pending comment
            pending_comment=""
        fi
    done < <(tail -n +${start_line} "$message_file")
}

# Function to generate new table content
generate_table_content() {
    local message_name="$1"

    # Get the message location from pre-built map
    local message_location=""
    if ! message_location=$(get_message_location "$message_name"); then
        log_info "      Message $message_name not found in proto files - skipping"
        return 1  # Return failure so update_single_section can handle it
    fi

    # Parse file path and line number
    local message_file="${message_location%:*}"
    local start_line="${message_location#*:}"

    # Generate the complete table
    generate_table_header
    extract_message_fields "$message_name" "$message_file" "$start_line"
}

# Callback function for finding table start
_find_table_start_callback() {
    local current_line="$1"
    local line_content="$2"

    # Check if this is the table header
    if [[ "$line_content" =~ $TABLE_HEADER_PATTERN ]]; then
        echo "$current_line"
        return 1  # Stop iteration (success)
    fi

    # Stop if we hit another section or end of relevant content
    if [[ "$line_content" =~ ^#+ ]] && [[ $current_line -gt $(($SECTION_LINE + 1)) ]]; then
        return 1  # Stop iteration (not found)
    fi

    return 0  # Continue iteration
}

# Function to find table start line
find_table_start() {
    local file="$1"
    local section_line="$2"

    # Set global variable for callback to access
    SECTION_LINE="$section_line"

    local result
    if result=$(iterate_file_lines "$file" $((section_line + 1)) "_find_table_start_callback"); then
        echo "$result"
        return 0
    fi

    return 1
}

# Callback function for finding table end
_find_table_end_callback() {
    local current_line="$1"
    local line_content="$2"

    # If a line starts with a pipe character
    if [[ "$line_content" =~ ^\| ]]; then
        TABLE_END_LINE=$current_line
    elif [[ -n "${line_content// }" ]]; then
        # Non-empty line that's not part of the table
        return 1  # Stop iteration
    fi

    return 0  # Continue iteration
}

# Function to find table end line
find_table_end() {
    local file="$1"
    local table_start="$2"

    # Initialize global variable for callback to access
    TABLE_END_LINE=$table_start

    iterate_file_lines "$file" $((table_start + 1)) "_find_table_end_callback"

    echo "$TABLE_END_LINE"
}

# Combined function to find both table start and end boundaries
find_table_boundaries() {
    local file="$1"
    local section_line="$2"

    # First find the table start
    SECTION_LINE="$section_line"
    local table_start
    if ! table_start=$(iterate_file_lines "$file" $((section_line + 1)) "_find_table_start_callback"); then
        return 1
    fi

    # Then find the table end using the start we just found
    TABLE_END_LINE=$table_start
    iterate_file_lines "$file" $((table_start + 1)) "_find_table_end_callback"

    # Return both as "start:end"
    echo "${table_start}:${TABLE_END_LINE}"
    return 0
}

# Function to replace table in file using consolidated awk operation
replace_table_in_file() {
    local file="$1"
    local table_start="$2"
    local table_end="$3"
    local new_table="$4"
    local temp_file="${file}.tmp"

    # Use awk for efficient single-pass file processing
    awk -v start="$table_start" -v end="$table_end" -v new_table="$new_table" '
        NR < start { print }
        NR == start { print new_table }
        NR > end { print }
    ' "$file" > "$temp_file"

    # Replace the original file
    mv "$temp_file" "$file"
}

# Function to update a single section
update_single_section() {
    local file="$1"
    local line_num="$2"
    local message_name="$3"

    log_info "      Detected message: $message_name"

    # Generate the new table
    local new_table
    if ! new_table=$(generate_table_content "$message_name"); then
        log_info "      Failed to generate table for $message_name - skipping"
        return 0  # Return success to continue processing other sections
    fi

    # Find the existing table boundaries
    local table_boundaries
    if ! table_boundaries=$(find_table_boundaries "$file" "$line_num"); then
        log_info "      No existing table found after this section - skipping"
        return 0  # Return success to continue processing other sections
    fi

    local table_start_line="${table_boundaries%%:*}"
    local table_end_line="${table_boundaries##*:}"

    log_info "      Replacing table from line $table_start_line to $table_end_line"

    # Replace the table
    replace_table_in_file "$file" "$table_start_line" "$table_end_line" "$new_table"

    log_info "      ✅ Updated table for $message_name"
    return 0
}

# Function to cleanup downloaded proto files
cleanup_downloaded_files() {
    local tag="$1"

    if [[ -n "$PROTO_DIR" ]] && [[ -d "$PROTO_DIR" ]]; then
        log_info "Cleaning up downloaded files..."
        rm -rf "$PROTO_DIR"
        rm -f "${tag}${TARBALL_EXT}"
        log_info "Cleanup completed"
    fi
}

# Main function
main() {
    # Change to documentation root and validate directory
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
    [[ -d "$DOCS_DIR" ]] || { log_error "Directory $DOCS_DIR not found"; exit 1; }

    # Download proto files once at the beginning
    if ! download_proto_files "$TAG"; then
        log_error "Failed to download proto files for version $TAG"
        exit 1
    fi

    # Build proto links map once
    build_proto_maps "$TAG"

    local target="${MESSAGE_NAME:-all message}"
    log_info "Updating '${target} fields' tables... from Tag: $TAG"
    log_info ""

    # Process all markdown files in the directory
    while IFS= read -r -d '' md_file; do
        # Find table sections
        local sections_result
        if sections_result=$(find_table_sections_from_md "$md_file" "$MESSAGE_NAME"); then
            local section_type="${sections_result%%|*}"
            local sorted_sections="${sections_result#*|}"

            # Update tables
            update_tables_in_md "$md_file" "$MESSAGE_NAME" "$section_type" "$sorted_sections"
        fi
    done < <(find "$DOCS_DIR" -name "*${MARKDOWN_EXT}" -type f -print0)

    log_info ""
    log_success "'# ${target} fields' table updates completed"

    # Cleanup downloaded files
    cleanup_downloaded_files "$TAG"
}
# Main execution
main
