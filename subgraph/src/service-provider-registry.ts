import { BigInt, log } from "@graphprotocol/graph-ts";
import {
  ProviderRegistered as ProviderRegisteredEvent,
  ProviderInfoUpdated as ProviderInfoUpdatedEvent,
  ProviderRemoved as ProviderRemovedEvent,
  ProductAdded as ProductAddedEvent,
  ProductUpdated as ProductUpdatedEvent,
  ProductRemoved as ProductRemovedEvent,
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
  const owner = event.params.owner;
  const beneficiary = event.params.beneficiary;

  const serviceProviderRegistryAddress = event.address;
  const providerInfo = getServiceProviderInfo(serviceProviderRegistryAddress, providerId);

  const provider = initiateProvider(providerId, owner, beneficiary, event.block.timestamp, event.block.number);
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

  const provider = Provider.load(event.params.owner);

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
  const owner = event.params.owner;
  const capabilityKeys = event.params.capabilityKeys;
  const capabilityValues = event.params.capabilityValues;
  const serviceUrl = event.params.serviceUrl;

  const productId = getProviderProductEntityId(owner, productType);

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
