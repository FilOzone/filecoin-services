export const PDPVerifierAddress = "0x07074aDd0364e79a1fEC01c128c1EFfa19C184E9";

export const USDFCTokenAddress = "0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0";

export const NumChallenges = 5;

export const LeafSize = 32;

export const DefaultLockupPeriod = 2880 * 10; // 10 days

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
  static readonly Created: string = "Created";
  static readonly Registered: string = "Registered";
  static readonly Approved: string = "Approved";
  static readonly Rejected: string = "Rejected";
  static readonly Removed: string = "Removed";
}
