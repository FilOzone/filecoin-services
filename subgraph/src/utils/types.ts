import { Address } from "@graphprotocol/graph-ts";

/**
 * Information about a service provider
 */
export class ServiceProviderInfo {
  constructor(
    public beneficiary: Address,
    public name: string,
    public description: string,
    public isActive: boolean,
  ) {}
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
