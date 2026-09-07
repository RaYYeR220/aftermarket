/**
 * The contract surface the app compiles against.
 *
 * Every fragment below is taken verbatim from the Foundry artifacts in `contracts/out` for the
 * frozen Base mainnet deployment recorded in `contracts/deployments/8453.json`, trimmed to the
 * entry points this application actually calls. Trimming keeps the client bundle small; it never
 * edits a signature, so a selector computed here is the selector the deployed bytecode answers to.
 *
 * Errors are kept in full wherever a call can revert, because a revert this app cannot decode is a
 * revert it would have to render as a generic failure -- which is the one thing this product must
 * never do.
 */

/**
 * AftermarketLens: every read the app surface makes about the protocol, an asset or a line.
 * Total by construction -- see `IAftermarketLens` -- so a screen never loses its data because an
 * oracle refused.
 */
export const lensAbi = [
  {
    "type": "function",
    "name": "assetView",
    "inputs": [
      {
        "name": "asset",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct IAftermarketLens.AssetView",
        "components": [
          {
            "name": "asset",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "symbol",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "decimals",
            "type": "uint8",
            "internalType": "uint8"
          },
          {
            "name": "oracle",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "quote",
            "type": "tuple",
            "internalType": "struct Quote",
            "components": [
              {
                "name": "verdict",
                "type": "uint8",
                "internalType": "enum Verdict"
              },
              {
                "name": "session",
                "type": "uint8",
                "internalType": "enum Session"
              },
              {
                "name": "anchorPrice",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "poolPrice",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "markBorrow",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "markLiquidate",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "feedAge",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "stalenessBudget",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "divergenceBps",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "divergenceBand",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "haircutBps",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "multiplier",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "poolLiquidityUsd",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "nextOpen",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "lastClose",
                "type": "uint64",
                "internalType": "uint64"
              }
            ]
          },
          {
            "name": "quoteOk",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "advanceBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "liqThresholdBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "cap",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "posted",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "enabled",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "borrowApr",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "supplyApr",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "assetViews",
    "inputs": [],
    "outputs": [
      {
        "name": "views",
        "type": "tuple[]",
        "internalType": "struct IAftermarketLens.AssetView[]",
        "components": [
          {
            "name": "asset",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "symbol",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "decimals",
            "type": "uint8",
            "internalType": "uint8"
          },
          {
            "name": "oracle",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "quote",
            "type": "tuple",
            "internalType": "struct Quote",
            "components": [
              {
                "name": "verdict",
                "type": "uint8",
                "internalType": "enum Verdict"
              },
              {
                "name": "session",
                "type": "uint8",
                "internalType": "enum Session"
              },
              {
                "name": "anchorPrice",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "poolPrice",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "markBorrow",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "markLiquidate",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "feedAge",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "stalenessBudget",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "divergenceBps",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "divergenceBand",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "haircutBps",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "multiplier",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "poolLiquidityUsd",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "nextOpen",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "lastClose",
                "type": "uint64",
                "internalType": "uint64"
              }
            ]
          },
          {
            "name": "quoteOk",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "advanceBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "liqThresholdBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "cap",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "posted",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "enabled",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "borrowApr",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "supplyApr",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "previewDraw",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "p",
        "type": "tuple",
        "internalType": "struct IAftermarketLens.DrawPreview",
        "components": [
          {
            "name": "ok",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "reason",
            "type": "uint8",
            "internalType": "uint8"
          },
          {
            "name": "debtAfter",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "borrowPower",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "healthBps",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "previewWithdraw",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "asset",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "p",
        "type": "tuple",
        "internalType": "struct IAftermarketLens.WithdrawPreview",
        "components": [
          {
            "name": "ok",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "reason",
            "type": "uint8",
            "internalType": "uint8"
          },
          {
            "name": "borrowPowerAfter",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "seizureThresholdAfter",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "healthBps",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "protocolView",
    "inputs": [],
    "outputs": [
      {
        "name": "v",
        "type": "tuple",
        "internalType": "struct IAftermarketLens.ProtocolView",
        "components": [
          {
            "name": "session",
            "type": "uint8",
            "internalType": "enum Session"
          },
          {
            "name": "nextOpen",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "lastClose",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "totalDebt",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "totalSupplied",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "utilisation",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "vaultSharePrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "assets",
            "type": "address[]",
            "internalType": "address[]"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "userView",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "v",
        "type": "tuple",
        "internalType": "struct IAftermarketLens.UserView",
        "components": [
          {
            "name": "user",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "collateral",
            "type": "address[]",
            "internalType": "address[]"
          },
          {
            "name": "amounts",
            "type": "uint256[]",
            "internalType": "uint256[]"
          },
          {
            "name": "debt",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "borrowPower",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "seizureThreshold",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "healthBps",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "priced",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "graceUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "flaggedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "eligible",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "country",
            "type": "bytes2",
            "internalType": "bytes2"
          },
          {
            "name": "autoRepayEnrolled",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "stateMutability": "view"
  }
] as const;

/**
 * AftermarketCredit: the write surface a borrower operates, plus the full typed-error vocabulary
 * so a rejected call can be rendered as the reason it was rejected for.
 */
export const creditAbi = [
  {
    "type": "function",
    "name": "accrue",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "assetsOf",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address[]",
        "internalType": "address[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "collateral",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "asset",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "cure",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "debtOf",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "depositCollateral",
    "inputs": [
      {
        "name": "asset",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "draw",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "flag",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "openLine",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "positionOf",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "p",
        "type": "tuple",
        "internalType": "struct IAftermarketCredit.Position",
        "components": [
          {
            "name": "debtAssets",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "debtShares",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "borrowPower",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "seizureThreshold",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "healthFactor",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "priced",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "flagged",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "openedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "flaggedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "graceUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "autoRepayEnabled",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "session",
            "type": "uint8",
            "internalType": "enum Session"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "repay",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "repaidAssets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "repaidShares",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setAutoRepay",
    "inputs": [
      {
        "name": "enabled",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "withdrawCollateral",
    "inputs": [
      {
        "name": "asset",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "AutoRepaySet",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "enabled",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BadDebtRealized",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "shares",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "CollateralDeposited",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "asset",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "balance",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "CollateralWithdrawn",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "asset",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Drawn",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "shares",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "LineCured",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "caller",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "debtAssets",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "seizureThreshold",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "LineFlagged",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "keeper",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "debtAssets",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "seizureThreshold",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "graceUntil",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      },
      {
        "name": "nextOpen",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      },
      {
        "name": "session",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum Session"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "LineOpened",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "openedAt",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Liquidated",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "liquidator",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "collateralAsset",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "repaidAssets",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "repaidShares",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "seized",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "receiver",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Repaid",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "payer",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "shares",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "YieldSwept",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "asset",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "fromMultiplier",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "toMultiplier",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "sold",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "proceeds",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "repaid",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "surplus",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AlreadyFlagged",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "graceUntil",
        "type": "uint64",
        "internalType": "uint64"
      }
    ]
  },
  {
    "type": "error",
    "name": "AssetCapExceeded",
    "inputs": [
      {
        "name": "asset",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "posted",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "cap",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "AssetNotEnabled",
    "inputs": [
      {
        "name": "asset",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "AutoRepayDisabled",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "CalendarHorizon",
    "inputs": []
  },
  {
    "type": "error",
    "name": "CloseFactorExceeded",
    "inputs": [
      {
        "name": "requested",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "maxRepay",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "CureIncomplete",
    "inputs": [
      {
        "name": "debtAssets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "borrowPower",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "GraceNotExpired",
    "inputs": [
      {
        "name": "graceUntil",
        "type": "uint64",
        "internalType": "uint64"
      }
    ]
  },
  {
    "type": "error",
    "name": "InsufficientCollateral",
    "inputs": [
      {
        "name": "asset",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "balance",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "requested",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidAssetConfig",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidSlippage",
    "inputs": [
      {
        "name": "maxSlippageBps",
        "type": "uint16",
        "internalType": "uint16"
      }
    ]
  },
  {
    "type": "error",
    "name": "LineAlreadyOpen",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "LineHealthy",
    "inputs": [
      {
        "name": "debtAssets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "seizureThreshold",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "LineIsFlagged",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "LineNotDust",
    "inputs": [
      {
        "name": "seizureThreshold",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "debtAssets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "LineNotOpen",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "MarketClosed",
    "inputs": [
      {
        "name": "session",
        "type": "uint8",
        "internalType": "enum Session"
      }
    ]
  },
  {
    "type": "error",
    "name": "NoDebt",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "NotFlagged",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "NothingToSweep",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "asset",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "OracleAssetMismatch",
    "inputs": [
      {
        "name": "expected",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "actual",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "Overflow",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OwnableInvalidOwner",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "OwnableUnauthorizedAccount",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SafeERC20FailedOperation",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "SlippageExceeded",
    "inputs": [
      {
        "name": "amountOut",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minOut",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "SweepTooLarge",
    "inputs": [
      {
        "name": "sold",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "cap",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "TooManyAssets",
    "inputs": [
      {
        "name": "max",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "Undercollateralized",
    "inputs": [
      {
        "name": "debtAssets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "borrowPower",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "UnpricedCollateral",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ZeroAddress",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ZeroAmount",
    "inputs": []
  }
] as const;

/**
 * AftermarketVault: the ERC-4626 lender surface plus `idleAssets`, which is the number that
 * decides whether a draw can actually be funded.
 */
export const vaultAbi = [
  {
    "type": "function",
    "name": "asset",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "convertToAssets",
    "inputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "convertToShares",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "decimals",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "deposit",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "idleAssets",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "maxRedeem",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "maxWithdraw",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "name",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "previewDeposit",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "previewRedeem",
    "inputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "redeem",
    "inputs": [
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "symbol",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalAssets",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalSupply",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "withdraw",
    "inputs": [
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "Deposit",
    "inputs": [
      {
        "name": "sender",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "owner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "shares",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Lent",
    "inputs": [
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Settled",
    "inputs": [
      {
        "name": "from",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Withdraw",
    "inputs": [
      {
        "name": "sender",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "receiver",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "owner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "shares",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "CreditMismatch",
    "inputs": [
      {
        "name": "expected",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "actual",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InsufficientAllowance",
    "inputs": [
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "allowance",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "needed",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InsufficientBalance",
    "inputs": [
      {
        "name": "sender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "balance",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "needed",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidApprover",
    "inputs": [
      {
        "name": "approver",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidReceiver",
    "inputs": [
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidSender",
    "inputs": [
      {
        "name": "sender",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidSpender",
    "inputs": [
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC4626ExceededMaxDeposit",
    "inputs": [
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "max",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC4626ExceededMaxMint",
    "inputs": [
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "max",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC4626ExceededMaxRedeem",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "shares",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "max",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC4626ExceededMaxWithdraw",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "assets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "max",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "InsufficientLiquidity",
    "inputs": [
      {
        "name": "requested",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "idle",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "NotCredit",
    "inputs": [
      {
        "name": "caller",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SafeERC20FailedOperation",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ZeroAddress",
    "inputs": []
  }
] as const;

/**
 * AutoRepayer: enrolment, the mandate, and the three reads that explain a refusal --
 * `simulate`, `spendableFor` and `healthBpsOf`.
 */
export const autoRepayerAbi = [
  {
    "type": "function",
    "name": "RECOVERY_MARGIN_BPS",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "SPEND_PERMISSION_MANAGER",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "cancel",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "credit",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract AftermarketCredit"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "enroll",
    "inputs": [
      {
        "name": "permission",
        "type": "tuple",
        "internalType": "struct SpendPermission",
        "components": [
          {
            "name": "account",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "spender",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "token",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "allowance",
            "type": "uint160",
            "internalType": "uint160"
          },
          {
            "name": "period",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "start",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "end",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "salt",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "extraData",
            "type": "bytes",
            "internalType": "bytes"
          }
        ]
      },
      {
        "name": "policy",
        "type": "tuple",
        "internalType": "struct IAutoRepayer.Policy",
        "components": [
          {
            "name": "maxPerExecution",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "minInterval",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "triggerHealthBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "enabled",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "enrollmentOf",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct IAutoRepayer.Enrollment",
        "components": [
          {
            "name": "permissionHash",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "lastExecutedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "policy",
            "type": "tuple",
            "internalType": "struct IAutoRepayer.Policy",
            "components": [
              {
                "name": "maxPerExecution",
                "type": "uint128",
                "internalType": "uint128"
              },
              {
                "name": "minInterval",
                "type": "uint32",
                "internalType": "uint32"
              },
              {
                "name": "triggerHealthBps",
                "type": "uint16",
                "internalType": "uint16"
              },
              {
                "name": "enabled",
                "type": "bool",
                "internalType": "bool"
              }
            ]
          },
          {
            "name": "permission",
            "type": "tuple",
            "internalType": "struct SpendPermission",
            "components": [
              {
                "name": "account",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "spender",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "token",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "allowance",
                "type": "uint160",
                "internalType": "uint160"
              },
              {
                "name": "period",
                "type": "uint48",
                "internalType": "uint48"
              },
              {
                "name": "start",
                "type": "uint48",
                "internalType": "uint48"
              },
              {
                "name": "end",
                "type": "uint48",
                "internalType": "uint48"
              },
              {
                "name": "salt",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "extraData",
                "type": "bytes",
                "internalType": "bytes"
              }
            ]
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "healthBpsOf",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isEnrolled",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "poke",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "acted",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "reason",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setPolicy",
    "inputs": [
      {
        "name": "policy",
        "type": "tuple",
        "internalType": "struct IAutoRepayer.Policy",
        "components": [
          {
            "name": "maxPerExecution",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "minInterval",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "triggerHealthBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "enabled",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "simulate",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "willAct",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "reason",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "spendableFor",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "usdc",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IERC20"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "withdraw",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "AutoRepaid",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "healthBefore",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "healthAfter",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "session",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum Session"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "AutoRepayRefused",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "reason",
        "type": "uint8",
        "indexed": false,
        "internalType": "uint8"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Cancelled",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "permissionHash",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "revoked",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Enrolled",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "permissionHash",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "policy",
        "type": "tuple",
        "indexed": false,
        "internalType": "struct IAutoRepayer.Policy",
        "components": [
          {
            "name": "maxPerExecution",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "minInterval",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "triggerHealthBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "enabled",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PolicyUpdated",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "policy",
        "type": "tuple",
        "indexed": false,
        "internalType": "struct IAutoRepayer.Policy",
        "components": [
          {
            "name": "maxPerExecution",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "minInterval",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "triggerHealthBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "enabled",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Refunded",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Withdrawn",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "permissionHash",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AboveMaxPerExecution",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "maxPerExecution",
        "type": "uint128",
        "internalType": "uint128"
      }
    ]
  },
  {
    "type": "error",
    "name": "IntervalNotElapsed",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "lastExecutedAt",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "minInterval",
        "type": "uint32",
        "internalType": "uint32"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidPolicy",
    "inputs": [
      {
        "name": "policy",
        "type": "tuple",
        "internalType": "struct IAutoRepayer.Policy",
        "components": [
          {
            "name": "maxPerExecution",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "minInterval",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "triggerHealthBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "enabled",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ]
  },
  {
    "type": "error",
    "name": "LineHealthy",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "healthBps",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "triggerHealthBps",
        "type": "uint16",
        "internalType": "uint16"
      }
    ]
  },
  {
    "type": "error",
    "name": "NotEnrolled",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "NothingToRepay",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "OracleUntrusted",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "PermissionAccountMismatch",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "caller",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "PermissionAllowanceZero",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PermissionExpired",
    "inputs": [
      {
        "name": "end",
        "type": "uint48",
        "internalType": "uint48"
      }
    ]
  },
  {
    "type": "error",
    "name": "PermissionSpenderMismatch",
    "inputs": [
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "expected",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "PermissionTokenMismatch",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "expected",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "PermissionUnavailable",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "available",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "PolicyDisabled",
    "inputs": [
      {
        "name": "user",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SafeERC20FailedOperation",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ZeroAddress",
    "inputs": []
  }
] as const;

/**
 * AftermarketOracle: `peek` never reverts, `price` reverts with one of the five typed errors.
 * Both are read side by side on the oracle screen.
 */
export const oracleAbi = [
  {
    "type": "function",
    "name": "baseHaircutBps",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "collateralToken",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "divergenceBand",
    "inputs": [
      {
        "name": "session",
        "type": "uint8",
        "internalType": "enum Session"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "feed",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "haircutSlopeBpsPerHour",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "loanToken",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "markBorrow",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "markLiquidate",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "maxHaircutBps",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "minPoolLiquidityUsd",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint128",
        "internalType": "uint128"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "peek",
    "inputs": [],
    "outputs": [
      {
        "name": "q",
        "type": "tuple",
        "internalType": "struct Quote",
        "components": [
          {
            "name": "verdict",
            "type": "uint8",
            "internalType": "enum Verdict"
          },
          {
            "name": "session",
            "type": "uint8",
            "internalType": "enum Session"
          },
          {
            "name": "anchorPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "poolPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "markBorrow",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "markLiquidate",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "feedAge",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stalenessBudget",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "divergenceBps",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "divergenceBand",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "haircutBps",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "multiplier",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "poolLiquidityUsd",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "nextOpen",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "lastClose",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pool",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "price",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "stalenessBudget",
    "inputs": [
      {
        "name": "session",
        "type": "uint8",
        "internalType": "enum Session"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "twapWindow",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint32",
        "internalType": "uint32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "error",
    "name": "InvalidDivergenceBand",
    "inputs": [
      {
        "name": "bandBps",
        "type": "uint16",
        "internalType": "uint16"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidFeedAnswer",
    "inputs": [
      {
        "name": "answer",
        "type": "int256",
        "internalType": "int256"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidHaircutConfig",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidMultiplierBounds",
    "inputs": [
      {
        "name": "lowerBound",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "upperBound",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "current",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidTwapWindow",
    "inputs": [
      {
        "name": "window",
        "type": "uint32",
        "internalType": "uint32"
      }
    ]
  },
  {
    "type": "error",
    "name": "MarketHalted",
    "inputs": [
      {
        "name": "multiplier",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "PoolTokenMismatch",
    "inputs": [
      {
        "name": "token0",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "token1",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "PoolTooThin",
    "inputs": [
      {
        "name": "liquidityUsd",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minLiquidityUsd",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "SourcesDiverged",
    "inputs": [
      {
        "name": "session",
        "type": "uint8",
        "internalType": "enum Session"
      },
      {
        "name": "divergenceBps",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "band",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "StaleFeed",
    "inputs": [
      {
        "name": "session",
        "type": "uint8",
        "internalType": "enum Session"
      },
      {
        "name": "age",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "budget",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "TickOutOfBounds",
    "inputs": [
      {
        "name": "tick",
        "type": "int24",
        "internalType": "int24"
      }
    ]
  },
  {
    "type": "error",
    "name": "UnsupportedDecimals",
    "inputs": [
      {
        "name": "tokenDecimals",
        "type": "uint8",
        "internalType": "uint8"
      }
    ]
  },
  {
    "type": "error",
    "name": "ZeroAddress",
    "inputs": []
  }
] as const;

/**
 * SessionRateModel: the curve plus `ratePerSecondAt`, which prices the same utilisation in a
 * session other than the current one -- the closed-market premium, read rather than asserted.
 */
export const sessionRateModelAbi = [
  {
    "type": "function",
    "name": "baseRatePerSecond",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "curveRatePerSecond",
    "inputs": [
      {
        "name": "totalDebtAssets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalAssets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "kink",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "ratePerSecond",
    "inputs": [
      {
        "name": "totalDebtAssets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalAssets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "ratePerSecondAt",
    "inputs": [
      {
        "name": "totalDebtAssets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalAssets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "session",
        "type": "uint8",
        "internalType": "enum Session"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "sessionMultiplier",
    "inputs": [
      {
        "name": "session",
        "type": "uint8",
        "internalType": "enum Session"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "slope1PerSecond",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "slope2PerSecond",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "utilization",
    "inputs": [
      {
        "name": "totalDebtAssets",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "totalAssets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  }
] as const;

/**
 * RegSGate: whether an account is admitted, and the country it proved.
 */
export const regSGateAbi = [
  {
    "type": "function",
    "name": "check",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "ok",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "country",
        "type": "bytes2",
        "internalType": "bytes2"
      },
      {
        "name": "source",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "checkNonBlocking",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isRestricted",
    "inputs": [
      {
        "name": "country",
        "type": "bytes2",
        "internalType": "bytes2"
      }
    ],
    "outputs": [
      {
        "name": "restricted",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "restrictedJurisdictions",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes2[]",
        "internalType": "bytes2[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "verifiedCountryOf",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes2",
        "internalType": "bytes2"
      }
    ],
    "stateMutability": "view"
  }
] as const;

/**
 * Coinbase's SpendPermissionManager, at the same address on Base mainnet and Base Sepolia.
 * The account approves its own permission here; `AutoRepayer` only ever spends against it.
 */
export const spendPermissionManagerAbi = [
  {
    "type": "function",
    "name": "approve",
    "inputs": [
      {
        "name": "spendPermission",
        "type": "tuple",
        "internalType": "struct SpendPermissionManager.SpendPermission",
        "components": [
          {
            "name": "account",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "spender",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "token",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "allowance",
            "type": "uint160",
            "internalType": "uint160"
          },
          {
            "name": "period",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "start",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "end",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "salt",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "extraData",
            "type": "bytes",
            "internalType": "bytes"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "approved",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "revoke",
    "inputs": [
      {
        "name": "spendPermission",
        "type": "tuple",
        "internalType": "struct SpendPermissionManager.SpendPermission",
        "components": [
          {
            "name": "account",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "spender",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "token",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "allowance",
            "type": "uint160",
            "internalType": "uint160"
          },
          {
            "name": "period",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "start",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "end",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "salt",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "extraData",
            "type": "bytes",
            "internalType": "bytes"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getCurrentPeriod",
    "inputs": [
      {
        "name": "spendPermission",
        "type": "tuple",
        "internalType": "struct SpendPermission",
        "components": [
          {
            "name": "account",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "spender",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "token",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "allowance",
            "type": "uint160",
            "internalType": "uint160"
          },
          {
            "name": "period",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "start",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "end",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "salt",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "extraData",
            "type": "bytes",
            "internalType": "bytes"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct ISpendPermissionManager.PeriodSpend",
        "components": [
          {
            "name": "start",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "end",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "spend",
            "type": "uint160",
            "internalType": "uint160"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getHash",
    "inputs": [
      {
        "name": "spendPermission",
        "type": "tuple",
        "internalType": "struct SpendPermission",
        "components": [
          {
            "name": "account",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "spender",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "token",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "allowance",
            "type": "uint160",
            "internalType": "uint160"
          },
          {
            "name": "period",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "start",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "end",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "salt",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "extraData",
            "type": "bytes",
            "internalType": "bytes"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isValid",
    "inputs": [
      {
        "name": "spendPermission",
        "type": "tuple",
        "internalType": "struct SpendPermission",
        "components": [
          {
            "name": "account",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "spender",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "token",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "allowance",
            "type": "uint160",
            "internalType": "uint160"
          },
          {
            "name": "period",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "start",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "end",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "salt",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "extraData",
            "type": "bytes",
            "internalType": "bytes"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "spend",
    "inputs": [
      {
        "name": "spendPermission",
        "type": "tuple",
        "internalType": "struct SpendPermission",
        "components": [
          {
            "name": "account",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "spender",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "token",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "allowance",
            "type": "uint160",
            "internalType": "uint160"
          },
          {
            "name": "period",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "start",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "end",
            "type": "uint48",
            "internalType": "uint48"
          },
          {
            "name": "salt",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "extraData",
            "type": "bytes",
            "internalType": "bytes"
          }
        ]
      },
      {
        "name": "value",
        "type": "uint160",
        "internalType": "uint160"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  }
] as const;

/**
 * The five ERC-20 entry points the app needs: two balances, one allowance, one approval, and the
 * two metadata reads that keep a token's own decimals out of a hardcoded table.
 */
export const erc20Abi = [
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "allowance",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "approve",
    "inputs": [
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "value",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "decimals",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "symbol",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  }
] as const;
