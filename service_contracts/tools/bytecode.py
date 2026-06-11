#!/usr/bin/env python3
"""bytecode.py — bytecode manipulation utilities for verify-deployments.sh

Subcommands
-----------
link <hex> <link_refs_json> <libs_json>
    Replace __$...$__ library placeholder bytes in <hex> with the 20-byte
    addresses from <libs_json> ({"path:Name": "0xaddr"}).  Positions come
    from <link_refs_json> (artifact bytecode.linkReferences).
    Outputs the linked hex, no 0x prefix.

patch-lib <hex> <imm_refs_json> <address>
    Patch the compiler-generated library_deploy_address immutable in <hex>
    with <address> (0x-prefixed, padded to 32 bytes).  Positions come from
    <imm_refs_json> (artifact deployedBytecode.immutableReferences).
    Outputs the patched hex, no 0x prefix.

read-imm <hex> <imm_refs_json>
    Read immutable values from <hex> at positions from <imm_refs_json>.
    Outputs a JSON object mapping immutable name/ID to its hex value
    (32 bytes, no 0x, lowercase), using the first occurrence of each.
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


def cmd_patch_lib(hex_str, imm_refs_json, deployed_addr):
    imm_refs = json.loads(imm_refs_json)
    if 'library_deploy_address' not in imm_refs:
        print(hex_str, end='')
        return
    addr = deployed_addr.lower().removeprefix('0x').zfill(64)
    chars = list(hex_str)
    for pos in imm_refs['library_deploy_address']:
        start, length = pos['start'] * 2, pos['length'] * 2
        chars[start:start + length] = list(addr.zfill(length))
    print(''.join(chars), end='')


def cmd_read_imm(hex_str, imm_refs_json):
    imm_refs = json.loads(imm_refs_json)
    result = {}
    for name, positions in imm_refs.items():
        if positions:
            start, length = positions[0]['start'] * 2, positions[0]['length'] * 2
            result[name] = hex_str[start:start + length]
    print(json.dumps(result, indent=2))


COMMANDS = {
    'link':      (cmd_link,      3),
    'patch-lib': (cmd_patch_lib, 3),
    'read-imm':  (cmd_read_imm,  2),
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
