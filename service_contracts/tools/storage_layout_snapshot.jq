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

[
  .types as $types
  | .storage[]
  | {
      label,
      slot,
      offset,
      type: (($types[.type].label // .type) | stable_type_label),
      typeDetails: type_shape($types; .type)
    }
]
