import { Address, BigInt } from "@graphprotocol/graph-ts";

/**
 * Information about a service provider
 */
export class ServiceProviderInfo {
  constructor(
    public serviceProvider: Address,
    public payee: Address,
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

/**
 * PDP Offering
 */
export class PDPOffering {
  constructor(
    public serviceURL: string,
    public minPieceSizeInBytes: BigInt,
    public maxPieceSizeInBytes: BigInt,
    public ipniPiece: boolean,
    public ipniIpfs: boolean,
    public storagePricePerTibPerMonth: BigInt,
    public minProvingPeriodInEpochs: BigInt,
    public location: string,
    public paymentTokenAddress: Address,
  ) {}

  static empty(): PDPOffering {
    return new PDPOffering(
      "",
      BigInt.zero(),
      BigInt.zero(),
      false,
      false,
      BigInt.zero(),
      BigInt.zero(),
      "",
      Address.zero(),
    );
  }

  toJSON(): string {
    return `{"serviceURL": "${this.serviceURL}", "minPieceSizeInBytes": "${this.minPieceSizeInBytes}", "maxPieceSizeInBytes": "${this.maxPieceSizeInBytes}", "ipniPiece": "${this.ipniPiece}", "ipniIpfs": "${this.ipniIpfs}", "storagePricePerTibPerMonth": "${this.storagePricePerTibPerMonth}", "minProvingPeriodInEpochs": "${this.minProvingPeriodInEpochs}", "location": "${this.location}", "paymentTokenAddress": "${this.paymentTokenAddress}"}`;
  }
}
