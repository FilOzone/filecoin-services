#!/usr/bin/env bash
# Check that storage layout changes are additive only.
# Uses the full forge inspect storageLayout JSON metadata to detect:
# - Removing existing storage variables
# - Changing the slot number of an existing variable
# - Changing the type of an existing variable
# - Changing the offset of an existing variable within a slot
# - Inserting new variables in the middle (shifting existing slots)
# Allowed: Appending new variables at the end (highest slot numbers)
#
# Usage: check_storage_layout.sh [<base_layout.json> <new_layout.json>]
#   No args: compares HEAD to working tree
#   Two args: compares base_layout.json to new_layout.json

set -euo pipefail

# Clean up temp files on exit
TEMP_FILES=()
cleanup() { rm -f "${TEMP_FILES[@]:-}" 2>/dev/null || true; }
trap cleanup EXIT

LAYOUT_JSON="src/lib/FilecoinWarmStorageServiceLayout.json"

# Validate that a JSON layout file is well-formed and non-empty
validate_layout_json() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "Error: Layout JSON file not found: $file" >&2
        return 1
    fi

    # Check it's valid JSON array
    if ! jq -e 'type == "array"' "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON layout file: $file" >&2
        return 1
    fi

    local entry_count
    entry_count=$(jq 'length' "$file")
    if [ "$entry_count" -eq 0 ]; then
        echo "Error: No storage entries found in: $file" >&2
        return 1
    fi

    # Check for required fields
    local missing
    missing=$(jq '[.[] | select(.label == null or .slot == null or .offset == null or .type == null)] | length' "$file")
    if [ "$missing" -gt 0 ]; then
        echo "Error: $missing entries missing required fields (label, slot, offset, type) in: $file" >&2
        return 1
    fi

    # Check for duplicate slot+offset combinations
    local dupes
    dupes=$(jq '[group_by(.slot + ":" + (.offset | tostring)) | .[] | select(length > 1)] | length' "$file")
    if [ "$dupes" -gt 0 ]; then
        echo "Error: Duplicate slot+offset combinations found in: $file" >&2
        return 1
    fi

    return 0
}

# Check if two typeDetails JSON blobs are compatible, allowing struct members to be appended.
# Struct members appended at higher slot numbers are permitted; all other changes are not.
typedetails_compatible() {
    local base_td="$1"
    local new_td="$2"

    local result
    result=$(jq -n --argjson base "$base_td" --argjson new "$new_td" '
        def compatible:
            .base as $base | .new as $new |
            if $base == $new then true
            elif (($base | type) == "object") and (($new | type) == "object") then
                if (($base | has("encoding")) and $base.encoding == "inplace" and ($base | has("members"))) and
                   (($new  | has("encoding")) and $new.encoding  == "inplace" and ($new  | has("members"))) then
                    (($new.members | length) >= ($base.members | length)) and
                    ($base.members == ($new.members[0:($base.members | length)]))
                else
                    (($base | keys_unsorted) == ($new | keys_unsorted)) and
                    (reduce ($base | keys_unsorted[]) as $k (true; . and ({base: $base[$k], new: $new[$k]} | compatible)))
                end
            else $base == $new
            end;
        {base: $base, new: $new} | compatible
    ' 2>/dev/null)

    [ "$result" = "true" ]
}

# Compare two JSON layout files and detect destructive changes
compare_layouts() {
    local base_file="$1"
    local new_file="$2"

    local errors=0
    local max_base_slot
    max_base_slot=$(jq '[.[].slot | tonumber] | max // -1' "$base_file")

    local base_count
    base_count=$(jq 'length' "$base_file")
    local new_count
    new_count=$(jq 'length' "$new_file")

    echo "Comparing storage layouts..."
    echo "  Base: $base_file ($base_count entries, max slot: $max_base_slot)"
    echo "  New:  $new_file ($new_count entries)"

    # Check 1: No existing entries removed or modified
    while IFS= read -r entry; do
        local label slot offset type
        label=$(echo "$entry" | jq -r '.label')
        slot=$(echo "$entry" | jq -r '.slot')
        offset=$(echo "$entry" | jq -r '.offset')
        type=$(echo "$entry" | jq -r '.type')

        # Look for entry with same label in new
        local new_entry
        new_entry=$(jq -c --arg l "$label" '.[] | select(.label == $l)' "$new_file")

        if [ -z "$new_entry" ]; then
            # Allow rename where only change is adding the "deprecated" prefix
            local deprecated_label="deprecated${label^}"
            local deprecated_entry
            deprecated_entry=$(jq -c --arg l "$deprecated_label" '.[] | select(.label == $l)' "$new_file")
            if [ -n "$deprecated_entry" ]; then
                local dep_slot dep_offset dep_type
                dep_slot=$(echo "$deprecated_entry" | jq -r '.slot')
                dep_offset=$(echo "$deprecated_entry" | jq -r '.offset')
                dep_type=$(echo "$deprecated_entry" | jq -r '.type')
                if [ "$dep_slot" = "$slot" ] && [ "$dep_offset" = "$offset" ] && [ "$dep_type" = "$type" ]; then
                    echo "  Renamed: '$label' → '$deprecated_label' (slot $slot, deprecated)"
                    continue
                fi
            fi
            echo "  DESTRUCTIVE: Variable '$label' (slot $slot, offset $offset, type $type) was removed" >&2
            errors=$((errors + 1))
            continue
        fi

        local new_slot new_offset new_type
        new_slot=$(echo "$new_entry" | jq -r '.slot')
        new_offset=$(echo "$new_entry" | jq -r '.offset')
        new_type=$(echo "$new_entry" | jq -r '.type')

        local type_comparison new_type_comparison
        if echo "$entry" | jq -e 'has("typeDetails")' >/dev/null && echo "$new_entry" | jq -e 'has("typeDetails")' >/dev/null; then
            type_comparison=$(echo "$entry" | jq -c '.typeDetails')
            new_type_comparison=$(echo "$new_entry" | jq -c '.typeDetails')
        else
            type_comparison=$(echo "$entry" | jq -c '.type')
            new_type_comparison=$(echo "$new_entry" | jq -c '.type')
        fi

        if [ "$slot" != "$new_slot" ]; then
            echo "  DESTRUCTIVE: Variable '$label' slot changed from $slot to $new_slot" >&2
            errors=$((errors + 1))
        fi

        if [ "$offset" != "$new_offset" ]; then
            echo "  DESTRUCTIVE: Variable '$label' offset changed from $offset to $new_offset (slot $slot)" >&2
            errors=$((errors + 1))
        fi

        if [ "$type_comparison" != "$new_type_comparison" ]; then
            if typedetails_compatible "$type_comparison" "$new_type_comparison"; then
                : # struct member(s) appended — allowed
            elif [ "$type" = "$new_type" ]; then
                echo "  DESTRUCTIVE: Variable '$label' type details changed within '$type' (slot $slot)" >&2
                errors=$((errors + 1))
            else
                echo "  DESTRUCTIVE: Variable '$label' type changed from '$type' to '$new_type' (slot $slot)" >&2
                errors=$((errors + 1))
            fi
        fi
    done < <(jq -c '.[]' "$base_file")

    # Check 2: New entries must be appended (slot numbers > max_base_slot)
    while IFS= read -r entry; do
        local label slot
        label=$(echo "$entry" | jq -r '.label')
        slot=$(echo "$entry" | jq -r '.slot')

        # Check if this label existed in base
        local base_match
        base_match=$(jq -c --arg l "$label" '.[] | select(.label == $l)' "$base_file")

        if [ -z "$base_match" ]; then
            # Check if this is a permitted deprecated rename (already reported in Check 1)
            local is_deprecated_rename=false
            if [[ "$label" == deprecated* ]]; then
                local original_label="${label#deprecated}"
                original_label="${original_label,}"
                local base_original
                base_original=$(jq -c --arg l "$original_label" '.[] | select(.label == $l)' "$base_file")
                if [ -n "$base_original" ]; then
                    local orig_slot orig_offset orig_type entry_offset entry_type
                    orig_slot=$(echo "$base_original" | jq -r '.slot')
                    orig_offset=$(echo "$base_original" | jq -r '.offset')
                    orig_type=$(echo "$base_original" | jq -r '.type')
                    entry_offset=$(echo "$entry" | jq -r '.offset')
                    entry_type=$(echo "$entry" | jq -r '.type')
                    if [ "$orig_slot" = "$slot" ] && [ "$orig_offset" = "$entry_offset" ] && [ "$orig_type" = "$entry_type" ]; then
                        is_deprecated_rename=true
                    fi
                fi
            fi

            if $is_deprecated_rename; then
                : # already reported in Check 1
            elif [ "$slot" -le "$max_base_slot" ]; then
                echo "  DESTRUCTIVE: New variable '$label' inserted at slot $slot (must be > $max_base_slot)" >&2
                errors=$((errors + 1))
            else
                local offset type
                offset=$(echo "$entry" | jq -r '.offset')
                type=$(echo "$entry" | jq -r '.type')
                echo "  Added: '$label' at slot $slot (offset $offset, type $type)"
            fi
        fi
    done < <(jq -c '.[]' "$new_file")

    # Report results
    local added=$((new_count - base_count))

    echo ""
    if [ "$errors" -eq 0 ]; then
        echo "Storage layout check passed"
        echo "  Entries: ${base_count} → ${new_count} (+${added} added)"
        return 0
    else
        echo "Storage layout check FAILED (${errors} destructive change(s) detected)" >&2
        return 1
    fi
}

case $# in
    0)
        # No arguments: compare HEAD to working tree
        if [ ! -f "$LAYOUT_JSON" ]; then
            echo "Error: Layout JSON not found: $LAYOUT_JSON" >&2
            echo "       Run 'make gen' from service_contracts/ directory" >&2
            exit 1
        fi

        # Get the base commit (HEAD for regular check, or base branch for PRs)
        if [ -n "${GITHUB_BASE_REF:-}" ]; then
            BASE_REF="origin/$GITHUB_BASE_REF"
        elif git rev-parse --quiet --verify HEAD~1 >/dev/null 2>&1; then
            BASE_REF="HEAD~1"
        else
            echo "Warning: No base commit found, assuming initial commit"
            BASE_REF=""
        fi

        if [ -z "$BASE_REF" ]; then
            # Initial commit - just validate format
            echo "Initial layout detected, validating format only..."
            if validate_layout_json "$LAYOUT_JSON"; then
                echo "Storage layout format validated"
                exit 0
            else
                exit 1
            fi
        fi

        # Get base version (must use repository-root relative path for git show)
        GIT_PREFIX=$(git rev-parse --show-prefix)
        FULL_LAYOUT_JSON="${GIT_PREFIX}${LAYOUT_JSON}"

        TEMP_BASE_LAYOUT=$(mktemp)
        TEMP_FILES+=("$TEMP_BASE_LAYOUT")

        if ! git show "$BASE_REF:$FULL_LAYOUT_JSON" > "$TEMP_BASE_LAYOUT" 2>/dev/null; then
            echo "Warning: Could not retrieve base layout JSON, assuming new file"
            if validate_layout_json "$LAYOUT_JSON"; then
                echo "Storage layout format validated"
                exit 0
            else
                exit 1
            fi
        fi

        # Validate both layouts before comparison
        if ! validate_layout_json "$TEMP_BASE_LAYOUT"; then
            echo "Error: Base layout validation failed" >&2
            exit 1
        fi
        if ! validate_layout_json "$LAYOUT_JSON"; then
            echo "Error: New layout validation failed" >&2
            exit 1
        fi

        compare_layouts "$TEMP_BASE_LAYOUT" "$LAYOUT_JSON"
        ;;

    2)
        # Two arguments: compare base to new
        if ! validate_layout_json "$1"; then
            exit 1
        fi
        if ! validate_layout_json "$2"; then
            exit 1
        fi
        compare_layouts "$1" "$2"
        ;;

    *)
        echo "Usage: $0 [<base_layout.json> <new_layout.json>]" >&2
        echo "" >&2
        echo "  With no args:  Compares HEAD to working tree" >&2
        echo "  With two args: Compares base_layout.json to new_layout.json" >&2
        exit 1
        ;;
esac
