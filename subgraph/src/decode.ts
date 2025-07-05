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
  operation: u8;
  // There are other parameters but we don't need them
  // safeTxGas: BigInt;
  // baseGas: BigInt;
  // gasPrice: BigInt;
  // gasToken: Address;
  // refundReceiver: Address;
  // signatures: Uint8Array;
}

export class MultiSendTransaction {
  operation: u8;
  to: Address;
  value: BigInt;
  data: Uint8Array;

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
 * Decodes a dynamic string from the given offset
 */
function decodeDynamicString(data: Bytes, offset: i32): string {
  if (offset + 32 > data.length) {
    throw new Error("String offset exceeds data length");
  }

  // Read length from the first 32 bytes at offset
  const lengthSlot = data.subarray(offset, offset + 32);
  const length = ByteUtils.toI32(lengthSlot, 0);

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
  const length = ByteUtils.toI32(lengthSlot);

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
    results[3].bytesValue
  );
}

/**
 * Convenience function for ["bytes", "string"]
 */
export function decodeBytesString(data: Bytes): BytesStringResult {
  const types: AbiType[] = [AbiType.BYTES, AbiType.STRING];
  const results = decodeAbi(data, types);

  return new BytesStringResult(results[0].bytesValue, results[1].stringValue);
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
  const results = decodeAbi(Bytes.fromUint8Array(data.subarray(4)), types);

  return new AddServiceProviderFunctionParams(
    results[0].addressValue,
    results[1].stringValue,
    results[2].stringValue
  );
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
  if (txData.length < 4) {
    return results;
  }

  // Get function selector (first 4 bytes)
  const functionSelector = txData.subarray(0, 4);

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
  // Skip execTransaction selector
  const execData = txInput.subarray(TransactionConstants.SELECTOR_SIZE);

  // Parse execTransaction parameters
  const execParams = parseExecTransactionParameters(execData);
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
 * Parses execTransaction parameters from Safe transaction
 */
function parseExecTransactionParameters(
  execData: Uint8Array
): SafeExecTransactionParams | null {
  // execTransaction(address to, uint256 value, bytes data, uint8 operation, ...)
  // We need: to (32 bytes), value (32 bytes), data offset (32 bytes), operation (32 bytes), ...

  const requiredSize = 4 * TransactionConstants.WORD_SIZE; // to, value, data_offset, operation
  if (execData.length < requiredSize) {
    log.warning(
      "ExecTransaction: data too short: required {} bytes, got {} bytes",
      [requiredSize.toString(), execData.length.toString()]
    );
    return null;
  }

  // Extract 'to' address (last 20 bytes of first 32-byte word)
  const toBytes = ByteUtils.view(
    execData,
    TransactionConstants.WORD_SIZE - TransactionConstants.ADDRESS_SIZE,
    TransactionConstants.ADDRESS_SIZE
  );

  // Extract value (second 32-byte word)
  const value = ByteUtils.toBigInt(execData, TransactionConstants.WORD_SIZE);

  // Extract data offset (third 32-byte word)
  const dataOffset = ByteUtils.toI32(
    execData,
    2 * TransactionConstants.WORD_SIZE
  );

  // Extract operation (fourth 32-byte word)
  const operation = ByteUtils.toI32(
    execData,
    3 * TransactionConstants.WORD_SIZE
  );

  // Extract data length and actual data
  if (execData.length < dataOffset + TransactionConstants.WORD_SIZE) {
    log.warning(
      "ExecTransaction: data offset too short: required {} bytes, got {} bytes",
      [dataOffset.toString(), execData.length.toString()]
    );
    return null;
  }

  const dataLength = ByteUtils.toI32(execData, dataOffset);

  if (
    execData.length <
    dataOffset + TransactionConstants.WORD_SIZE + dataLength
  ) {
    return null;
  }

  const data = execData.subarray(
    dataOffset + TransactionConstants.WORD_SIZE,
    dataOffset + TransactionConstants.WORD_SIZE + dataLength
  );

  return {
    to: Address.fromBytes(Bytes.fromUint8Array(toBytes)),
    value: value,
    data: data,
    operation: u8(operation),
  };
}

/**
 * Handles MultiSend batch transactions
 */
function handleMultiSendTransaction(
  txInput: Uint8Array,
  pandoraContractAddress: string
): AddServiceProviderFunctionParams[] {
  const results: AddServiceProviderFunctionParams[] = [];

  // Skip multiSend function selector
  const multiSendData: Uint8Array = txInput.subarray(
    TransactionConstants.SELECTOR_SIZE
  );

  // Parse MultiSend structure
  const batchData = parseMultiSendData(multiSendData);
  if (!batchData) {
    log.warning("Failed to parse MultiSend data", []);
    return results;
  }

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
 * Parses MultiSend data structure
 */
function parseMultiSendData(multiSendData: Uint8Array): Uint8Array | null {
  // MultiSend format: selector + offset + length + data
  const minSize = 2 * TransactionConstants.WORD_SIZE;
  if (multiSendData.length < minSize) {
    return null;
  }

  // Skip selector, get offset to batch data
  const offset = ByteUtils.toI32(multiSendData, 0);

  // Get length of batch data
  if (multiSendData.length < offset + TransactionConstants.WORD_SIZE) {
    return null;
  }

  const length = ByteUtils.toI32(multiSendData, offset);

  // Extract batch data
  if (multiSendData.length < offset + TransactionConstants.WORD_SIZE + length) {
    return null;
  }

  return ByteUtils.view(
    multiSendData,
    offset + TransactionConstants.WORD_SIZE,
    length
  );
}

/**
 * Parses a single transaction from MultiSend batch data
 */
function parseMultiSendTransaction(
  batchData: Uint8Array,
  position: i32
): MultiSendTransaction | null {
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

  // Extract operation
  const operation = batchData[pos];
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
    operation: u8(operation),
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
  transaction: MultiSendTransaction,
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
