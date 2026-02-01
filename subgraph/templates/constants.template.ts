// This file is auto-generated. Do not edit manually.
// Generated from service_contracts/deployments.json for network: {{network}}
// Last generated: {{timestamp}}

import { Address, Bytes } from "@graphprotocol/graph-ts";

export class ContractAddresses {
  static readonly PDPVerifier: Address = Address.fromBytes(
    Bytes.fromHexString("{{PDPVerifier.address}}"),
  );
  static readonly ServiceProviderRegistry: Address = Address.fromBytes(
    Bytes.fromHexString("{{ServiceProviderRegistry.address}}"),
  );
  static readonly FilecoinWarmStorageService: Address = Address.fromBytes(
    Bytes.fromHexString("{{FilecoinWarmStorageService.address}}"),
  );
  static readonly USDFCToken: Address = Address.fromBytes(
    Bytes.fromHexString("{{USDFCToken.address}}"),
  );
}
