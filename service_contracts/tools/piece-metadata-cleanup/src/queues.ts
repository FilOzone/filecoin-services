import type { DatabaseSync } from 'node:sqlite';
import { encodeFunctionData, parseAbi, type Address, type PublicClient } from 'viem';
import { replaceQueues } from './db.ts';
import { cleanupAbi, revertReason } from './send.ts';
import { queueSlot } from './slots.ts';
import type { StorageReader } from './storage.ts';

const pdpVerifierAbi = parseAbi(['function getNextDataSetId() view returns (uint64)']);

// PDPVerifier assigns every data set id, FWSS ones included, so ids below its next id cover every queue FWSS has.
export async function nextDataSetId(client: PublicClient, pdpVerifier: Address): Promise<number> {
  const next = await client.readContract({ address: pdpVerifier, abi: pdpVerifierAbi, functionName: 'getNextDataSetId' });
  return Number(next);
}

// The deployed FWSS pushes to and pops the legacy queues until the upgrade that installs the cleanup facet, so a
// length read before it can grow unseen by the plan. The dispatcher reverts on a selector it does not route.
export async function assertCleanupInstalled(reader: { client: PublicClient; ready(): Promise<void> }, fwss: Address): Promise<void> {
  // Without code at the address every call succeeds.
  await reader.ready();

  const data = encodeFunctionData({ abi: cleanupAbi, functionName: 'cleanupLegacyPieceMetadata', args: ['0x'] });
  try {
    await reader.client.call({ to: fwss, data });
  } catch (err) {
    throw new Error(
      `cleanupLegacyPieceMetadata with empty ops failed on ${fwss} (${revertReason(err)}): the cleanup facet is not installed; run queues after the upgrade that installs it`,
    );
  }
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

// Replaces the stored queues with the non-empty ones among data set ids 0..dataSetIds-1.
export async function refreshQueues(
  db: DatabaseSync,
  reader: StorageReader,
  dataSetIds: number,
  note: string,
): Promise<{ dataSetId: number; length: number }[]> {
  const queues = await readQueueLengths(reader, dataSetIds);
  replaceQueues(db, queues, note);
  return queues;
}
