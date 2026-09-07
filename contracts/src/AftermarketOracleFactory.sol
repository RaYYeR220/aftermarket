// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AftermarketOracle, OracleConfig} from "./AftermarketOracle.sol";

/// @title  AftermarketOracleFactory
/// @notice Deterministic, ownerless deployer for `AftermarketOracle` instances.
/// @dev One config hashes to one salt, which hashes to one address: the same parameters can only ever
///      produce the same oracle, and anybody can recompute that address off-chain before trusting it.
///      There is no owner, no pause and no registry write that can change an already deployed oracle -
///      each instance is immutable the moment it lands.
contract AftermarketOracleFactory {
    /// @notice Emitted for every oracle this factory deploys.
    /// @param oracle          Address of the freshly deployed oracle.
    /// @param collateralToken B20 collateral the oracle prices.
    /// @param loanToken       Loan-side asset the price is quoted in.
    /// @param salt            CREATE2 salt, equal to `saltFor(cfg)`.
    event OracleDeployed(
        address indexed oracle, address indexed collateralToken, address indexed loanToken, bytes32 salt
    );

    /// @notice Canonical oracle per (collateral, loan) pair. First deployment wins.
    /// @dev Advisory index only. Later deployments for the same pair still succeed and still emit
    ///      `OracleDeployed`, they simply do not overwrite the first entry, so this mapping can never
    ///      be repointed at a differently configured oracle after the fact. Integrators that care
    ///      about a specific configuration should verify the address with `predictAddress`.
    mapping(address collateralToken => mapping(address loanToken => address oracle)) public oracleFor;

    /// @notice Deploys the oracle described by `cfg` at its deterministic address.
    /// @dev Reverts when an oracle with an identical config already exists, because CREATE2 refuses to
    ///      overwrite. Every parameter validation lives in the oracle constructor.
    /// @param cfg Full immutable oracle configuration.
    /// @return oracle The deployed oracle.
    function deploy(OracleConfig calldata cfg) external returns (AftermarketOracle oracle) {
        bytes32 salt = saltFor(cfg);
        oracle = new AftermarketOracle{salt: salt}(cfg);

        if (oracleFor[cfg.collateralToken][cfg.loanToken] == address(0)) {
            oracleFor[cfg.collateralToken][cfg.loanToken] = address(oracle);
        }
        emit OracleDeployed(address(oracle), cfg.collateralToken, cfg.loanToken, salt);
    }

    /// @notice The CREATE2 salt for `cfg`.
    /// @param cfg Full immutable oracle configuration.
    /// @return The salt, equal to `keccak256(abi.encode(cfg))`.
    function saltFor(OracleConfig calldata cfg) public pure returns (bytes32) {
        return keccak256(abi.encode(cfg));
    }

    /// @notice The address `deploy(cfg)` would produce, computable before deployment.
    /// @param cfg Full immutable oracle configuration.
    /// @return The counterfactual oracle address.
    function predictAddress(OracleConfig calldata cfg) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(AftermarketOracle).creationCode, abi.encode(cfg)));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), saltFor(cfg), initCodeHash))))
            );
    }
}
