import { parseAbi, type Address, type PublicClient } from 'viem';
import { queueSlot } from './slots.ts';
import type { StorageReader } from './storage.ts';

const pdpVerifierAbi = parseAbi(['function getNextDataSetId() view returns (uint64)']);

// PDPVerifier assigns every data set id, FWSS ones included, so ids below its next id cover every queue FWSS has.
export async function nextDataSetId(client: PublicClient, pdpVerifier: Address): Promise<number> {
  const next = await client.readContract({ address: pdpVerifier, abi: pdpVerifierAbi, functionName: 'getNextDataSetId' });
  return Number(next);
}

export async function readQueueLengths(
  reader: StorageReader,
  dataSetIds: number,
): Promise<{ dataSetId: number; length: number }[]> {
  const ids = Array.from({ length: dataSetIds }, (_, i) => i);
  const lengths = await reader.read(ids.map(queueSlot));
  return ids
    .map((dataSetId, i) => {
      const length = lengths[i]!;
      if (length > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error(`queue of data set ${dataSetId} reads length ${length}`);
      return { dataSetId, length: Number(length) };
    })
    .filter((q) => q.length > 0);
}
