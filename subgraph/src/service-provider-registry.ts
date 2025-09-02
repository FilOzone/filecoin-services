import { BigInt, log, store } from "@graphprotocol/graph-ts";
import {
  ProviderRegistered as ProviderRegisteredEvent,
  ProviderInfoUpdated as ProviderInfoUpdatedEvent,
  ProviderRemoved as ProviderRemovedEvent,
  ProductAdded as ProductAddedEvent,
  ProductUpdated as ProductUpdatedEvent,
  ProductRemoved as ProductRemovedEvent,
  BeneficiaryTransferred as BeneficiaryTransferredEvent,
} from "../generated/ServiceProviderRegistry/ServiceProviderRegistry";
import { Provider, ProviderProduct } from "../generated/schema";
import { BIGINT_ONE } from "./utils/constants";
import { getServiceProviderInfo } from "./utils/contract-calls";
import { createProviderProduct, initiateProvider } from "./utils/entity";
import { getProviderProductEntityId } from "./utils/keys";

/**
 * Handles the ProviderRegistered event.
 * @param event The ProviderRegistered event.
 */
export function handleProviderRegistered(event: ProviderRegisteredEvent): void {
  const providerId = event.params.providerId;
  const beneficiary = event.params.beneficiary;

  const serviceProviderRegistryAddress = event.address;
  const providerInfo = getServiceProviderInfo(serviceProviderRegistryAddress, providerId);

  const provider = initiateProvider(providerId, beneficiary, event.block.timestamp, event.block.number);
  provider.registeredAt = event.block.number;
  provider.name = providerInfo.name;
  provider.description = providerInfo.description;
  provider.save();
}

/**
 * Handles the ProviderInfoUpdated event.
 * @param event The ProviderInfoUpdated event.
 */
export function handleProviderInfoUpdated(event: ProviderInfoUpdatedEvent): void {
  const providerId = event.params.providerId;
  const serviceProviderRegistryAddress = event.address;

  const providerInfo = getServiceProviderInfo(serviceProviderRegistryAddress, providerId);
  let provider = Provider.load(providerInfo.beneficiary);

  if (provider === null) {
    provider = new Provider(providerInfo.beneficiary);

    provider.providerId = providerId;
    provider.beneficiary = providerInfo.beneficiary;

    provider.totalFaultedPeriods = BigInt.zero();
    provider.totalFaultedPieces = BigInt.zero();
    provider.totalDataSets = BigInt.zero();
    provider.totalPieces = BigInt.zero();
    provider.totalDataSize = BigInt.zero();

    provider.createdAt = event.block.timestamp;
  }

  provider.name = providerInfo.name;
  provider.description = providerInfo.description;
  provider.updatedAt = event.block.timestamp;
  provider.blockNumber = event.block.number;
  provider.save();
}

/**
 * Handles the ProviderRemoved event.
 * @param event The ProviderRemoved event.
 */
export function handleProviderRemoved(event: ProviderRemovedEvent): void {
  const providerId = event.params.providerId;
  const providerInfo = getServiceProviderInfo(event.address, providerId);
  const provider = Provider.load(providerInfo.beneficiary);

  if (!provider) return;

  provider.isActive = false;
  provider.save();

  const products = provider.products.load();
  products.forEach((product) => {
    product.isActive = false;
    product.save();
  });
}

/**
 * Handles the ProductAdded event.
 * @param event The ProductAdded event.
 */
export function handleProductAdded(event: ProductAddedEvent): void {
  createProviderProduct(event);

  const provider = Provider.load(event.params.beneficiary);

  if (!provider) return;
  provider.totalProducts = provider.totalProducts.plus(BIGINT_ONE);
  provider.save();
}

/**
 * Handles the ProductUpdated event.
 * @param event The ProductUpdated event.
 */
export function handleProductUpdated(event: ProductUpdatedEvent): void {
  const productType = event.params.productType;
  const beneficiary = event.params.beneficiary;
  const capabilityKeys = event.params.capabilityKeys;
  const capabilityValues = event.params.capabilityValues;
  const serviceUrl = event.params.serviceUrl;

  const productId = getProviderProductEntityId(beneficiary, productType);

  const providerProduct = ProviderProduct.load(productId);

  if (!providerProduct) {
    log.warning("Provider product not found for id: {}", [productId]);
    return;
  }

  providerProduct.capabilityKeys = capabilityKeys;
  providerProduct.capabilityValues = capabilityValues;
  providerProduct.serviceUrl = serviceUrl;
  providerProduct.isActive = true;
  providerProduct.save();
}

/**
 * Handles the ProductRemoved event.
 * @param event The ProductRemoved event.
 */
export function handleProductRemoved(event: ProductRemovedEvent): void {
  const providerId = event.params.providerId;
  const productType = event.params.productType;

  const providerInfo = getServiceProviderInfo(event.address, providerId);
  const productId = getProviderProductEntityId(providerInfo.beneficiary, productType);
  const providerProduct = ProviderProduct.load(productId);

  if (!providerProduct) {
    log.warning("Provider product not found for id: {}", [productId]);
    return;
  }

  providerProduct.isActive = false;
  providerProduct.save();
}

/**
 * Handles the BeneficiaryTransferred event.
 * @param event The BeneficiaryTransferred event.
 */
export function handleBeneficiaryTransferred(event: BeneficiaryTransferredEvent): void {
  const providerId = event.params.providerId;
  const previousBeneficiary = event.params.previousBeneficiary;
  const newBeneficiary = event.params.newBeneficiary;

  const previousProvider = Provider.load(previousBeneficiary);
  if (previousProvider) {
    store.remove("Provider", previousBeneficiary.toString());
  }

  const newProvider = initiateProvider(providerId, newBeneficiary, event.block.timestamp, event.block.number);
  if (!previousProvider) {
    return newProvider.save();
  }

  newProvider.status = previousProvider.status;
  newProvider.name = previousProvider.name;
  newProvider.description = previousProvider.description;
  newProvider.registeredAt = previousProvider.registeredAt;
  newProvider.approvedAt = previousProvider.approvedAt;
  newProvider.isActive = previousProvider.isActive;

  newProvider.totalFaultedPeriods = previousProvider.totalFaultedPeriods;
  newProvider.totalFaultedPieces = previousProvider.totalFaultedPieces;
  newProvider.totalDataSets = previousProvider.totalDataSets;
  newProvider.totalPieces = previousProvider.totalPieces;
  newProvider.totalDataSize = previousProvider.totalDataSize;
  newProvider.totalProducts = previousProvider.totalProducts;

  newProvider.createdAt = previousProvider.createdAt;
  newProvider.updatedAt = event.block.timestamp;
  newProvider.blockNumber = event.block.number;

  newProvider.save();

  const dataSets = previousProvider.dataSets.load();
  for (let i = 0; i < dataSets.length; i++) {
    const dataSet = dataSets[i];
    dataSet.storageProvider = newBeneficiary;
    dataSet.save();
  }

  const products = previousProvider.products.load();
  for (let i = 0; i < products.length; i++) {
    const product = products[i];
    product.provider = newBeneficiary;
    product.save();
  }
}
