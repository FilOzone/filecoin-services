import { ByteArray } from "@graphprotocol/graph-ts";

/**
 * Function selectors as Bytes for efficient comparison
 */
export class FunctionSelectors {
  static readonly EXEC_TRANSACTION: ByteArray =
    ByteArray.fromHexString("0x6a761202");
  static readonly ADD_SERVICE_PROVIDER: ByteArray =
    ByteArray.fromHexString("0x5f6840ec");
  static readonly MULTI_SEND: ByteArray = ByteArray.fromHexString("0x8d80ff0a");
}

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
 * Contract Address
 */
export class ContractAddresses {
  static readonly PANDORA: string =
    "0xf49ba5eaCdFD5EE3744efEdf413791935FE4D4c5";
}
