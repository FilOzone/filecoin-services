#!/usr/bin/env bash
#
# Script for comparing Solidity contract sizes between the current branch and the base branch.
# Intended for use in CI to report runtime and init code size changes per EIP-170 compliance.
# Usage: ./tools/compare_contract_sizes.sh <current_sizes.json> <base_sizes.json>
# Requires: jq
#
# Exits 0. Prints table of contract sizes and their delta/status.
# Author: [Your Name]

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <current_sizes.json> <base_sizes.json>"
  exit 1
fi

CURRENT="$1"
BASE="$2"
CONTRACT_SIZE_LIMIT=24576

command -v jq >/dev/null 2>&1 || { echo >&2 "jq is required but not installed."; exit 1; }

printf "| %-60s | %-15s | %-15s | %-10s | %-10s | %-18s |\n" "Contract" "Current Size" "Base Size" "Delta" "% Change" "Status"
printf "| %-.60s | %-.15s | %-.15s | %-.10s | %-.10s | %-.18s |\n" \
  "------------------------------------------------------------" "---------------" "---------------" "----------" "----------" "------------------"

jq -n --rawfile current "$CURRENT" --rawfile base "$BASE" --argjson limit "$CONTRACT_SIZE_LIMIT" '
  def sizes:
    [split("\n")[]
      | fromjson?
      | select(
          type == "object"
          and length > 0
          and all(.[]; type == "object" and has("runtime_size"))
        )]
    | last
    | if . == null then error("no contract size JSON found") else . end;
  def bytes_fmt(n): "\(n) bytes";
  def pct(curr; base; is_new):
    if is_new then "New"
    else if base == 0 then "N/A"
    else (((curr - base) / base) * 100 | tostring + "%")
    end
    end;
  def status(delta; curr; is_new; is_removed):
    if is_new then "New"
    else if is_removed then "Removed"
    else if curr > $limit then "Limit Exceeded"
    else if delta > 0 then "Increased"
    else if delta < 0 then "Decreased"
    else "Unchanged"
    end
    end
    end
    end
    end;

  ($current | sizes) as $current_sizes
  | ($base | sizes) as $base_sizes
  | (($current_sizes | keys) + ($base_sizes | keys) | unique) as $all_keys
  | $all_keys[] as $k
  | {
      contract: $k,
      curr: ($current_sizes[$k].runtime_size // 0),
      base: ($base_sizes[$k].runtime_size // 0),
      is_new: ($base_sizes[$k] == null),
      is_removed: ($current_sizes[$k] == null)
    }
  | .delta = (.curr - .base)
  | {
      c: .contract,
      curr: bytes_fmt(.curr),
      base: bytes_fmt(.base),
      delta: ((if .delta > 0 then "+" else if .delta == 0 then "±" else "" end end) + bytes_fmt(.delta)),
      pct: pct(.curr; .base; .is_new),
      status: status(.delta; .curr; .is_new; .is_removed)
    }
' \
| jq -r '[.c, .curr, .base, .delta, .pct, .status] | @tsv' \
| while IFS=$'\t' read -r c curr base delta pct status; do
    printf "| %-60s | %-15s | %-15s | %-10s | %-10s | %-18s |\n" "$c" "$curr" "$base" "$delta" "$pct" "$status"
done

