include "storage_layout_names";

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
      label: (.label | stable_storage_label),
      slot,
      offset,
      type: (($types[.type].label // .type) | stable_type_label),
      typeDetails: type_shape($types; .type)
    }
]
