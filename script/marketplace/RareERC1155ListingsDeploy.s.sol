// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/marketplace/RareERC1155Listings.sol";

/// @title RareERC1155ListingsDeploy
/// @notice Forge deployment script for the ERC1155 marketplace implementation and ERC1967 proxy.
/// @dev Reads market config addresses from environment variables and initializes the proxy in the same broadcast.
contract RareERC1155ListingsDeploy is Script {
    /// @notice Deploys marketplace logic, deploys proxy, and initializes the proxied marketplace.
    function run() external {
        // Environment read: select deployer key for broadcast signing.
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Broadcast boundary: following operations are submitted as deployer transactions.
        vm.startBroadcast(privateKey);

        // Address derivation: default network beneficiary to deployer when no env override is provided.
        address addr = vm.addr(privateKey);

        // Environment reads: collect required marketplace dependency addresses.
        address networkBeneficiary = vm.envOr("NETWORK_BENEFICIARY", addr);
        address marketplaceSettings = vm.envAddress("SETTINGS_ADDRESS");
        address spaceOperatorRegistry = vm.envAddress("SPACE_OPERATOR_REGISTRY");
        address royaltyEngine = vm.envAddress("ROYALTY_ENGINE");
        address payments = vm.envAddress("PAYMENTS");
        address approvedTokenRegistry = vm.envAddress("TOKEN_REGISTRY");
        address stakingSettings = vm.envAddress("STAKING_SETTINGS");
        address stakingRegistry = vm.envAddress("STAKING_REGISTRY");
        address erc20ApprovalManager = vm.envAddress("ERC20_APPROVAL_MANAGER");
        address erc721ApprovalManager = vm.envAddress("ERC721_APPROVAL_MANAGER");
        address erc1155ApprovalManager = vm.envAddress("ERC1155_APPROVAL_MANAGER");

        // Deployment operation: deploy UUPS implementation logic.
        RareERC1155Listings marketplace = new RareERC1155Listings();

        // Deployment operation: deploy ERC1967 proxy pointing at the implementation.
        ERC1967Proxy marketplaceProxy = new ERC1967Proxy(address(marketplace), "");

        // Initialization transaction: configure proxied marketplace dependencies.
        RareERC1155Listings(address(marketplaceProxy))
            .initialize(
                networkBeneficiary,
                marketplaceSettings,
                spaceOperatorRegistry,
                royaltyEngine,
                payments,
                approvedTokenRegistry,
                stakingSettings,
                stakingRegistry,
                erc20ApprovalManager,
                erc721ApprovalManager,
                erc1155ApprovalManager
            );

        // Broadcast boundary: stop submitting transactions.
        vm.stopBroadcast();
    }
}
