#!/bin/bash

# Simple test runner for update-message-tables.sh functions
# Usage: ./run-tests.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Constants and function definitions (extracted from main script)
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

# Excluded generic terms that should not be treated as proto message names
readonly -A EXCLUDED_GENERIC_TERMS=(
    ["Request"]=1
    ["Response"]=1
    ["Fields"]=1
    ["Operation"]=1
)

# Global associative arrays for proto data
declare -A PROTO_LINKS=()
declare -A PROTO_LOCATIONS=()

# Logging functions
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

# Function to get message location from pre-built map
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
    local field_name="$1"
    local field_type="$2"
    local description="$3"
    local message_name="$4"

    # Clean up description (remove // comments and extra spaces)
    description=$(echo "$description" | sed 's|//||g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    # Default to no link if no description
    [[ -z "$description" ]] && description="No description provided"

    # Create GitHub link for the field type if it exists in our proto links
    local type_link="$field_type"
    if [[ -v "PROTO_LINKS[$field_type]" ]]; then
        type_link="[$field_type](${PROTO_LINKS[$field_type]})"
    fi

    echo "| $field_name | $type_link | $description |"
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

# Test utilities
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

test_assert() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $test_name"
        echo -e "    Expected: '$expected'"
        echo -e "    Got:      '$actual'"
    fi
}

test_assert_contains() {
    local test_name="$1"
    local haystack="$2"
    local needle="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $test_name"
        echo -e "    String '$haystack' does not contain '$needle'"
    fi
}

test_assert_exit_code() {
    local test_name="$1"
    local expected_code="$2"
    local command="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    set +e
    eval "$command" >/dev/null 2>&1
    local actual_code=$?
    set -e

    if [[ $expected_code -eq $actual_code ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $test_name"
        echo -e "    Expected exit code: $expected_code, Got: $actual_code"
    fi
}

# Create test files
setup_test_data() {
    TEST_DIR=$(mktemp -d)

    # Create sample markdown file
    cat > "$TEST_DIR/sample.md" << 'EOF'
# API Reference

## SearchRequest fields

| Field | Protobuf type | Description |
| :---- | :---- | :---- |
| index | string | The index name |
| query | string | The search query |

## ResponseBody fields

| Field | Protobuf type | Description |
| :---- | :---- | :---- |
| hits | repeated Hit | Search results |

### Index

| Field | Protobuf type | Description |
| :---- | :---- | :---- |
| name | string | Index name |

## Regular section

This is just text without a table.
EOF
}

cleanup_test_data() {
    [[ -n "${TEST_DIR:-}" ]] && [[ -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Test basic functions
test_basic_functions() {
    print_header "Testing Basic Functions"

    # Test log functions
    local output
    output=$(log_info "test message")
    test_assert "log_info outputs correctly" "test message" "$output"

    output=$(log_success "test message")
    test_assert "log_success outputs correctly" "✅ test message" "$output"

    # Test handle_result
    output=$(handle_result "true" "success_value" "error_msg")
    test_assert "handle_result success case" "success_value" "$output"

    test_assert_exit_code "handle_result success exit code" 0 "handle_result 'true' 'value'"
    test_assert_exit_code "handle_result failure exit code" 1 "handle_result 'false' 'value'"
}

# Test message name extraction
test_message_name_extraction() {
    print_header "Testing Message Name Extraction"

    # Test regular patterns
    local result
    result=$(extract_message_name_from_header "## SearchRequest fields" 2>/dev/null || echo "")
    test_assert "Extract from ## pattern" "SearchRequest" "$result"

    result=$(extract_message_name_from_header "### ResponseBody fields" 2>/dev/null || echo "")
    test_assert "Extract from ### pattern" "ResponseBody" "$result"

    # Test special patterns
    result=$(extract_message_name_from_header "## Index" 2>/dev/null || echo "")
    test_assert "Extract from special pattern" "IndexOperation" "$result"

    # Test invalid patterns
    result=$(extract_message_name_from_header "## Invalid pattern" 2>/dev/null || echo "")
    test_assert "Invalid pattern returns empty" "" "$result"

    # Test exit codes
    test_assert_exit_code "Valid pattern returns 0" 0 "extract_message_name_from_header '## Test fields'"
    test_assert_exit_code "Invalid pattern returns 1" 1 "extract_message_name_from_header 'invalid'"
}

# Test table generation
test_table_generation() {
    print_header "Testing Table Generation"

    # Test table header
    local header
    header=$(generate_table_header)
    test_assert_contains "Table header contains Field column" "$header" "| Field |"
    test_assert_contains "Table header contains separator" "$header" "| :---- |"

    # Test table row formatting
    PROTO_LINKS["CustomType"]="https://github.com/example/repo/blob/v1.0.0/test.proto#L10"

    local row
    row=$(format_table_row "fieldName" "string" "Field description" "TestMessage")
    test_assert_contains "Table row contains field name" "$row" "| fieldName |"
    test_assert_contains "Table row contains field type" "$row" "| string |"
    test_assert_contains "Table row contains description" "$row" "| Field description |"

    # Test with linked type
    row=$(format_table_row "customField" "CustomType" "Custom field" "TestMessage")
    test_assert_contains "Table row with linked type" "$row" "[CustomType]("
}

# Test file operations
test_file_operations() {
    print_header "Testing File Operations"

    setup_test_data

    # Test find_table_start
    local start_line
    start_line=$(find_table_start "$TEST_DIR/sample.md" 3 2>/dev/null || echo "")
    test_assert "find_table_start finds table" "5" "$start_line"

    # Test find_table_end
    local end_line
    end_line=$(find_table_end "$TEST_DIR/sample.md" 5 2>/dev/null || echo "")
    test_assert "find_table_end finds table end" "8" "$end_line"

    # Test find_table_boundaries
    local boundaries
    boundaries=$(find_table_boundaries "$TEST_DIR/sample.md" 3 2>/dev/null || echo "")
    test_assert "find_table_boundaries returns start:end" "5:8" "$boundaries"

    cleanup_test_data
}

# Test pattern matching
test_patterns() {
    print_header "Testing Pattern Matching"

    # Test MESSAGE_FIELDS_PATTERN
    if [[ "## TestMessage fields" =~ $MESSAGE_FIELDS_PATTERN ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} MESSAGE_FIELDS_PATTERN matches correctly"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} MESSAGE_FIELDS_PATTERN does not match"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))

    # Test TABLE_HEADER_PATTERN
    if [[ "| Field | Protobuf type | Description |" =~ $TABLE_HEADER_PATTERN ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} TABLE_HEADER_PATTERN matches correctly"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} TABLE_HEADER_PATTERN does not match"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))

    # Test PROTO_TYPES_PATTERN
    if [[ "message TestMessage {" =~ ${PROTO_TYPES_PATTERN} ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} PROTO_TYPES_PATTERN matches message"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} PROTO_TYPES_PATTERN does not match message"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Test callback functions
test_callbacks() {
    print_header "Testing Callback Functions"

    setup_test_data

    # Test table start callback
    SECTION_LINE=3
    set +e
    local result
    result=$(_find_table_start_callback 5 "| Field | Protobuf type | Description |" 2>/dev/null)
    local exit_code=$?
    set -e

    test_assert "Table start callback returns line number" "5" "$result"
    test_assert "Table start callback returns 1 (stop)" "1" "$exit_code"

    # Test table end callback
    TABLE_END_LINE=5
    set +e
    _find_table_end_callback 6 "| field1 | string | desc |" >/dev/null 2>&1
    exit_code=$?
    set -e

    test_assert "Table end callback updates TABLE_END_LINE" "6" "$TABLE_END_LINE"
    test_assert "Table end callback returns 0 (continue)" "0" "$exit_code"

    cleanup_test_data
}

# Main test runner
main() {
    echo -e "${YELLOW}🧪 Running Tests for update-message-tables.sh${NC}"
    echo "=============================================="

    # Run all test suites
    test_basic_functions
    test_message_name_extraction
    test_table_generation
    test_file_operations
    test_patterns
    test_callbacks

    # Print summary
    echo -e "\n${BLUE}=== Test Summary ===${NC}"
    echo "Tests run: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    local success_rate=0
    if [[ $TESTS_RUN -gt 0 ]]; then
        success_rate=$(( (TESTS_PASSED * 100) / TESTS_RUN ))
    fi

    echo "Success rate: ${success_rate}%"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}🎉 All tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Some tests failed.${NC}"
        exit 1
    fi
}

# Run tests
main "$@"
