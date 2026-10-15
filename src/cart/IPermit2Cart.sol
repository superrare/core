// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/// @notice Minimal Permit2 surface used by Cart for Universal Router routing.
interface IPermit2Cart {
    /// @notice Gives a spender a temporary allowance for a token.
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    /// @notice Reads a token allowance for an owner and spender.
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}
