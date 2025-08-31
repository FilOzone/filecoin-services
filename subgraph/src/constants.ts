import { Address, Bytes, BigInt } from "@graphprotocol/graph-ts";

export const NumChallenges = 5;

export const LeafSize = 32;

export const DefaultLockupPeriod = 2880 * 10; // 10 days

export const BIGINT_ZERO = BigInt.zero();
export const BIGINT_ONE = BigInt.fromI32(1);

export class ContractAddresses {
  static readonly PDPVerifier: Address = Address.fromBytes(
    Bytes.fromHexString("0x07074aDd0364e79a1fEC01c128c1EFfa19C184E9"),
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

/**
 * Type of rail provider
 */
export class RailType {
  static readonly PDP: string = "PDP";
  static readonly CACHE_MISS: string = "CACHE_MISS";
  static readonly CDN: string = "CDN";
}

/**
 * Status of provider
 */
export class ProviderStatus {
  static readonly REGISTERED: string = "REGISTERED";
  static readonly APPROVED: string = "APPROVED";
  static readonly UNAPPROVED: string = "UNAPPROVED";
  static readonly REMOVED: string = "REMOVED";
}

export class ProductType {
  static readonly PDP: BigInt = BigInt.fromI32(0);
}
