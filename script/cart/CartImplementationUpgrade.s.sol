// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Script} from "forge-std/Script.sol";

/// @title CartImplementationUpgrade
/// @notice Disabled: the signed-checkout migration also requires a new executor and hashing helpers.
/// @dev Use CartFreeListingUpgrade or CartImplementationLensAndHashesUpgrade to deploy the matching bundle.
contract CartImplementationUpgrade is Script {
    error MatchingSettlementBundleRequired();

    function run() external pure {
        // Fail before any broadcast rather than reuse an executor with an incompatible order ABI.
        revert MatchingSettlementBundleRequired();
    }
}
