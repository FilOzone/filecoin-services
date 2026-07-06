#!/usr/bin/env python3
"""bytecode.py — bytecode manipulation utilities for verify-deployments.sh

Subcommands
-----------
link <hex> <link_refs_json> <libs_json>
    Replace __$...$__ library placeholder bytes in <hex> with the 20-byte
    addresses from <libs_json> ({"path:Name": "0xaddr"}).  Positions come
    from <link_refs_json> (artifact bytecode.linkReferences).
    Outputs the linked hex, no 0x prefix.

patch-lib <simulated_hex> <imm_refs_json> <onchain_hex> <address>
    Patch any immutable position in <simulated_hex> where the on-chain value
    equals <address> (padded to 32 bytes), using positions from <imm_refs_json>
    (artifact deployedBytecode.immutableReferences).  Handles both the named
    library_deploy_address key and numeric-ID keys like UUPSUpgradeable's
    __self immutable.  Outputs the patched hex, no 0x prefix.

read-imm <hex> <imm_refs_json>
    Read immutable values from <hex> at positions from <imm_refs_json>.
    Outputs a JSON object mapping immutable name/ID to its hex value
    (32 bytes, no 0x, lowercase), using the first occurrence of each.

fill-imm <hex> <imm_refs_json> <values_json>
    Fill immutable positions in <hex> with values from <values_json>
    ({"id": "32-byte-hex-value", ...}).  Used to populate the artifact's
    deployedBytecode (which has zero placeholders) with known values for
    direct on-chain comparison when constructor simulation is unavailable.
    Outputs the filled hex, no 0x prefix.
"""

import sys
import json


def cmd_link(hex_str, link_refs_json, libs_json):
    link_refs = json.loads(link_refs_json)
    libs = json.loads(libs_json)
    chars = list(hex_str)
    for sol_file, contracts in link_refs.items():
        for name, positions in contracts.items():
            key = f"{sol_file}:{name}"
            addr = libs.get(key)
            if addr is None:
                print(f"missing library address for {key}", file=sys.stderr)
                sys.exit(1)
            addr_hex = addr.lower().removeprefix('0x').zfill(40)
            for pos in positions:
                start = pos['start'] * 2
                chars[start:start + 40] = list(addr_hex)
    print(''.join(chars), end='')


def cmd_patch_lib(hex_str, imm_refs_json, onchain_hex, deployed_addr):
    if not hex_str:
        print('', end='')
        return
    imm_refs = json.loads(imm_refs_json)
    addr_padded = deployed_addr.lower().removeprefix('0x').zfill(64)
    chars = list(hex_str)
    for positions in imm_refs.values():
        for pos in positions:
            start, length = pos['start'] * 2, pos['length'] * 2
            onchain_val = onchain_hex[start:start + length]
            if onchain_val == addr_padded[:length]:
                chars[start:start + length] = list(addr_padded[:length])
    print(''.join(chars), end='')


def cmd_read_imm(hex_str, imm_refs_json):
    imm_refs = json.loads(imm_refs_json)
    result = {}
    for name, positions in imm_refs.items():
        if positions:
            start, length = positions[0]['start'] * 2, positions[0]['length'] * 2
            result[name] = hex_str[start:start + length]
    print(json.dumps(result, indent=2))


def cmd_fill_imm(hex_str, imm_refs_json, values_json):
    imm_refs = json.loads(imm_refs_json)
    values = json.loads(values_json)
    chars = list(hex_str)
    for imm_id, positions in imm_refs.items():
        val = values.get(imm_id)
        if val is None:
            continue
        val = val.lower().removeprefix('0x')
        for pos in positions:
            start, length = pos['start'] * 2, pos['length'] * 2
            chars[start:start + length] = list(val.zfill(length))
    print(''.join(chars), end='')


COMMANDS = {
    'link':      (cmd_link,      3),
    'patch-lib': (cmd_patch_lib, 4),
    'read-imm':  (cmd_read_imm,  2),
    'fill-imm':  (cmd_fill_imm,  3),
}

if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    cmd, nargs = COMMANDS[sys.argv[1]]
    args = sys.argv[2:]
    if len(args) != nargs:
        print(f"error: {sys.argv[1]} expects {nargs} arguments, got {len(args)}", file=sys.stderr)
        sys.exit(1)
    cmd(*args)
