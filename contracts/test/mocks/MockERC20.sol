// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A test-only ERC20 with configurable decimals and a B20-style dividend multiplier.
/// @dev One token stands in for both sides of the protocol: USDC at 6 decimals with a permanently
///      unit multiplier, and NVDAc-style B20 collateral at 8 decimals whose multiplier can be moved
///      to simulate a distribution that has not happened on mainnet yet.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    /// @notice B20 dividend/split multiplier, WAD.
    uint256 public multiplier = 1e18;

    /// @notice Mirrors `IB20Asset.WAD_PRECISION`.
    uint256 public constant WAD_PRECISION = 1e18;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /// @notice Moves the dividend multiplier, exactly as a B20 issuer would.
    function setMultiplier(uint256 newMultiplier) external {
        multiplier = newMultiplier;
    }

    /// @notice Mirrors `IB20Asset.toScaledBalance`.
    function toScaledBalance(uint256 rawBalance) external view returns (uint256) {
        return rawBalance * multiplier / WAD_PRECISION;
    }

    /// @notice Mirrors `IB20Asset.scaledBalanceOf`.
    function scaledBalanceOf(address account) external view returns (uint256) {
        return balanceOf(account) * multiplier / WAD_PRECISION;
    }
}
