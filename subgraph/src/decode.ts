import { Bytes, Address, BigInt, log } from "@graphprotocol/graph-ts";
import { ByteUtils } from "./utils/ByteUtils";
import { FunctionSelectors, TransactionConstants } from "./constants";

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

export class SafeExecTransactionParams {
  to: Address;
  value: BigInt;
  data: Uint8Array;
  // There are other parameters but we don't need them
  // operation: u8;
  // safeTxGas: BigInt;
  // baseGas: BigInt;
  // gasPrice: BigInt;
  // gasToken: Address;
  // refundReceiver: Address;
  // signatures: Uint8Array;
}

export class MultiSendFunctionParams {
  data: Uint8Array;
}

export class MultiSendSingleTransaction {
  to: Address;
  value: BigInt;
  data: Uint8Array;
  // There is one other parameter but we don't need it
  // operation: u8;

  // Not in the struct but we need it
  nextPosition: i32;
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

/**
 * Convenience function for decoding addServiceProvider function parameters
 *
 * @param data - The ABI-encoded bytes with function selector
 * @returns The decoded AddServiceProviderFunctionParams
 */
export function decodeAddServiceProviderFunction(
  data: Uint8Array
): AddServiceProviderFunctionParams {
  if (!ByteUtils.equals(data, 0, FunctionSelectors.ADD_SERVICE_PROVIDER)) {
    throw new Error("Invalid function selector");
  }

  const types: AbiType[] = [AbiType.ADDRESS, AbiType.STRING, AbiType.STRING];
  const results = decodeAbi(
    Bytes.fromUint8Array(data.subarray(TransactionConstants.SELECTOR_SIZE)),
    types
  );

  return new AddServiceProviderFunctionParams(
    results[0].addressValue,
    results[1].stringValue,
    results[2].stringValue
  );
}

export function decodeSafeExecTransactionFunctionParams(
  data: Uint8Array
): SafeExecTransactionParams {
  const types: AbiType[] = [AbiType.ADDRESS, AbiType.UINT256, AbiType.BYTES];
  const results = decodeAbi(
    Bytes.fromUint8Array(data.subarray(TransactionConstants.SELECTOR_SIZE)),
    types
  );

  return {
    to: results[0].addressValue,
    value: results[1].uint256Value,
    data: results[2].bytesValue,
  };
}

export function decodeMultiSendFunctionParams(
  data: Uint8Array
): MultiSendFunctionParams {
  const types: AbiType[] = [AbiType.BYTES];
  const results = decodeAbi(
    Bytes.fromUint8Array(data.subarray(TransactionConstants.SELECTOR_SIZE)),
    types
  );

  return {
    data: results[0].bytesValue,
  };
}

//---------------------------------------------
// 4. AddServiceProvider- Specific decoders
//---------------------------------------------

/**
 * Extracts all occurrences of addServiceProvider function call data from the
 * provided transaction input bytes. The function handles different Ethereum
 * transaction formats, including direct calls, Safe execTransaction calls,
 * and batched MultiSend transactions.
 *
 * @param txInput - The transaction input as Bytes
 * @param pandoraContractAddress - Optional address of the Pandora contract to verify target addresses
 * @returns An array of decoded AddServiceProvider function parameters
 */
export function extractAddServiceProviderCalldatas(
  txInput: Bytes,
  pandoraContractAddress: string = ""
): AddServiceProviderFunctionParams[] {
  const results: AddServiceProviderFunctionParams[] = [];

  const txData = new Uint8Array(txInput.length);
  txData.set(txInput);

  // Early return for empty input
  if (txData.length < TransactionConstants.SELECTOR_SIZE) {
    return results;
  }

  // Get function selector (first 4 bytes)
  const functionSelector = txData.subarray(
    0,
    TransactionConstants.SELECTOR_SIZE
  );

  // Route to appropriate handler based on function selector
  if (
    ByteUtils.equals(
      functionSelector,
      0,
      FunctionSelectors.ADD_SERVICE_PROVIDER
    )
  ) {
    return handleDirectCall(txData);
  } else if (
    ByteUtils.equals(functionSelector, 0, FunctionSelectors.EXEC_TRANSACTION)
  ) {
    return handleSafeExecTransaction(txData, pandoraContractAddress);
  } else {
    return handleFallbackParsing(txData);
  }
}

/**
 * Handles direct calls to addServiceProvider function
 */
function handleDirectCall(
  txInput: Uint8Array
): AddServiceProviderFunctionParams[] {
  if (
    txInput.length <
    TransactionConstants.SELECTOR_SIZE +
      TransactionConstants.MIN_ADD_SERVICE_PROVIDER_SIZE
  ) {
    log.warning(
      "Direct call input too short: required {} bytes, got {} bytes",
      [
        (
          TransactionConstants.SELECTOR_SIZE +
          TransactionConstants.MIN_ADD_SERVICE_PROVIDER_SIZE
        ).toString(),
        txInput.length.toString(),
      ]
    );
    return [];
  }

  return [decodeAddServiceProviderFunction(txInput)];
}

/**
 * Handles Safe execTransaction calls
 */
function handleSafeExecTransaction(
  txInput: Uint8Array,
  pandoraContractAddress: string
): AddServiceProviderFunctionParams[] {
  // Parse execTransaction parameters
  const execParams = decodeSafeExecTransactionFunctionParams(txInput);
  if (!execParams) {
    log.warning("Failed to parse execTransaction parameters", []);
    return [];
  }

  // Check what type of call is nested inside
  if (execParams.data.length < TransactionConstants.SELECTOR_SIZE) {
    log.warning("Nested call data too short: required {} bytes, got {} bytes", [
      TransactionConstants.SELECTOR_SIZE.toString(),
      execParams.data.length.toString(),
    ]);
    return [];
  }

  const nestedSelector = execParams.data.subarray(
    0,
    TransactionConstants.SELECTOR_SIZE
  );

  if (ByteUtils.equals(nestedSelector, 0, FunctionSelectors.MULTI_SEND)) {
    return handleMultiSendTransaction(execParams.data, pandoraContractAddress);
  } else if (
    ByteUtils.equals(nestedSelector, 0, FunctionSelectors.ADD_SERVICE_PROVIDER)
  ) {
    return handleDirectCall(execParams.data);
  }

  log.info("No matching nested function found", []);
  return [];
}

/**
 * Handles MultiSend batch transactions
 */
function handleMultiSendTransaction(
  txInput: Uint8Array,
  pandoraContractAddress: string
): AddServiceProviderFunctionParams[] {
  const results: AddServiceProviderFunctionParams[] = [];

  // Parse MultiSend structure
  const multiSendDataBytes = decodeMultiSendFunctionParams(txInput);
  if (!multiSendDataBytes) {
    log.warning("Failed to parse MultiSend data", []);
    return results;
  }

  const batchData = multiSendDataBytes.data;
  // Process each transaction in the batch
  let position = 0;
  while (position < batchData.length) {
    const transaction = parseMultiSendTransaction(batchData, position);
    if (!transaction) {
      log.warning("Failed to parse transaction at position: {}", [
        position.toString(),
      ]);
      break;
    }

    // Check if this transaction matches our criteria
    if (isTargetTransaction(transaction, pandoraContractAddress)) {
      results.push(decodeAddServiceProviderFunction(transaction.data));
    }

    position = transaction.nextPosition;
  }

  return results;
}

/**
 * Parses a single transaction from MultiSend batch data
 */
function parseMultiSendTransaction(
  batchData: Uint8Array,
  position: i32
): MultiSendSingleTransaction | null {
  // MultiSend transaction format:
  // 1 byte: operation
  // 20 bytes: to address
  // 32 bytes: value
  // 32 bytes: data length
  // N bytes: data

  const headerSize =
    1 + TransactionConstants.ADDRESS_SIZE + 2 * TransactionConstants.WORD_SIZE;
  if (position + headerSize > batchData.length) {
    return null;
  }

  let pos = position;

  // skip 1 byte of operation
  pos += 1;

  // Extract to address
  const to = ByteUtils.view(batchData, pos, TransactionConstants.ADDRESS_SIZE);
  pos += TransactionConstants.ADDRESS_SIZE;

  // Extract value
  const value = ByteUtils.view(batchData, pos, TransactionConstants.WORD_SIZE);
  pos += TransactionConstants.WORD_SIZE;

  // Extract data length
  const dataLength = ByteUtils.toI32(batchData, pos);
  pos += TransactionConstants.WORD_SIZE;

  // Extract data
  if (pos + dataLength > batchData.length) {
    return null;
  }

  const data = ByteUtils.view(batchData, pos, dataLength);
  pos += dataLength;

  return {
    to: Address.fromBytes(Bytes.fromUint8Array(to)),
    value: BigInt.fromUnsignedBytes(Bytes.fromUint8Array(value)),
    data: data,
    nextPosition: pos,
  };
}

/**
 * Checks if a transaction matches our target criteria
 */
function isTargetTransaction(
  transaction: MultiSendSingleTransaction,
  pandoraContractAddress: string
): boolean {
  // Check function selector
  if (transaction.data.length < TransactionConstants.SELECTOR_SIZE) {
    return false;
  }

  if (
    !ByteUtils.equals(
      transaction.data,
      0,
      FunctionSelectors.ADD_SERVICE_PROVIDER
    )
  ) {
    return false;
  }

  // Check contract address if specified
  if (pandoraContractAddress !== "") {
    const expectedAddress = Address.fromHexString(pandoraContractAddress);
    if (!transaction.to.equals(expectedAddress)) {
      return false;
    }
  }

  return true;
}

/**
 * Fallback parsing for other transaction formats
 */
function handleFallbackParsing(
  txData: Uint8Array
): AddServiceProviderFunctionParams[] {
  const results: AddServiceProviderFunctionParams[] = [];
  const selector = FunctionSelectors.ADD_SERVICE_PROVIDER;

  // Search for selector patterns
  for (let i = 0; i <= txData.length - selector.length; i++) {
    if (ByteUtils.equals(txData, i, selector)) {
      const paramStart = i;
      const minParamSize = 4 + 3 * 32; // function selector + 3 * 32 bytes for params

      if (paramStart + minParamSize <= txData.length) {
        const paramData = ByteUtils.view(txData, paramStart, minParamSize);
        results.push(decodeAddServiceProviderFunction(paramData));
      }
    }
  }

  return results;
}
