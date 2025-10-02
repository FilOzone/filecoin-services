import { PieceAdded as PieceAddedEvent } from "../generated/FilecoinWarmStorageServiceLegacy/FilecoinWarmStorageServiceLegacy";
import { getPieceCidData } from "./utils/contract-calls";
import { ContractAddresses } from "./utils/constants";
import { handlePieceAddedCommon } from "./utils/entity";

/**
 * Handles the PieceAdded event with definition- PieceAdded(indexed uint256,indexed uint256,string[],string[])
 * Parses the pieceCid from the contract and creates a new piece.
 */
export function handlePieceAdded(event: PieceAddedEvent): void {
  const setId = event.params.dataSetId;
  const pieceId = event.params.pieceId;
  const metadataKeys = event.params.keys;
  const metadataValues = event.params.values;

  const pieceBytes = getPieceCidData(ContractAddresses.PDPVerifier, setId, pieceId);

  handlePieceAddedCommon(
    setId,
    pieceId,
    metadataKeys,
    metadataValues,
    pieceBytes,
    event.block.timestamp,
    event.block.number,
  );
}