# These two types moved to the shared storage base without changing their representation.
# Keep snapshot names stable; slots, offsets, widths and recursive member types still compare exactly.
def stable_type_label:
  gsub("FWSSStorage\\.DataSetInfo"; "FilecoinWarmStorageService.DataSetInfo")
  | gsub("FWSSStorage\\.PlannedUpgrade"; "FilecoinWarmStorageService.PlannedUpgrade");

def type_shape($types; $id):
  ($types[$id] // {label: $id}) as $type
  | {
      label: (($type.label // $id) | stable_type_label),
      encoding: ($type.encoding // null),
      numberOfBytes: ($type.numberOfBytes // null)
    }
  + if $type.key then {
      key: type_shape($types; $type.key),
      value: type_shape($types; $type.value)
    } else {} end
  + if $type.base then {
      base: type_shape($types; $type.base)
    } else {} end
  + if $type.members then {
      members: [
        $type.members[]
        | {
            label,
            slot,
            offset,
            type: type_shape($types; .type)
          }
      ]
    } else {} end;

# Internal fields may take a leading underscore to avoid clashing with a same-named getter;
# publish them under the unprefixed label so the layout check and slot constants stay stable.
[
  .types as $types
  | .storage[]
  | {
      label: (.label | ltrimstr("_")),
      slot,
      offset,
      type: (($types[.type].label // .type) | stable_type_label),
      typeDetails: type_shape($types; .type)
    }
]
