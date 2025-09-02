import { Address, BigInt, Bytes } from "@graphprotocol/graph-ts";
import { ServiceProviderRegistry } from "../../generated/ServiceProviderRegistry/ServiceProviderRegistry";
import { ServiceProviderInfo } from "./types";
import { PDPVerifier } from "../../generated/PDPVerifier/PDPVerifier";

export function getServiceProviderInfo(registryAddress: Address, providerId: BigInt): ServiceProviderInfo {
  const serviceProviderRegistryInstance = ServiceProviderRegistry.bind(registryAddress);

  const providerInfoTry = serviceProviderRegistryInstance.try_getProvider(providerId);

  if (providerInfoTry.reverted) {
    return new ServiceProviderInfo(Address.zero(), Address.zero(), "", "", false);
  }

  return new ServiceProviderInfo(
    providerInfoTry.value.owner,
    providerInfoTry.value.beneficiary,
    providerInfoTry.value.name,
    providerInfoTry.value.description,
    providerInfoTry.value.isActive,
  );
}

export function getProviderProductData(registryAddress: Address, providerId: BigInt, productType: number): Bytes {
  const serviceProviderRegistryInstance = ServiceProviderRegistry.bind(registryAddress);

  const productDataTry = serviceProviderRegistryInstance.try_getProduct(providerId, i32(productType));

  if (productDataTry.reverted) {
    return Bytes.empty();
  }

  return productDataTry.value.getProductData();
}

export function getPieceCidData(verifierAddress: Address, setId: BigInt, pieceId: BigInt): Bytes {
  const pdpVerifierInstance = PDPVerifier.bind(verifierAddress);

  const pieceCidTry = pdpVerifierInstance.try_getPieceCid(setId, pieceId);

  if (pieceCidTry.reverted) {
    return Bytes.empty();
  }

  return pieceCidTry.value.data;
}
