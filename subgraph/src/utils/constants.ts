import { BigInt } from "@graphprotocol/graph-ts";

// Import network-specific contract addresses from generated constants
export { ContractAddresses } from "../generated/constants";

export const NumChallenges = 5;

export const LeafSize = 32;

export const DefaultLockupPeriod = 2880 * 10; // 10 days

export const BIGINT_ZERO = BigInt.zero();
export const BIGINT_ONE = BigInt.fromI32(1);

export const METADATA_KEY_WITH_CDN = "withCDN";

/**
 * Constants for transaction parsing
 */
export class TransactionConstants {
  static readonly WORD_SIZE: i32 = 32;
  static readonly ADDRESS_SIZE: i32 = 20;
  static readonly SELECTOR_SIZE: i32 = 4;
  static readonly MIN_ADD_SERVICE_PROVIDER_SIZE: i32 = 3 * 32; // 3 parameters * 32 bytes each
}
