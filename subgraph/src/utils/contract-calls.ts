import { Address, BigInt, Bytes, log } from "@graphprotocol/graph-ts";
import { ServiceProviderRegistry } from "../../generated/ServiceProviderRegistry/ServiceProviderRegistry";
import { PDPOffering, ServiceProviderInfo } from "./types";
import { PDPVerifier } from "../../generated/PDPVerifier/PDPVerifier";

export function getServiceProviderInfo(registryAddress: Address, providerId: BigInt): ServiceProviderInfo {
  const serviceProviderRegistryInstance = ServiceProviderRegistry.bind(registryAddress);

  const providerInfoTry = serviceProviderRegistryInstance.try_getProvider(providerId);

  if (providerInfoTry.reverted) {
    log.warning("getServiceProviderInfo: contract call reverted for providerId: {}", [providerId.toString()]);
    return new ServiceProviderInfo(Address.zero(), Address.zero(), "", "", false);
  }

  return new ServiceProviderInfo(
    providerInfoTry.value.info.serviceProvider,
    providerInfoTry.value.info.payee,
    providerInfoTry.value.info.name,
    providerInfoTry.value.info.description,
    providerInfoTry.value.info.isActive,
  );
}

export function getProviderProductData(registryAddress: Address, providerId: BigInt, productType: number): Bytes {
  const serviceProviderRegistryInstance = ServiceProviderRegistry.bind(registryAddress);

  const productDataTry = serviceProviderRegistryInstance.try_getProduct(providerId, i32(productType));

  if (productDataTry.reverted) {
    log.warning("getProviderProductData: contract call reverted for providerId: {}", [providerId.toString()]);
    return Bytes.empty();
  }

  return productDataTry.value.getProductData();
}

export function getPieceCidData(verifierAddress: Address, setId: BigInt, pieceId: BigInt): Bytes {
  const pdpVerifierInstance = PDPVerifier.bind(verifierAddress);

  const pieceCidTry = pdpVerifierInstance.try_getPieceCid(setId, pieceId);

  if (pieceCidTry.reverted) {
    log.warning("getPieceCidData: contract call reverted for setId: {} and pieceId: {}", [
      setId.toString(),
      pieceId.toString(),
    ]);
    return Bytes.empty();
  }

  return pieceCidTry.value.data;
}

export function decodePDPOfferingData(registryAddress: Address, data: Bytes): PDPOffering {
  const serviceProviderRegistryInstance = ServiceProviderRegistry.bind(registryAddress);

  const pdpOfferingTry = serviceProviderRegistryInstance.try_decodePDPOffering(data);

  if (pdpOfferingTry.reverted) {
    log.warning("decodePDPOfferingData: contract call reverted for data: {}", [data.toHexString()]);
    return PDPOffering.empty();
  }

  return new PDPOffering(
    pdpOfferingTry.value.serviceURL,
    pdpOfferingTry.value.minPieceSizeInBytes,
    pdpOfferingTry.value.maxPieceSizeInBytes,
    pdpOfferingTry.value.ipniPiece,
    pdpOfferingTry.value.ipniIpfs,
    pdpOfferingTry.value.storagePricePerTibPerMonth,
    pdpOfferingTry.value.minProvingPeriodInEpochs,
    pdpOfferingTry.value.location,
    pdpOfferingTry.value.paymentTokenAddress,
  );
}
