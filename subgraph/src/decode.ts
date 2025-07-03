import { Bytes, Address, BigInt } from "@graphprotocol/graph-ts";

// Enum for supported ABI types
export enum AbiType {
  STRING,
  ADDRESS,
  BOOL,
  BYTES,
  UINT256,
  INT256,
}

// Generic result class that can hold any decoded value
export class AbiValue {
  type: AbiType;
  stringValue: string;
  addressValue: Address;
  boolValue: boolean;
  bytesValue: Bytes;
  uint256Value: BigInt;

  constructor(type: AbiType) {
    this.type = type;
    this.stringValue = "";
    this.addressValue = Address.zero();
    this.boolValue = false;
    this.bytesValue = Bytes.empty();
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

  static fromBytes(value: Bytes): AbiValue {
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

// Specific result classes for common patterns
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

  const headerSize = types.length * 32;
  if (data.length < headerSize) {
    throw new Error("Insufficient data length for ABI decoding");
  }

  let results: AbiValue[] = [];
  let dynamicDataOffsets: i32[] = [];

  // First pass: read header and collect offsets for dynamic types
  for (let i = 0; i < types.length; i++) {
    const slotStart = i * 32;
    const slot = data.subarray(slotStart, slotStart + 32);

    if (isDynamicType(types[i])) {
      // For dynamic types, read the offset
      const offset = bytesToI32(slot);
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
    results[3].bytesValue
  );
}

/**
 * Convenience function for ["bytes", "string"] pattern
 */
export function decodeBytesString(data: Bytes): BytesStringResult {
  const types: AbiType[] = [AbiType.BYTES, AbiType.STRING];
  const results = decodeAbi(data, types);

  return new BytesStringResult(results[0].bytesValue, results[1].stringValue);
}

/**
 * Convenience function for decoding addServiceProvider function parameters
 */
export function decodeAddServiceProviderFunction(
  data: Bytes
): AddServiceProviderFunctionParams {
  const types: AbiType[] = [AbiType.ADDRESS, AbiType.STRING, AbiType.STRING];
  const results = decodeAbi(data, types);

  return new AddServiceProviderFunctionParams(
    results[0].addressValue,
    results[1].stringValue,
    results[2].stringValue
  );
}

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
      const addressBytes = slot.subarray(12, 32); // Last 20 bytes
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
 * Converts a 32-byte big-endian array to i32
 * Only uses the last 4 bytes to avoid overflow
 */
function bytesToI32(bytes: Uint8Array): i32 {
  if (bytes.length != 32) {
    throw new Error("Expected 32 bytes for offset conversion");
  }

  // Use only the last 4 bytes to avoid overflow
  const result =
    (i32(bytes[28]) << 24) |
    (i32(bytes[29]) << 16) |
    (i32(bytes[30]) << 8) |
    i32(bytes[31]);

  return result;
}

/**
 * Decodes a dynamic string from the given offset
 */
function decodeDynamicString(data: Bytes, offset: i32): string {
  if (offset + 32 > data.length) {
    throw new Error("String offset exceeds data length");
  }

  // Read length from the first 32 bytes at offset
  const lengthSlot = data.subarray(offset, offset + 32);
  const length = bytesToI32(lengthSlot);

  // If length is 0, return empty string
  if (length == 0) {
    return "";
  }

  // Read the string data
  const dataStart = offset + 32;
  if (dataStart + length > data.length) {
    throw new Error("String data exceeds available bytes");
  }

  const stringBytes = data.subarray(dataStart, dataStart + length);
  return Bytes.fromUint8Array(stringBytes).toString();
}

/**
 * Decodes dynamic bytes from the given offset
 */
function decodeDynamicBytes(data: Bytes, offset: i32): Bytes {
  if (offset + 32 > data.length) {
    throw new Error("Bytes offset exceeds data length");
  }

  // Read length from the first 32 bytes at offset
  const lengthSlot = data.subarray(offset, offset + 32);
  const length = bytesToI32(lengthSlot);

  // If length is 0, return empty bytes
  if (length == 0) {
    return Bytes.fromHexString("0x");
  }

  // Read the bytes data
  const dataStart = offset + 32;
  if (dataStart + length > data.length) {
    throw new Error("Bytes data exceeds available bytes");
  }

  const bytesData = data.subarray(dataStart, dataStart + length);
  return Bytes.fromUint8Array(bytesData);
}

/**
 * Extracts all occurrences of addServiceProvider function call data from the
 * provided transaction input selector string. The function identifies
 * calldatas based on the specified function selector and ensures data integrity
 * by excluding entries that only contain the selector without additional data.
 *
 * @param funcSelector - The transaction input selector string, potentially
 * including multiple function call data.
 * @returns An array of strings, each representing a piece of calldata that
 * includes the addServiceProvider function call.
 */
export function extractAddServiceProviderCalldatas(
  funcSelector: string
): string[] {
  const addServiceProviderFunctionSelector = "5f6840ec";
  const calldatas: string[] = [];

  if (funcSelector.length < 10) {
    // Minimum length for function selector (0x + 4 bytes)
    return calldatas;
  }

  // Remove '0x' prefix if present
  let cleanSelector = funcSelector;
  if (cleanSelector.startsWith("0x")) {
    cleanSelector = cleanSelector.slice(2);
  }

  let searchPosition = 0;

  while (searchPosition < cleanSelector.length) {
    const selectorPosition = cleanSelector.indexOf(
      addServiceProviderFunctionSelector,
      searchPosition
    );

    if (selectorPosition === -1) {
      break;
    }

    // Find the next function selector occurrence
    const nextSelectorPosition = cleanSelector.indexOf(
      addServiceProviderFunctionSelector,
      selectorPosition + addServiceProviderFunctionSelector.length
    );

    let calldataEnd: i32;
    if (nextSelectorPosition === -1) {
      // This is the last occurrence, take everything until the end
      calldataEnd = cleanSelector.length;
    } else {
      // Take everything until the next function selector
      calldataEnd = nextSelectorPosition;
    }

    const calldata = cleanSelector.slice(selectorPosition, calldataEnd);
    if (calldata.length > 8) {
      // Ensure we have more than just the function selector
      calldatas.push("0x" + calldata);
    }

    searchPosition =
      selectorPosition + addServiceProviderFunctionSelector.length;
  }

  return calldatas;
}

// Helper function to check if transaction contains addServiceProvider function calls
export function hasAddServiceProviderFunction(txInput: string): boolean {
  const addServiceProviderFunctionSelector = "5f6840ec";
  return txInput.indexOf(addServiceProviderFunctionSelector) !== -1;
}
