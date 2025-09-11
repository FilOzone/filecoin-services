import { Address, Bytes, BigInt } from "@graphprotocol/graph-ts";

export const NumChallenges = 5;

export const LeafSize = 32;

export const DefaultLockupPeriod = 2880 * 10; // 10 days

export const BIGINT_ZERO = BigInt.zero();
export const BIGINT_ONE = BigInt.fromI32(1);

export const METADATA_KEY_WITH_CDN = "withCDN";

export class ContractAddresses {
  static readonly PDPVerifier: Address = Address.fromBytes(
    Bytes.fromHexString("0x445238Eca6c6aB8Dff1Aa6087d9c05734D22f137"),
  );
  static readonly ServiceProviderRegistry: Address = Address.fromBytes(
    Bytes.fromHexString("0xA8a7e2130C27e4f39D1aEBb3D538D5937bCf8ddb"),
  );
  static readonly USDFCToken: Address = Address.fromBytes(
    Bytes.fromHexString("0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"),
  );
}

/**
 * Constants for transaction parsing
 */
export class TransactionConstants {
  static readonly WORD_SIZE: i32 = 32;
  static readonly ADDRESS_SIZE: i32 = 20;
  static readonly SELECTOR_SIZE: i32 = 4;
  static readonly MIN_ADD_SERVICE_PROVIDER_SIZE: i32 = 3 * 32; // 3 parameters * 32 bytes each
}
