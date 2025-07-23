import { Address, BigInt, Bytes } from "@graphprotocol/graph-ts";
import { TransactionConstants } from "./constants";
import { ByteUtils } from "./utils/ByteUtils";

//--------------------------------
// 1. Common Types
//--------------------------------

export enum AbiType {
  STRING,
  ADDRESS,
  BOOL,
  BYTES,
  UINT256,
  INT256,
}

export class AbiValue {
  type: AbiType;
  stringValue: string;
  addressValue: Address;
  boolValue: boolean;
  bytesValue: Uint8Array;
  uint256Value: BigInt;

  constructor(type: AbiType) {
    this.type = type;
    this.stringValue = "";
    this.addressValue = Address.zero();
    this.boolValue = false;
    this.bytesValue = new Uint8Array(0);
    this.uint256Value = BigInt.zero();
  }

  static fromString(value: string): AbiValue {
    let result = new AbiValue(AbiType.STRING);
    result.stringValue = value;
    return result;
  }

  static fromAddress(value: Address): AbiValue {
    let result = new AbiValue(AbiType.ADDRESS);
    result.addressValue = value;
    return result;
  }

  static fromBool(value: boolean): AbiValue {
    let result = new AbiValue(AbiType.BOOL);
    result.boolValue = value;
    return result;
  }

  static fromBytes(value: Uint8Array): AbiValue {
    let result = new AbiValue(AbiType.BYTES);
    result.bytesValue = value;
    return result;
  }

  static fromUint256(value: BigInt): AbiValue {
    let result = new AbiValue(AbiType.UINT256);
    result.uint256Value = value;
    return result;
  }
}

export class StringAddressBoolBytesResult {
  stringValue: string;
  addressValue: Address;
  boolValue: boolean;
  bytesValue: Bytes;

  constructor(
    stringValue: string,
    addressValue: Address,
    boolValue: boolean,
    bytesValue: Bytes
  ) {
    this.stringValue = stringValue;
    this.addressValue = addressValue;
    this.boolValue = boolValue;
    this.bytesValue = bytesValue;
  }
}

export class BytesStringResult {
  bytesValue: Bytes;
  stringValue: string;

  constructor(bytesValue: Bytes, stringValue: string) {
    this.bytesValue = bytesValue;
    this.stringValue = stringValue;
  }
}

export class AddServiceProviderFunctionParams {
  provider: Address;
  pdpUrl: string;
  pieceRetrievalUrl: string;

  constructor(provider: Address, pdpUrl: string, pieceRetrievalUrl: string) {
    this.provider = provider;
    this.pdpUrl = pdpUrl;
    this.pieceRetrievalUrl = pieceRetrievalUrl;
  }
}

//--------------------------------
// 2. Contract Function Decoders
//--------------------------------

/**
 * Generic ABI decoder that can handle various type combinations
 * @param data - The ABI-encoded bytes
 * @param types - Array of ABI types in order
 * @returns Array of AbiValue objects
 */
export function decodeAbi(data: Bytes, types: AbiType[]): AbiValue[] {
  if (types.length == 0) {
    return [];
  }

  const headerSize = types.length * TransactionConstants.WORD_SIZE;
  if (data.length < headerSize) {
    throw new Error("Insufficient data length for ABI decoding");
  }

  let results: AbiValue[] = [];
  let dynamicDataOffsets: i32[] = [];

  // First pass: read header and collect offsets for dynamic types
  for (let i = 0; i < types.length; i++) {
    const slotStart = i * TransactionConstants.WORD_SIZE;
    const slot = data.subarray(
      slotStart,
      slotStart + TransactionConstants.WORD_SIZE
    );

    if (isDynamicType(types[i])) {
      // For dynamic types, read the offset
      const offset = ByteUtils.toI32(slot);
      dynamicDataOffsets.push(offset);
      results.push(new AbiValue(types[i])); // Placeholder
    } else {
      // For static types, decode directly
      results.push(decodeStaticType(slot, types[i]));
      dynamicDataOffsets.push(0); // Not used for static types
    }
  }

  // Second pass: decode dynamic data
  for (let i = 0; i < types.length; i++) {
    if (isDynamicType(types[i])) {
      const offset = dynamicDataOffsets[i];
      results[i] = decodeDynamicType(data, offset, types[i]);
    }
  }

  return results;
}

// ======= Decoder Helper Functions =======

/**
 * Helper function to check if a type is dynamic
 */
function isDynamicType(type: AbiType): boolean {
  return type == AbiType.STRING || type == AbiType.BYTES;
}

/**
 * Decode static types directly from a 32-byte slot
 */
function decodeStaticType(slot: Uint8Array, type: AbiType): AbiValue {
  switch (type) {
    case AbiType.ADDRESS:
      const addressBytes = slot.subarray(
        TransactionConstants.WORD_SIZE - TransactionConstants.ADDRESS_SIZE,
        TransactionConstants.WORD_SIZE
      ); // Last 20 bytes
      return AbiValue.fromAddress(
        Address.fromBytes(Bytes.fromUint8Array(addressBytes))
      );

    case AbiType.BOOL:
      return AbiValue.fromBool(slot[31] != 0);

    case AbiType.UINT256:
    case AbiType.INT256:
      return AbiValue.fromUint256(
        BigInt.fromUnsignedBytes(changetype<Bytes>(slot))
      );

    default:
      throw new Error("Unsupported static type");
  }
}

/**
 * Decode dynamic types from their data location
 */
function decodeDynamicType(data: Bytes, offset: i32, type: AbiType): AbiValue {
  switch (type) {
    case AbiType.STRING:
      return AbiValue.fromString(decodeDynamicString(data, offset));

    case AbiType.BYTES:
      return AbiValue.fromBytes(decodeDynamicBytes(data, offset));

    default:
      throw new Error("Unsupported dynamic type");
  }
}

/**
 * Decodes a dynamic string from the given offset
 */
function decodeDynamicString(data: Bytes, offset: i32): string {
  if (offset + TransactionConstants.WORD_SIZE > data.length) {
    throw new Error("String offset exceeds data length");
  }

  // Read length from the first 32 bytes at offset
  const length = ByteUtils.toI32(data, offset);

  // If length is 0, return empty string
  if (length == 0) {
    return "";
  }

  // Read the string data
  const dataStart = offset + TransactionConstants.WORD_SIZE;
  if (dataStart + length > data.length) {
    throw new Error("String data exceeds available bytes");
  }

  const stringBytes = data.subarray(dataStart, dataStart + length);
  return Bytes.fromUint8Array(stringBytes).toString();
}

/**
 * Decodes dynamic bytes from the given offset
 */
function decodeDynamicBytes(data: Bytes, offset: i32): Uint8Array {
  if (offset + TransactionConstants.WORD_SIZE > data.length) {
    throw new Error("Bytes offset exceeds data length");
  }

  // Read length from the first 32 bytes at offset
  const length = ByteUtils.toI32(data, offset);

  // If length is 0, return empty bytes
  if (length == 0) {
    return new Uint8Array(0);
  }

  // Read the bytes data
  const dataStart = offset + TransactionConstants.WORD_SIZE;
  if (dataStart + length > data.length) {
    throw new Error("Bytes data exceeds available bytes");
  }

  const bytesData = data.subarray(dataStart, dataStart + length);
  return bytesData;
}

//--------------------------------
// 3. Function-Specific Decoders
//--------------------------------

/**
 * Convenience function for ["string", "address", "bool", "bytes"] pattern
 */
export function decodeStringAddressBoolBytes(
  data: Bytes
): StringAddressBoolBytesResult {
  const types: AbiType[] = [
    AbiType.STRING,
    AbiType.ADDRESS,
    AbiType.BOOL,
    AbiType.BYTES,
  ];
  const results = decodeAbi(data, types);

  return new StringAddressBoolBytesResult(
    results[0].stringValue,
    results[1].addressValue,
    results[2].boolValue,
    Bytes.fromUint8Array(results[3].bytesValue)
  );
}

/**
 * Convenience function for ["bytes", "string"]
 */
export function decodeBytesString(data: Bytes): BytesStringResult {
  const types: AbiType[] = [AbiType.BYTES, AbiType.STRING];
  const results = decodeAbi(data, types);

  return new BytesStringResult(
    Bytes.fromUint8Array(results[0].bytesValue),
    results[1].stringValue
  );
}
