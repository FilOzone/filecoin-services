import { readFileSync } from 'node:fs';
import { getAddress, type Address, type Chain } from 'viem';
import { filecoin, filecoinCalibration } from 'viem/chains';

export type NetworkName = 'mainnet' | 'calibnet';

export type Network = {
  name: NetworkName;
  chain: Chain;
  fwss: Address;
  pdpVerifier: Address;
  // Pieces added at or after this block came after FWSS stopped storing piece metadata.
  legacyBeforeBlock: number;
  defaultRpcUrl: string;
};

const NETWORKS: Record<NetworkName, { chain: Chain; legacyBeforeBlock: number; defaultRpcUrl: string }> = {
  mainnet: { chain: filecoin, legacyBeforeBlock: 6338200, defaultRpcUrl: 'https://api.node.glif.io/rpc/v1' },
  calibnet: {
    chain: filecoinCalibration,
    legacyBeforeBlock: 4029095,
    defaultRpcUrl: 'https://api.calibration.node.glif.io/rpc/v1',
  },
};

export const DEFAULT_DEPLOYMENTS = new URL('../../../deployments.json', import.meta.url);

export function loadNetwork(name: string, deploymentsPath: string | URL = DEFAULT_DEPLOYMENTS): Network {
  if (name !== 'mainnet' && name !== 'calibnet') throw new Error(`unknown network ${name}, use mainnet or calibnet`);
  const base = NETWORKS[name];
  const deployments = JSON.parse(readFileSync(deploymentsPath, 'utf8')) as Record<string, Record<string, unknown>>;
  const entry = deployments[String(base.chain.id)];
  const fwss = entry?.FWSS_PROXY_ADDRESS;
  const pdpVerifier = entry?.PDP_VERIFIER_PROXY_ADDRESS;
  if (typeof fwss !== 'string' || typeof pdpVerifier !== 'string') {
    throw new Error(`no FWSS or PDPVerifier proxy for chain ${base.chain.id} in ${deploymentsPath}`);
  }
  return { name, ...base, fwss: getAddress(fwss), pdpVerifier: getAddress(pdpVerifier) };
}
