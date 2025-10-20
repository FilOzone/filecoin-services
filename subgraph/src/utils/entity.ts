import { Bytes, BigInt, Address, log } from "@graphprotocol/graph-ts";
import { Provider, ProviderProduct, Rail, DataSet, Piece } from "../../generated/schema";
import { ProductAdded as ProductAddedEvent } from "../../generated/ServiceProviderRegistry/ServiceProviderRegistry";
import { BIGINT_ZERO, BIGINT_ONE, ContractAddresses, LeafSize } from "./constants";
import { ProviderStatus } from "./types";
import { getProviderProductEntityId, getPieceEntityId, getDataSetEntityId } from "./keys";
import { decodePDPOfferingData } from "./decoders";
import { validateCommPv2, unpaddedSize } from "./cid";

export function createRails(
  railIds: BigInt[],
  type: string[],
  from: Address,
  to: Address,
  listenerAddr: Address,
  dataSetId: Bytes,
): void {
  for (let i = 0; i < type.length; i++) {
    if (railIds[i].isZero()) {
      continue;
    }

    let rail = new Rail(Bytes.fromByteArray(Bytes.fromBigInt(railIds[i])));
    rail.railId = railIds[i];
    rail.token = ContractAddresses.USDFCToken;
    rail.type = type[i];
    rail.from = from;
    rail.to = to;
    rail.operator = listenerAddr;
    rail.arbiter = listenerAddr;
    rail.dataSet = dataSetId;
    rail.paymentRate = BIGINT_ZERO;
    rail.endEpoch = BIGINT_ZERO;
    rail.isActive = true;
    rail.queueLength = BIGINT_ZERO;
    rail.save();
  }
}

export function createProviderProduct(event: ProductAddedEvent): void {
  const productType = event.params.productType;
  const serviceProvider = event.params.serviceProvider;
  const productData = event.params.productData;
  const capabilityKeys = event.params.capabilityKeys;
  const capabilityValues = event.params.capabilityValues;

  const productId = getProviderProductEntityId(serviceProvider, productType);
  const providerProduct = new ProviderProduct(productId);

  providerProduct.provider = serviceProvider;
  providerProduct.productData = productData;
  providerProduct.decodedProductData = decodePDPOfferingData(productData).toJSON();
  providerProduct.productType = BigInt.fromI32(productType);
  providerProduct.capabilityKeys = capabilityKeys;
  providerProduct.capabilityValues = capabilityValues;
  providerProduct.isActive = true;

  providerProduct.save();
}

export function initiateProvider(
  providerId: BigInt,
  serviceProvider: Address,
  payee: Address,
  timestamp: BigInt,
  blockNumber: BigInt,
): Provider {
  const provider = new Provider(serviceProvider);
  provider.providerId = providerId;
  provider.serviceProvider = serviceProvider;
  provider.payee = payee;
  provider.name = "";
  provider.description = "";
  provider.status = ProviderStatus.REGISTERED;
  provider.isActive = true;

  provider.totalFaultedPeriods = BIGINT_ZERO;
  provider.totalFaultedPieces = BIGINT_ZERO;
  provider.totalDataSets = BIGINT_ZERO;
  provider.totalPieces = BIGINT_ZERO;
  provider.totalDataSize = BIGINT_ZERO;
  provider.totalProducts = BIGINT_ZERO;

  provider.createdAt = timestamp;
  provider.updatedAt = timestamp;
  provider.blockNumber = blockNumber;

  return provider;
}

/**
 * Common logic for handling PieceAdded events.
 * Creates a new piece and updates related entities.
 */
export function handlePieceAddedCommon(
  setId: BigInt,
  pieceId: BigInt,
  metadataKeys: string[],
  metadataValues: string[],
  pieceBytes: Bytes,
  blockTimestamp: BigInt,
  blockNumber: BigInt,
): void {
  const commPData = validateCommPv2(pieceBytes);
  const rawSize = commPData.isValid ? unpaddedSize(commPData.padding, commPData.height) : BigInt.zero();

  const pieceEntityId = getPieceEntityId(setId, pieceId);
  const piece = new Piece(pieceEntityId);
  piece.pieceId = pieceId;
  piece.setId = setId;
  piece.rawSize = rawSize;
  piece.leafCount = rawSize.div(BigInt.fromI32(LeafSize));
  piece.cid = pieceBytes.length > 0 ? pieceBytes : Bytes.empty();
  piece.metadataKeys = metadataKeys;
  piece.metadataValues = metadataValues;
  piece.removed = false;
  piece.lastProvenEpoch = BIGINT_ZERO;
  piece.lastProvenAt = BIGINT_ZERO;
  piece.lastFaultedEpoch = BIGINT_ZERO;
  piece.lastFaultedAt = BIGINT_ZERO;
  piece.totalProofsSubmitted = BIGINT_ZERO;
  piece.totalPeriodsFaulted = BIGINT_ZERO;
  piece.createdAt = blockTimestamp;
  piece.updatedAt = blockTimestamp;
  piece.blockNumber = blockNumber;
  piece.dataSet = getDataSetEntityId(setId);

  piece.save();

  const dataSet = DataSet.load(getDataSetEntityId(setId));
  if (!dataSet) {
    log.warning("handlePieceAdded: DataSet not found for setId: {}", [setId.toString()]);
    return;
  }

  dataSet.totalPieces = dataSet.totalPieces.plus(BIGINT_ONE);
  dataSet.nextPieceId = dataSet.nextPieceId.plus(BIGINT_ONE);
  dataSet.totalDataSize = dataSet.totalDataSize.plus(piece.rawSize);
  dataSet.leafCount = dataSet.leafCount.plus(piece.rawSize.div(BigInt.fromI32(LeafSize)));
  dataSet.updatedAt = blockTimestamp;
  dataSet.blockNumber = blockNumber;
  dataSet.save();

  const provider = Provider.load(dataSet.serviceProvider);
  if (!provider) {
    log.warning("handlePieceAdded: Provider not found for DataSet: {}", [dataSet.id.toString()]);
    return;
  }

  provider.totalDataSize = provider.totalDataSize.plus(piece.rawSize);
  provider.totalPieces = provider.totalPieces.plus(BIGINT_ONE);
  provider.updatedAt = blockTimestamp;
  provider.blockNumber = blockNumber;
  provider.save();
}
