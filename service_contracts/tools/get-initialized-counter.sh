#!/bin/bash

if [ -z "$ETH_RPC_URL" ]; then
    echo "Error: ETH_RPC_URL is not set"
    exit 1
fi

if [ -z "$1" ]; then
    echo "Error: Must specify a contract address"
    exit 1
fi

SLOT=$(cast storage $1 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00)

cast to-base $SLOT 10
