import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import { SumTreeCount } from "../generated/schema";

// Define a class for the structure instead of a type alias
class PieceIdAndOffset {
  pieceId: BigInt;
  offset: BigInt;
}

export class SumTree {
  private getPieceEntityId(dataSetId: BigInt, pieceId: BigInt): Bytes {
    return Bytes.fromUTF8(dataSetId.toString() + "-" + pieceId.toString());
  }

  // Helper: Get sumTreeCounts[dataSetId][index], default 0
  private getSum(dataSetId: i32, index: i32, blockNumber: BigInt): BigInt {
    const rootEntityId = this.getPieceEntityId(
      BigInt.fromI32(dataSetId as i32),
      BigInt.fromI32(index as i32)
    );
    const sumTreeCount = SumTreeCount.load(rootEntityId);
    if (!sumTreeCount) return BigInt.fromI32(0);
    if (sumTreeCount.lastDecEpoch.equals(blockNumber)) {
      return sumTreeCount.lastCount;
    }
    return sumTreeCount.count;
  }

  // Helper: Set sumTreeCounts[dataSetId][index] = value
  private setSum(dataSetId: i32, index: i32, value: BigInt): void {
    const rootEntityId = this.getPieceEntityId(
      BigInt.fromI32(dataSetId),
      BigInt.fromI32(index)
    );
    const sumTreeCount = new SumTreeCount(rootEntityId);
    sumTreeCount.dataSetId = BigInt.fromI32(dataSetId as i32);
    sumTreeCount.pieceId = BigInt.fromI32(index as i32);
    sumTreeCount.count = value;
    sumTreeCount.lastCount = BigInt.fromI32(0);
    sumTreeCount.lastDecEpoch = BigInt.fromI32(0);
    sumTreeCount.save();
  }

  // Helper: Decrement sumTreeCounts[dataSetId][index] by delta
  private decSum(
    dataSetId: i32,
    index: i32,
    delta: BigInt,
    blockNumber: BigInt
  ): void {
    const rootEntityId = this.getPieceEntityId(
      BigInt.fromI32(dataSetId),
      BigInt.fromI32(index)
    );
    const sumTreeCount = SumTreeCount.load(rootEntityId);
    if (!sumTreeCount) return;
    const prev = sumTreeCount.count;
    sumTreeCount.lastCount = prev;
    sumTreeCount.count = prev.minus(delta);
    sumTreeCount.lastDecEpoch = blockNumber;
    sumTreeCount.save();
  }

  // Helper: heightFromIndex (number of trailing zeros in index+1)
  private heightFromIndex(index: i32): i32 {
    let x = index + 1;
    let tz = 0;
    while ((x & 1) === 0) {
      tz++;
      x >>= 1;
    }
    return tz;
  }

  // Helper: clz (count leading zeros) for 32-bit numbers
  private clz(x: i32): i32 {
    if (x === 0) return 32;
    let n = 32;
    let y = (x as u32) >> 16;
    if (y !== 0) {
      n -= 16;
      x = y;
    }
    y = (x as u32) >> 8;
    if (y !== 0) {
      n -= 8;
      x = y;
    }
    y = (x as u32) >> 4;
    if (y !== 0) {
      n -= 4;
      x = y;
    }
    y = (x as u32) >> 2;
    if (y !== 0) {
      n -= 2;
      x = y;
    }
    y = (x as u32) >> 1;
    if (y !== 0) {
      return n - 2;
    }
    return n - (x as i32);
  }

  // sumTreeAdd
  sumTreeAdd(dataSetId: i32, count: BigInt, pieceId: i32): void {
    let index = pieceId;
    let h = this.heightFromIndex(index);
    let sum = count;
    for (let i = 0; i < h; i++) {
      let j = index - (1 << i);
      sum = sum.plus(this.getSum(dataSetId, j, BigInt.fromI32(1))); // 0 is default value of lastDecEpoch so using 1
    }
    this.setSum(dataSetId, pieceId, sum);
  }

  // sumTreeRemove
  sumTreeRemove(
    dataSetId: i32,
    nextRoot: i32,
    index: i32,
    delta: BigInt,
    blockNumber: BigInt
  ): void {
    const top = 32 - this.clz(nextRoot);
    let h = this.heightFromIndex(index);
    while (h <= top && index < nextRoot) {
      this.decSum(dataSetId, index, delta, blockNumber);
      index += 1 << h;
      h = this.heightFromIndex(index);
    }
  }

  // findOneRootId
  findOneRootId(
    dataSetId: i32,
    nextRoot: i32,
    leafIndex: BigInt,
    top: i32,
    blockNumber: BigInt
  ): PieceIdAndOffset {
    let searchPtr = (1 << top) - 1;
    let acc: BigInt = BigInt.fromI32(0);
    let candidate: BigInt = BigInt.fromI32(0);
    for (let h = top; h > 0; h--) {
      if (searchPtr >= nextRoot) {
        searchPtr -= 1 << (h - 1);
        continue;
      }
      const sum = this.getSum(dataSetId, searchPtr, blockNumber);
      candidate = acc.plus(sum);
      if (candidate.le(leafIndex)) {
        acc = acc.plus(sum);
        searchPtr += 1 << (h - 1);
      } else {
        searchPtr -= 1 << (h - 1);
      }
    }
    candidate = acc.plus(this.getSum(dataSetId, searchPtr, blockNumber));
    if (candidate.le(leafIndex)) {
      return {
        pieceId: BigInt.fromI32(searchPtr + 1),
        offset: leafIndex.minus(candidate),
      };
    }
    return {
      pieceId: BigInt.fromI32(searchPtr),
      offset: leafIndex.minus(acc),
    };
  }

  // findPieceIds (batched)
  findPieceIds(
    dataSetId: i32,
    nextRootId: i32,
    leafIndexes: BigInt[],
    blockNumber: BigInt
  ): PieceIdAndOffset[] {
    const top = 32 - this.clz(nextRootId);

    const results: PieceIdAndOffset[] = [];
    for (let i = 0; i < leafIndexes.length; i++) {
      const idx = leafIndexes[i];

      const result = this.findOneRootId(
        dataSetId,
        nextRootId,
        idx,
        top,
        blockNumber
      );
      results.push(result);
    }

    return results;
  }
}

export default SumTree;
