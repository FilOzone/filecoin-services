import { Address } from "@graphprotocol/graph-ts";

export class ServiceProviderInfo {
  constructor(
    public beneficiary: Address,
    public name: string,
    public description: string,
    public isActive: boolean,
  ) {}
}
