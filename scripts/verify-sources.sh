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

# name:address:contract-path:manifest-json-path-to-constructor-args (empty = none)
TARGETS=(
  "TradingCalendar:0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9:src/TradingCalendar.sol:TradingCalendar:"
  "AttesterRegistry:0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E:src/AttesterRegistry.sol:AttesterRegistry:constructorArgs.attesterRegistry"
  "RegSGate:0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C:src/RegSGate.sol:RegSGate:constructorArgs.regSGate"
  "SessionRateModel:0x6d5152d81982DEb660736fC514761E18533a2343:src/SessionRateModel.sol:SessionRateModel:constructorArgs.sessionRateModel"
  "AftermarketOracleFactory:0xD10f2f4a4e9052fD3fa87aAFC529983EdB1c1f8A:src/AftermarketOracleFactory.sol:AftermarketOracleFactory:"
  "AerodromeSwapAdapter:0xfF81282c6353dC3fB0Ca890Da3cdde9BAFcd68fF:src/adapters/AerodromeSwapAdapter.sol:AerodromeSwapAdapter:constructorArgs.swapAdapter"
  "AftermarketCredit:0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3:src/AftermarketCredit.sol:AftermarketCredit:constructorArgs.credit"
  "AftermarketVault:0x00751166Ce3fa20a4143a1F0D848978Db73bd53f:src/AftermarketVault.sol:AftermarketVault:constructorArgs.vault"
  "AutoRepayer:0xEFC7ce780F5030489a027cebde8BeFb7e7ee681A:src/AutoRepayer.sol:AutoRepayer:constructorArgs.autoRepayer"
  "AftermarketLens:0x5A18BdEB02B30b737a2464E02A2a669BF52bC049:src/AftermarketLens.sol:AftermarketLens:constructorArgs.lens"
  "Oracle-NVDAc:0x1E2b20B4703F97710c2600eA73179c6CD1E00b02:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.NVDAc"
  "Oracle-AAPLc:0x6cE58FE71eD10b82c2C0A9a348E82D1ee6D9a8dc:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.AAPLc"
  "Oracle-METAc:0xf5Cc0cc94ecF4866661373f2aa066af76e08dEf2:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.METAc"
  "Oracle-GOOGLc:0x203cDf7e33eA0d652cA54f4807c9d2d1d081C9aA:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.GOOGLc"
  "Oracle-TSLAc:0x74058d51B3b04Ba09be2aa51ab1CE930Dd3c2C99:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.TSLAc"
  "Oracle-AMZNc:0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C:src/AftermarketOracle.sol:AftermarketOracle:constructorArgs.oracles.AMZNc"
  "Oracle-NegativeControl:0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58:src/AftermarketOracle.sol:AftermarketOracle:"
)

ctor_args() {
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
    IFS=':' read -r name addr _file _contract _argpath <<< "$t"
    status_one "$name" "$addr"
  done
  exit 0
fi

echo "Verifying 17 contracts on $MODE ($URL)"
echo
for t in "${TARGETS[@]}"; do
  IFS=':' read -r name addr file contract argpath <<< "$t"
  verify_one "$name" "$addr" "$file:$contract" "$(ctor_args "$argpath")" "$URL"
  # Blockscout's free tier rate-limits aggressively; pace the submissions.
  [ "$MODE" = "blockscout" ] && sleep 15
done
