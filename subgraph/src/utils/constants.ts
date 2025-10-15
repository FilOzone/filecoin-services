import { BigInt } from "@graphprotocol/graph-ts";

// Import network-specific contract addresses from generated constants
export { ContractAddresses } from "../generated/constants";

export const NumChallenges = 5;

export const LeafSize = 32;

export const DefaultLockupPeriod = 2880 * 10; // 10 days

export const BIGINT_ZERO = BigInt.zero();
export const BIGINT_ONE = BigInt.fromI32(1);

export const METADATA_KEY_WITH_CDN = "withCDN";

export const PDP_OFFERING_DEF = "(string,uint256,uint256,bool,bool,uint256,uint256,string,address)";
