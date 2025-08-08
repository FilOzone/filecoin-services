import { Bytes, BigInt, Address } from "@graphprotocol/graph-ts";
import { Rail } from "../../generated/schema";
import { DefaultLockupPeriod, USDFCTokenAddress } from "../../utils";

export function createRails(
  railId: BigInt,
  type: string[],
  from: Address,
  to: Address,
  listenerAddr: Address,
  dataSetId: Bytes
): void {
  for (let i = 0; i < type.length; i++) {
    let rail = new Rail(Bytes.fromByteArray(Bytes.fromBigInt(railId)));
    rail.railId = railId;
    rail.token = Address.fromHexString(USDFCTokenAddress);
    rail.type = type[i];
    rail.from = from;
    rail.to = to;
    rail.operator = listenerAddr;
    rail.arbiter = listenerAddr;
    rail.dataSet = dataSetId;
    rail.paymentRate = BigInt.fromI32(0);
    rail.lockupPeriod = BigInt.fromI32(DefaultLockupPeriod);
    rail.lockupFixed = BigInt.fromI32(0); // lockupFixed - oneTimePayment
    rail.settledUpto = BigInt.fromI32(0);
    rail.endEpoch = BigInt.fromI32(0);
    rail.queueLength = BigInt.fromI32(0);
    rail.save();
  }
}
