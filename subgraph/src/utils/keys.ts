import { Address, BigInt, Bytes } from "@graphprotocol/graph-ts";

export const getProviderProductEntityId = (beneficiary: Address, productType: number): string => {
  return beneficiary.toHexString() + "-" + productType.toString();
};

export function getDataSetEntityId(setId: BigInt): Bytes {
  return Bytes.fromByteArray(Bytes.fromBigInt(setId));
}

export function getPieceEntityId(setId: BigInt, pieceId: BigInt): Bytes {
  return Bytes.fromUTF8(setId.toString() + "-" + pieceId.toString());
}

export function getRailEntityId(railId: BigInt): Bytes {
  return Bytes.fromByteArray(Bytes.fromBigInt(railId));
}

export function getEventLogEntityId(txHash: Bytes, logIndex: BigInt): Bytes {
  return txHash.concatI32(logIndex.toI32());
}

export function getRateChangeQueueEntityId(railId: BigInt, queueLength: BigInt): Bytes {
  return Bytes.fromUTF8(railId.toString() + "-" + queueLength.toString());
}
