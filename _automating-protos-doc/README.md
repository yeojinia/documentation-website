# Proto Documentation Automation

Automation tool for updating OpenSearch protobuf documentation tables.

## Introduction

This script automatically finds and updates message field tables in markdown documentation by:
- Finding `## MessageName fields` sections
- Generating tables from proto file definitions
- Adding GitHub links to field types
- Preserving existing markdown formatting

### Patterns It Finds

**Regular Patterns:**
- `# MessageName fields`
- `## MessageName fields`
- `### MessageName fields`

**Special Patterns** (defined in `SPECIAL_SECTION_PATTERNS`):
- `## Index` → Updates `IndexOperation` fields
- `## Create` → Updates `WriteOperation` fields
- `## Update` → Updates `UpdateOperation` fields
- `## Delete` → Updates `DeleteOperation` fields

## Usage

```bash
cd _automating-protos-doc/src

# Update all message field tables
./update-message-tables.sh <version>

# Update specific message only
./update-message-tables.sh <version> <message_name>
```

## Examples

```bash
# Update ALL message field tables for version 0.9.0
./update-message-tables.sh 0.9.0

# Update only SearchRequest tables
./update-message-tables.sh 0.9.0 SearchRequest

# Update only BulkResponseBody tables
./update-message-tables.sh 0.9.0 BulkResponseBody
```

## Adding New Special Cases

To add new special section patterns, edit the `SPECIAL_SECTION_PATTERNS` array in `update-message-tables.sh`:

```bash
readonly -A SPECIAL_SECTION_PATTERNS=(
    ["IndexOperation"]="#+ Index"
    ["WriteOperation"]="#+ Create"
    ["UpdateOperation"]="#+ Update"
    ["DeleteOperation"]="#+ Delete"
    ["YourNewOperation"]="#+ Your New Header"
)
```

This maps markdown section headers to their corresponding proto message names.

## Testing

### Running Tests

The script includes comprehensive unit tests to ensure all functions work correctly:

```bash
cd _automating-protos-doc/tests
./test-update-message-tables.sh
```

### Adding New Tests

To add a new test, follow this pattern:

```bash
test_your_new_function() {
    print_header "Testing Your New Function"

    local result
    result=$(your_function "input")
    test_assert "Test description" "expected_value" "$result"

    test_assert_exit_code "Exit code test" 0 "your_function 'input'"
}
```

Then add `test_your_new_function` to the `main()` function in the test file.
