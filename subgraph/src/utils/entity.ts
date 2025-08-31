import { Bytes, BigInt, Address } from "@graphprotocol/graph-ts";
import { Provider, ProviderProduct, Rail } from "../../generated/schema";
import { DefaultLockupPeriod, ProviderStatus, ContractAddresses } from "../constants";
import { ProductAdded as ProductAddedEvent } from "../../generated/ServiceProviderRegistry/ServiceProviderRegistry";
import { getProviderProductEntityId } from "./keys";
import { getProviderProductData } from "./contract-calls";

export function createRails(
  railIds: BigInt[],
  type: string[],
  from: Address,
  to: Address,
  listenerAddr: Address,
  dataSetId: Bytes,
): void {
  for (let i = 0; i < type.length; i++) {
    if (railIds[i].isZero()) {
      continue;
    }

    let rail = new Rail(Bytes.fromByteArray(Bytes.fromBigInt(railIds[i])));
    rail.railId = railIds[i];
    rail.token = ContractAddresses.USDFCToken;
    rail.type = type[i];
    rail.from = from;
    rail.to = to;
    rail.operator = listenerAddr;
    rail.arbiter = listenerAddr;
    rail.dataSet = dataSetId;
    rail.paymentRate = BigInt.fromI32(0);
    rail.lockupPeriod = BigInt.fromI32(DefaultLockupPeriod);
    rail.lockupFixed = BigInt.fromI32(0);
    rail.settledUpto = BigInt.fromI32(0);
    rail.endEpoch = BigInt.fromI32(0);
    rail.queueLength = BigInt.fromI32(0);
    rail.save();
  }
}

export function createProviderProduct(event: ProductAddedEvent): void {
  const providerId = event.params.providerId;
  const productType = event.params.productType;
  const beneficiary = event.params.beneficiary;
  const capabilityKeys = event.params.capabilityKeys;
  const capabilityValues = event.params.capabilityValues;
  const serviceUrl = event.params.serviceUrl;

  const productId = getProviderProductEntityId(beneficiary, productType);
  const providerProduct = new ProviderProduct(productId);

  providerProduct.provider = beneficiary;
  providerProduct.serviceUrl = serviceUrl;
  providerProduct.productData = getProviderProductData(event.address, providerId, productType);
  providerProduct.productType = BigInt.fromI32(productType);
  providerProduct.capabilityKeys = capabilityKeys;
  providerProduct.capabilityValues = capabilityValues;
  providerProduct.isActive = true;

  providerProduct.save();
}

export function initiateProvider(
  providerId: BigInt,
  beneficiary: Address,
  timestamp: BigInt,
  blockNumber: BigInt,
): Provider {
  const provider = new Provider(beneficiary);
  provider.providerId = providerId;
  provider.beneficiary = beneficiary;
  provider.name = "";
  provider.description = "";
  provider.status = ProviderStatus.REGISTERED;
  provider.isActive = true;

  provider.totalFaultedPeriods = BigInt.zero();
  provider.totalFaultedPieces = BigInt.zero();
  provider.totalDataSets = BigInt.zero();
  provider.totalPieces = BigInt.zero();
  provider.totalDataSize = BigInt.zero();

  provider.createdAt = timestamp;
  provider.updatedAt = timestamp;
  provider.blockNumber = blockNumber;

  return provider;
}
