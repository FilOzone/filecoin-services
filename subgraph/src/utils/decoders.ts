import { Bytes, ethereum, log } from "@graphprotocol/graph-ts";
import { PDP_OFFERING_DEF } from "./constants";
import { PDPOffering } from "./types";

export function decodePDPOfferingData(data: Bytes): PDPOffering {
  const decoded = ethereum.decode(PDP_OFFERING_DEF, data);

  if (!decoded) {
    log.warning("[decodePDPOfferingData]: failed to decode data: {}", [data.toHexString()]);
    return PDPOffering.empty();
  }

  const decodedTuple = decoded.toTuple();
  return new PDPOffering(
    decodedTuple[0].toString(),
    decodedTuple[1].toBigInt(),
    decodedTuple[2].toBigInt(),
    decodedTuple[3].toBoolean(),
    decodedTuple[4].toBoolean(),
    decodedTuple[5].toBigInt(),
    decodedTuple[6].toBigInt(),
    decodedTuple[7].toString(),
    decodedTuple[8].toAddress(),
  );
}
