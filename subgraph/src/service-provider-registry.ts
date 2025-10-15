import { log } from "@graphprotocol/graph-ts";
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
import { decodePDPOfferingData, getProviderProductData, getServiceProviderInfo } from "./utils/contract-calls";
import { createProviderProduct, initiateProvider } from "./utils/entity";
import { getProviderProductEntityId } from "./utils/keys";

/**
 * Handles the ProviderRegistered event.
 * @param event The ProviderRegistered event.
 */
export function handleProviderRegistered(event: ProviderRegisteredEvent): void {
  const providerId = event.params.providerId;
  const serviceProvider = event.params.serviceProvider;
  const payee = event.params.payee;

  const serviceProviderRegistryAddress = event.address;
  const providerInfo = getServiceProviderInfo(serviceProviderRegistryAddress, providerId);

  const provider = initiateProvider(providerId, serviceProvider, payee, event.block.timestamp, event.block.number);
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
  let provider = Provider.load(providerInfo.serviceProvider);

  if (provider === null) {
    log.warning("ProviderInfoUpdated: existing provider not found for address: {}", [
      providerInfo.serviceProvider.toHexString(),
    ]);
    return;
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
  const provider = Provider.load(providerInfo.serviceProvider);

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

  const provider = Provider.load(event.params.serviceProvider);

  if (!provider) return;
  provider.totalProducts = provider.totalProducts.plus(BIGINT_ONE);
  provider.save();
}

/**
 * Handles the ProductUpdated event.
 * @param event The ProductUpdated event.
 */
export function handleProductUpdated(event: ProductUpdatedEvent): void {
  const providerId = event.params.providerId;
  const productType = event.params.productType;
  const serviceProvider = event.params.serviceProvider;
  const capabilityKeys = event.params.capabilityKeys;
  const capabilityValues = event.params.capabilityValues;

  const productId = getProviderProductEntityId(serviceProvider, productType);

  const providerProduct = ProviderProduct.load(productId);

  if (!providerProduct) {
    log.warning("Provider product not found for id: {}", [productId]);
    return;
  }

  const productData = getProviderProductData(event.address, providerId, productType);
  const decodedProductData = decodePDPOfferingData(productData);

  providerProduct.capabilityKeys = capabilityKeys;
  providerProduct.capabilityValues = capabilityValues;
  providerProduct.productData = productData;
  providerProduct.decodedProductData = decodedProductData.toJSON();
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
  const productId = getProviderProductEntityId(providerInfo.serviceProvider, productType);
  const providerProduct = ProviderProduct.load(productId);

  if (!providerProduct) {
    log.warning("Provider product not found for id: {}", [productId]);
    return;
  }

  providerProduct.isActive = false;
  providerProduct.save();
}
