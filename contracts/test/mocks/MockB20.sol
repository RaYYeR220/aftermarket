// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal stand-in for a Coinbase B20 token, and for a plain ERC-20 loan asset.
/// @dev Test double only. Exposes just the surface `AftermarketOracle` reads: `decimals`, `balanceOf`,
///      and the corporate-action pair `multiplier()` / `isPaused(PausableFeature)`. `exposeMultiplier`
///      is false for plain ERC-20 collateral, and can be flipped off after construction to simulate a
///      token that stops answering.
contract MockB20 {
    error NoMultiplier();

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address account => uint256 balance) public balanceOf;
    uint256 public totalSupply;

    uint256 internal _multiplier = 1e18;
    bool public exposeMultiplier;
    bool public transferPaused;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, bool exposeMultiplier_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        exposeMultiplier = exposeMultiplier_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setMultiplier(uint256 multiplier_) external {
        _multiplier = multiplier_;
    }

    function setExposeMultiplier(bool exposeMultiplier_) external {
        exposeMultiplier = exposeMultiplier_;
    }

    function setTransferPaused(bool paused) external {
        transferPaused = paused;
    }

    function multiplier() external view returns (uint256) {
        if (!exposeMultiplier) revert NoMultiplier();
        return _multiplier;
    }

    /// @dev `PausableFeature` is `{TRANSFER, MINT, BURN}`; only TRANSFER is modelled.
    function isPaused(uint8 feature) external view returns (bool) {
        return feature == 0 && transferPaused;
    }
}
