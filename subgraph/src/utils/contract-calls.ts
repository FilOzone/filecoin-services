import { Address, BigInt, Bytes, log } from "@graphprotocol/graph-ts";
import { ServiceProviderRegistry } from "../../generated/ServiceProviderRegistry/ServiceProviderRegistry";
import { ServiceProviderInfo } from "./types";
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
