#!/usr/bin/env bash
#
# Source-verify every deployed Aftermarket contract on Base mainnet, without an
# explorer API key.
#
#   scripts/verify-sources.sh              # Sourcify (default)
#   scripts/verify-sources.sh sourcify
#   scripts/verify-sources.sh blockscout
#   scripts/verify-sources.sh status       # just report what each verifier currently holds
#
# Addresses and ABI-encoded constructor arguments come from
# contracts/deployments/8453.json, which the deploy script writes. The compiler
# settings come from contracts/foundry.toml and must match the deploy exactly:
# solc 0.8.28, optimizer on, 200 runs, evm_version cancun, via_ir off.
#
# Note on BASESCAN_API_KEY: foundry.toml carries an [etherscan] block that
# interpolates it. If it is unset, forge errors before it reaches the verifier;
# if it is set to a non-empty value, forge prefers Etherscan over the verifier
# you asked for. Exporting it *empty* is what makes the key-less path work.

set -uo pipefail

MODE="${1:-sourcify}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS="$ROOT/contracts"
MANIFEST="$CONTRACTS/deployments/8453.json"

SOURCIFY_URL="https://sourcify.dev/server"
BLOCKSCOUT_URL="https://base.blockscout.com/api"

export BASESCAN_API_KEY=""

command -v forge >/dev/null 2>&1 || { echo "forge not found on PATH"; exit 1; }
command -v node  >/dev/null 2>&1 || { echo "node not found on PATH";  exit 1; }
[ -f "$MANIFEST" ] || { echo "missing $MANIFEST"; exit 1; }

cd "$CONTRACTS"

# name:manifest-path-to-address:contract-path:manifest-path-to-constructor-args (empty = none)
#
# Addresses are read out of the manifest rather than written here, so that a
# redeployment cannot leave this script verifying the previous deployment.
TARGETS=(
  "TradingCalendar:tradingCalendar:src/TradingCalendar.sol:TradingCalendar:"
  "AttesterRegistry:attesterRegistry:src/AttesterRegistry.sol:AttesterRegistry:constructorArgs.attesterRegistry"
  "RegSGate:regSGate:src/RegSGate.sol:RegSGate:constructorArgs.regSGate"
  "SessionRateModel:sessionRateModel:src/SessionRateModel.sol:SessionRateModel:constructorArgs.sessionRateModel"
  "AftermarketOracleFactory:oracleFactory:src/AftermarketOracleFactory.sol:AftermarketOracleFactory:"
  "AerodromeSwapAdapter:swapAdapter:src/adapters/AerodromeSwapAdapter.sol:AerodromeSwapAdapter:constructorArgs.swapAdapter"
  "AftermarketCredit:credit:src/AftermarketCredit.sol:AftermarketCredit:constructorArgs.credit"
  "AftermarketVault:vault:src/AftermarketVault.sol:AftermarketVault:constructorArgs.vault"
  "AutoRepayer:autoRepayer:src/AutoRepayer.sol:AutoRepayer:constructorArgs.autoRepayer"
  "AftermarketLens:lens:src/AftermarketLens.sol:AftermarketLens:constructorArgs.lens"
  "Oracle-NVDAc:oracles.NVDAc:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.NVDAc"
  "Oracle-AAPLc:oracles.AAPLc:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.AAPLc"
  "Oracle-METAc:oracles.METAc:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.METAc"
  "Oracle-GOOGLc:oracles.GOOGLc:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.GOOGLc"
  "Oracle-TSLAc:oracles.TSLAc:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.TSLAc"
  "Oracle-AMZNc:oracles.AMZNc:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.AMZNc"
  "Oracle-NegativeControl:negativeControl:src/AftermarketOracle.sol:AftermarketOracle:"
)

manifest_value() {
  # $1 = dotted path inside deployments/8453.json, or empty
  [ -z "$1" ] && return 0
  node -e '
    const d = require(process.argv[1]);
    const v = process.argv[2].split(".").reduce((o, k) => (o == null ? o : o[k]), d);
    if (v) process.stdout.write(v);
  ' "$MANIFEST" "$1"
}

verify_one() {
  local name="$1" addr="$2" target="$3" args="$4" url="$5"
  local extra=()
  [ -n "$args" ] && extra=(--constructor-args "$args")
  printf '%-26s %s\n' "$name" "$addr"
  forge verify-contract "$addr" "$target" \
    --chain-id 8453 \
    --verifier "$MODE" \
    --verifier-url "$url" \
    "${extra[@]}" 2>&1 | sed 's/^/    /'
}

status_one() {
  local name="$1" addr="$2"
  local sc bs
  sc=$(curl -s --max-time 25 "https://sourcify.dev/server/v2/contract/8453/$addr" \
       | grep -o '"match":"[a-z_]*"' | head -1 | cut -d'"' -f4)
  bs=$(curl -s --max-time 25 "https://base.blockscout.com/api/v2/smart-contracts/$addr" \
       | grep -o '"is_verified":[a-z]*' | head -1 | cut -d: -f2)
  printf '%-26s %s  sourcify=%-14s blockscout=%s\n' \
    "$name" "$addr" "${sc:-none}" "${bs:-unavailable}"
}

case "$MODE" in
  sourcify)   URL="$SOURCIFY_URL" ;;
  blockscout) URL="$BLOCKSCOUT_URL" ;;
  status)     URL="" ;;
  *) echo "usage: $0 [sourcify|blockscout|status]"; exit 2 ;;
esac

if [ "$MODE" = "status" ]; then
  echo "Base mainnet (8453) source verification status"
  echo
  for t in "${TARGETS[@]}"; do
    IFS=':' read -r name addrpath _file _contract _argpath <<< "$t"
    status_one "$name" "$(manifest_value "$addrpath")"
  done
  exit 0
fi

echo "Verifying 17 contracts on $MODE ($URL)"
echo
for t in "${TARGETS[@]}"; do
  IFS=':' read -r name addrpath file contract argpath <<< "$t"
  verify_one "$name" "$(manifest_value "$addrpath")" "$file:$contract" "$(manifest_value "$argpath")" "$URL"
  # Blockscout's free tier rate-limits aggressively; pace the submissions.
  [ "$MODE" = "blockscout" ] && sleep 15
done
