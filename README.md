# CCIP Rebase Token (RBT)

## Overview

This project demonstrates a simplified end-to-end system for a rebasing ERC-20 token that can be bridged cross-chain using Chainlink CCIP.

Specifically, it showcases how to:

- Mint a rebasing token by depositing ETH into a **Vault**
- Accrue value over time via a **time-based rebase (interest mechanism)**
- Bridge the token across chains using **Chainlink CCIP**
- Preserve each user’s **individual interest rate** during cross-chain transfers

**Not audited. Educational only.**

---

## What’s inside (plain English)

### `Vault`
- You **deposit ETH**
- It **mints RBT** to you (same amount as ETH you deposited)
- You can **redeem** your RBT to get ETH back
- `redeem(type(uint256).max)` means “redeem all”

### `RebaseToken` (RBT)
- Your balance grows over time (linear interest)
- Each user has an interest rate snapshot
- Only approved contracts can mint/burn (Vault + CCIP pool)

### `RebaseTokenPool` (CCIP)
This is the bridge logic.
- When sending out: burn tokens and **encode the user interest rate**
- When receiving: decode the rate and mint tokens on the destination chain

---

## Requirements

- Foundry installed (`forge`, `cast`)
- For zkSync: `foundryup-zksync` available

---

## Setup

### 1) Create `.env` (don’t commit this)
In the repo root:

```bash
SEPOLIA_RPC_URL=...
ZKSYNC_SEPOLIA_RPC_URL=...
```

### 2) Create Foundry keystores
Examples:

```bash
cast wallet import sepoliaKey --interactive
cast wallet import zksyncSepoliaKey --interactive
```

---

## Run tests

```bash
forge test -vvv
```

> If `forge coverage` throws “stack too deep”, that’s normal for complex tests + coverage mode.  
> Your tests passing is the real signal.

---

## One-command demo: bridge Sepolia → zkSync

This repo includes:

- `bridgeToZKsync.sh`

It will:
1) Deploy token + pool on zkSync Sepolia  
2) Deploy token + pool + vault on Ethereum Sepolia  
3) Configure pools both ways  
4) Deposit ETH (mint RBT)  
5) Bridge RBT to zkSync  
6) Print balances before/after  

### Run it

```bash
chmod +x ./bridgeToZKsync.sh
./bridgeToZKsync.sh
```

You will be prompted for your keystore password(s). That’s expected.

---


## Common gotchas

- **CCIP is async**: “send” happens first, “mint on destination” can take a bit.
- **Chain ID 300 warning**: zkSync Sepolia uses chainId **300**. Some RPCs warn about EIP-3855. Annoying, usually fine.
- **Coverage vs via-IR**: forge coverage runs with reduced optimizations and may hit “stack too deep” errors. These can usually be resolved by using forge coverage --ir-minimum.

---

## License

MIT
# ccip-rebase-token
