// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../../../src/token/ERC1155/RareERC1155ContractFactory.sol";

/// @title RareERC1155FactoryDeploy
/// @notice Forge deployment script for the ERC1155 clone factory.
/// @dev Reads `PRIVATE_KEY` and optional `RARE_ERC1155_DEFAULT_MINTER` from the environment.
contract RareERC1155FactoryDeploy is Script {
    /// @notice Deploys the ERC1155 factory and optionally configures the default minter.
    function run() external {
        // Environment read: select deployer key for broadcast signing.
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Broadcast boundary: following operations are submitted as deployer transactions.
        vm.startBroadcast(deployerPrivateKey);

        // Deployment operation: create the factory and its initial ERC1155 implementation.
        RareERC1155ContractFactory factory = new RareERC1155ContractFactory();

        // Environment read: optional minter approved on future factory-created collections.
        address defaultMinter = vm.envOr("RARE_ERC1155_DEFAULT_MINTER", address(0));
        if (defaultMinter != address(0)) {
            // State write transaction: configure default minter when provided.
            factory.setDefaultMinter(defaultMinter);
        }

        // Broadcast boundary: stop submitting transactions.
        vm.stopBroadcast();
    }
}
