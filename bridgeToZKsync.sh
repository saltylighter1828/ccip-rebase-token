#!/bin/bash
set -euo pipefail

AMOUNT=100000

# -------------------------
# Constants
# -------------------------
ZKSYNC_REGISTRY_MODULE_OWNER_CUSTOM="0x3139687Ee9938422F57933C3CDB3E21EE43c4d0F"
ZKSYNC_TOKEN_ADMIN_REGISTRY="0xc7777f12258014866c677Bdb679D0b007405b7DF"
ZKSYNC_ROUTER="0xA1fdA8aa9A8C4b945C45aD30647b01f07D7A0B16"
ZKSYNC_RNM_PROXY_ADDRESS="0x3DA20FD3D8a8f8c1f1A5fD03648147143608C467"
ZKSYNC_SEPOLIA_CHAIN_SELECTOR="6898391096552792247"
ZKSYNC_LINK_ADDRESS="0x23A1aFD896c8c8876AF46aDc38521f4432658d1e"

SEPOLIA_REGISTRY_MODULE_OWNER_CUSTOM="0x62e731218d0D47305aba2BE3751E7EE9E5520790"
SEPOLIA_TOKEN_ADMIN_REGISTRY="0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82"
SEPOLIA_ROUTER="0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59"
SEPOLIA_RNM_PROXY_ADDRESS="0xba3f6251de62dED61Ff98590cB2fDf6871FbB991"
SEPOLIA_CHAIN_SELECTOR="16015286601757825753"
SEPOLIA_LINK_ADDRESS="0x779877A7B0D9E8603169DdbD7836e478b4624789"

# -------------------------
# Helpers
# -------------------------
is_addr() { [[ "${1:-}" =~ ^0x[a-fA-F0-9]{40}$ ]]; }
require_addr() {
  local name="$1"; local val="${2:-}"
  if ! is_addr "$val"; then
    echo "ERROR: $name is not a valid address: '$val'"
    exit 1
  fi
}

# ERC20 balance helper (portable + avoids deprecated --erc20 flag)
erc20_balance() {
  local rpc="$1"
  local token="$2"
  local owner="$3"
  cast call "$token" "balanceOf(address)(uint256)" "$owner" --rpc-url "$rpc" | awk '{print $1}'
}

# -------------------------
# Load env (export variables)
# -------------------------
if [[ -f ".env" ]]; then
  set -a
  source .env
  set +a
else
  echo "ERROR: .env not found in project root"
  exit 1
fi

: "${SEPOLIA_RPC_URL:?Missing SEPOLIA_RPC_URL in .env}"
: "${ZKSYNC_SEPOLIA_RPC_URL:?Missing ZKSYNC_SEPOLIA_RPC_URL in .env}"

# -------------------------
# 1) ZKsync Sepolia deploys
# -------------------------
foundryup-zksync
forge build --zksync

echo "Deploying RebaseToken on ZKsync..."
ZKSYNC_REBASE_TOKEN_ADDRESS=$(
  forge create src/RebaseToken.sol:RebaseToken \
    --rpc-url "$ZKSYNC_SEPOLIA_RPC_URL" \
    --account zksyncSepoliaKey \
    --legacy --zksync \
    --broadcast \
  | awk '/Deployed to:/ {print $3}' | tail -n1
)
echo "ZKsync rebase token address: $ZKSYNC_REBASE_TOKEN_ADDRESS"
require_addr "ZKSYNC_REBASE_TOKEN_ADDRESS" "$ZKSYNC_REBASE_TOKEN_ADDRESS"

echo "Deploying RebaseTokenPool on ZKsync..."
ZKSYNC_POOL_ADDRESS=$(
  forge create src/RebaseTokenPool.sol:RebaseTokenPool \
    --rpc-url "$ZKSYNC_SEPOLIA_RPC_URL" \
    --account zksyncSepoliaKey \
    --legacy --zksync \
    --broadcast \
    --constructor-args "$ZKSYNC_REBASE_TOKEN_ADDRESS" "[]" "$ZKSYNC_RNM_PROXY_ADDRESS" "$ZKSYNC_ROUTER" \
  | awk '/Deployed to:/ {print $3}' | tail -n1
)
echo "ZKsync pool address: $ZKSYNC_POOL_ADDRESS"
require_addr "ZKSYNC_POOL_ADDRESS" "$ZKSYNC_POOL_ADDRESS"

echo "Granting mint/burn role to ZKsync pool..."
cast send \
  --rpc-url "$ZKSYNC_SEPOLIA_RPC_URL" \
  --account zksyncSepoliaKey \
  "$ZKSYNC_REBASE_TOKEN_ADDRESS" \
  "grantMintAndBurnRole(address)" \
  "$ZKSYNC_POOL_ADDRESS"

echo "Setting CCIP registry/admin roles on ZKsync..."
cast send \
  --rpc-url "$ZKSYNC_SEPOLIA_RPC_URL" \
  --account zksyncSepoliaKey \
  "$ZKSYNC_REGISTRY_MODULE_OWNER_CUSTOM" \
  "registerAdminViaOwner(address)" \
  "$ZKSYNC_REBASE_TOKEN_ADDRESS"

cast send \
  --rpc-url "$ZKSYNC_SEPOLIA_RPC_URL" \
  --account zksyncSepoliaKey \
  "$ZKSYNC_TOKEN_ADMIN_REGISTRY" \
  "acceptAdminRole(address)" \
  "$ZKSYNC_REBASE_TOKEN_ADDRESS"

cast send \
  --rpc-url "$ZKSYNC_SEPOLIA_RPC_URL" \
  --account zksyncSepoliaKey \
  "$ZKSYNC_TOKEN_ADMIN_REGISTRY" \
  "setPool(address,address)" \
  "$ZKSYNC_REBASE_TOKEN_ADDRESS" \
  "$ZKSYNC_POOL_ADDRESS"

echo "ZKsync setup done."

# -------------------------
# 2) Sepolia deploys
# -------------------------
echo "Deploying token + pool on Sepolia..."
output=$(
  forge script ./script/Deployer.s.sol:TokenAndPoolDeployer \
    --rpc-url "$SEPOLIA_RPC_URL" \
    --account sepoliaKey \
    --broadcast \
  2>&1
)

SEPOLIA_REBASE_TOKEN_ADDRESS=$(echo "$output" | grep -m1 'token: contract RebaseToken' | awk '{print $NF}')
SEPOLIA_POOL_ADDRESS=$(echo "$output" | grep -m1 'pool: contract RebaseTokenPool' | awk '{print $NF}')

echo "Sepolia rebase token address: $SEPOLIA_REBASE_TOKEN_ADDRESS"
echo "Sepolia pool address: $SEPOLIA_POOL_ADDRESS"
require_addr "SEPOLIA_REBASE_TOKEN_ADDRESS" "$SEPOLIA_REBASE_TOKEN_ADDRESS"
require_addr "SEPOLIA_POOL_ADDRESS" "$SEPOLIA_POOL_ADDRESS"

# -------------------------
# Vault deploy (avoid broken pipe)
# -------------------------
echo "Deploying Vault on Sepolia..."
vault_output=$(
  forge script ./script/Deployer.s.sol:VaultDeployer \
    --rpc-url "$SEPOLIA_RPC_URL" \
    --account sepoliaKey \
    --broadcast \
    --sig "run(address)" \
    "$SEPOLIA_REBASE_TOKEN_ADDRESS" \
  2>&1
)

echo "$vault_output"

VAULT_ADDRESS=$(echo "$vault_output" | awk '/vault: contract Vault/ {print $NF}' | tail -n1)
if [[ -z "${VAULT_ADDRESS:-}" ]]; then
  VAULT_ADDRESS=$(echo "$vault_output" | grep -Eo '0x[a-fA-F0-9]{40}' | tail -n1)
fi

echo "Vault address: $VAULT_ADDRESS"
require_addr "VAULT_ADDRESS" "$VAULT_ADDRESS"

# -------------------------
# 3) Configure pools both directions (older TokenPool API)
# -------------------------
echo "Configuring Sepolia pool -> ZKsync..."
forge script ./script/ConfigurePool.s.sol:ConfigurePoolScript \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account sepoliaKey \
  --broadcast \
  --sig "run(address,uint64,address,address,bool,uint128,uint128,bool,uint128,uint128)" \
  "$SEPOLIA_POOL_ADDRESS" \
  "$ZKSYNC_SEPOLIA_CHAIN_SELECTOR" \
  "$ZKSYNC_POOL_ADDRESS" \
  "$ZKSYNC_REBASE_TOKEN_ADDRESS" \
  false 0 0 false 0 0

echo "Depositing funds to the vault on Sepolia..."
cast send \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account sepoliaKey \
  --value "$AMOUNT" \
  "$VAULT_ADDRESS" \
  "deposit()"

echo "Configuring ZKsync pool -> Sepolia..."
forge script ./script/ConfigurePool.s.sol:ConfigurePoolScript \
  --rpc-url "$ZKSYNC_SEPOLIA_RPC_URL" \
  --account zksyncSepoliaKey \
  --broadcast \
  --zksync --legacy \
  --sig "run(address,uint64,address,address,bool,uint128,uint128,bool,uint128,uint128)" \
  "$ZKSYNC_POOL_ADDRESS" \
  "$SEPOLIA_CHAIN_SELECTOR" \
  "$SEPOLIA_POOL_ADDRESS" \
  "$SEPOLIA_REBASE_TOKEN_ADDRESS" \
  false 0 0 false 0 0

# -------------------------
# 4) Bridge + verify arrival on zkSync
# -------------------------
SENDER_SEPOLIA="$(cast wallet address --account sepoliaKey)"
echo "Sender (Sepolia EOA): $SENDER_SEPOLIA"

SEPOLIA_BALANCE_BEFORE="$(erc20_balance "$SEPOLIA_RPC_URL" "$SEPOLIA_REBASE_TOKEN_ADDRESS" "$SENDER_SEPOLIA")"
ZKSYNC_BALANCE_BEFORE="$(erc20_balance "$ZKSYNC_SEPOLIA_RPC_URL" "$ZKSYNC_REBASE_TOKEN_ADDRESS" "$SENDER_SEPOLIA")"

echo "Sepolia token balance before bridging: $SEPOLIA_BALANCE_BEFORE"
echo "zkSync token balance before bridging:  $ZKSYNC_BALANCE_BEFORE"

echo "Bridging funds to zkSync..."
forge script ./script/BridgeTokens.s.sol:BridgeTokensScript \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account sepoliaKey \
  --broadcast \
  --sig "run(address,uint64,address,uint256,address,address)" \
  "$SENDER_SEPOLIA" \
  "$ZKSYNC_SEPOLIA_CHAIN_SELECTOR" \
  "$SEPOLIA_REBASE_TOKEN_ADDRESS" \
  "$AMOUNT" \
  "$SEPOLIA_LINK_ADDRESS" \
  "$SEPOLIA_ROUTER"

SEPOLIA_BALANCE_AFTER="$(erc20_balance "$SEPOLIA_RPC_URL" "$SEPOLIA_REBASE_TOKEN_ADDRESS" "$SENDER_SEPOLIA")"
echo "Sepolia token balance after bridging:  $SEPOLIA_BALANCE_AFTER"