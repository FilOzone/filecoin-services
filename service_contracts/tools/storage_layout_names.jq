# Published layout names stay stable when declarations move or are renamed in source.
# Slots, offsets, widths and recursive member types still compare exactly.

# These two types moved to the shared storage base without changing their representation.
def stable_type_label:
  gsub("FWSSStorage\\.DataSetInfo"; "FilecoinWarmStorageService.DataSetInfo")
  | gsub("FWSSStorage\\.PlannedUpgrade"; "FilecoinWarmStorageService.PlannedUpgrade");

# viewContract became internal so modules do not all export viewContractAddress().
def stable_storage_label:
  if . == "viewContract" then "viewContractAddress" else . end;
