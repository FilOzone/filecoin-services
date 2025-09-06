import { Bytes, BigInt } from "@graphprotocol/graph-ts";

/**
 * Utility functions for efficient byte operations
 */
export class ByteUtils {
  /**
   * Efficiently compare bytes without creating new arrays
   */
  static equals(a: Uint8Array, aStart: i32, b: Uint8Array, bStart: i32 = 0, length: i32 = -1): boolean {
    const len = length === -1 ? b.length : length;

    if (aStart + len > a.length || bStart + len > b.length) {
      return false;
    }

    for (let i = 0; i < len; i++) {
      if (a[aStart + i] !== b[bStart + i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * Extract BigInt from bytes
   */
  static toBigInt(data: Uint8Array, offset: i32): BigInt {
    if (offset + 32 > data.length) {
      return BigInt.zero();
    }
    return BigInt.fromUnsignedBytes(Bytes.fromUint8Array(data.slice(offset, offset + 32)));
  }

  /**
   * Extract 32-bit unsigned integer from bytes (big-endian)
   */
  static toI32(data: Uint8Array, offset: i32 = 0): i32 {
    if (offset + 32 > data.length) {
      return 0;
    }

    // Skip leading zeros for the last 4 bytes of a 32-byte word
    const start = offset + 28; // Last 4 bytes of 32-byte word
    return (i32(data[start]) << 24) | (i32(data[start + 1]) << 16) | (i32(data[start + 2]) << 8) | i32(data[start + 3]);
  }

  /**
   * Create a view of the array without copying
   */
  static view(data: Uint8Array, start: i32, length: i32): Uint8Array {
    return data.subarray(start, start + length);
  }

  /**
   * Convert back to Bytes only when needed for external APIs
   */
  static toBytes(data: Uint8Array): Bytes {
    return Bytes.fromUint8Array(data);
  }
}
