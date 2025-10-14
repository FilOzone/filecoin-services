import { Bytes, BigInt, Address } from "@graphprotocol/graph-ts";
import { Provider, ProviderProduct, Rail } from "../../generated/schema";
import { BIGINT_ZERO, ContractAddresses } from "./constants";
import { ProviderStatus } from "./types";
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
    rail.paymentRate = BIGINT_ZERO;
    rail.settledUpto = BIGINT_ZERO;
    rail.settledAmount = BIGINT_ZERO;
    rail.totalFaultedEpochs = BIGINT_ZERO;
    rail.endEpoch = BIGINT_ZERO;
    rail.isActive = true;
    rail.queueLength = BIGINT_ZERO;
    rail.save();
  }
}

export function createProviderProduct(event: ProductAddedEvent): void {
  const providerId = event.params.providerId;
  const productType = event.params.productType;
  const serviceProvider = event.params.serviceProvider;
  const capabilityKeys = event.params.capabilityKeys;
  const capabilityValues = event.params.capabilityValues;

  const productId = getProviderProductEntityId(serviceProvider, productType);
  const providerProduct = new ProviderProduct(productId);

  providerProduct.provider = serviceProvider;
  providerProduct.productData = getProviderProductData(event.address, providerId, productType);
  providerProduct.productType = BigInt.fromI32(productType);
  providerProduct.capabilityKeys = capabilityKeys;
  providerProduct.capabilityValues = capabilityValues;
  providerProduct.isActive = true;

  providerProduct.save();
}

export function initiateProvider(
  providerId: BigInt,
  serviceProvider: Address,
  payee: Address,
  timestamp: BigInt,
  blockNumber: BigInt,
): Provider {
  const provider = new Provider(serviceProvider);
  provider.providerId = providerId;
  provider.serviceProvider = serviceProvider;
  provider.payee = payee;
  provider.name = "";
  provider.description = "";
  provider.status = ProviderStatus.REGISTERED;
  provider.isActive = true;

  provider.totalFaultedPeriods = BIGINT_ZERO;
  provider.totalFaultedPieces = BIGINT_ZERO;
  provider.totalDataSets = BIGINT_ZERO;
  provider.totalPieces = BIGINT_ZERO;
  provider.totalDataSize = BIGINT_ZERO;
  provider.totalProducts = BIGINT_ZERO;

  provider.createdAt = timestamp;
  provider.updatedAt = timestamp;
  provider.blockNumber = blockNumber;

  return provider;
}
