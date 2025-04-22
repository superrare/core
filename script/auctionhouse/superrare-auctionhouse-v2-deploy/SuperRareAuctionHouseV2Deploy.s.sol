// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/v2/auctionhouse/SuperRareAuctionHouseV2.sol";
import "../../../src/v2/approver/ERC721/ERC721ApprovalManager.sol";
import "../../../src/v2/approver/ERC20/ERC20ApprovalManager.sol";

/// @title SuperRareAuctionHouseV2Deploy
/// @notice Deployment script for SuperRareAuctionHouseV2 and its dependencies
contract SuperRareAuctionHouseV2Deploy is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    // Get Market Config Values from .env
    address networkBeneficiary = vm.envAddress("NETWORK_BENEFICIARY");
    address marketplaceSettings = vm.envAddress("MARKETPLACE_SETTINGS");
    address spaceOperatorRegistry = vm.envAddress("SPACE_OPERATOR_REGISTRY");
    address royaltyEngine = vm.envAddress("ROYALTY_ENGINE");
    address payments = vm.envAddress("PAYMENTS");
    address approvedTokenRegistry = vm.envAddress("APPROVED_TOKEN_REGISTRY");
    address stakingSettings = vm.envAddress("STAKING_SETTINGS");
    address stakingRegistry = vm.envAddress("STAKING_REGISTRY");
    address erc721ApprovalManager = vm.envAddress("ERC721_APPROVAL_MANAGER");
    address erc20ApprovalManager = vm.envAddress("ERC20_APPROVAL_MANAGER");

    // Deploy implementation
    SuperRareAuctionHouseV2 auctionHouseImplementation = new SuperRareAuctionHouseV2();

    // Deploy proxy
    ERC1967Proxy auctionHouseProxy = new ERC1967Proxy(address(auctionHouseImplementation), "");

    // Initialize the proxy
    SuperRareAuctionHouseV2(payable(address(auctionHouseProxy))).initialize(
      marketplaceSettings,
      royaltyEngine,
      spaceOperatorRegistry,
      approvedTokenRegistry,
      payments,
      stakingRegistry,
      stakingSettings,
      networkBeneficiary,
      erc20ApprovalManager,
      erc721ApprovalManager
    );

    // Grant operator role to the auction house proxy for both approval managers
    ERC721ApprovalManager(erc721ApprovalManager).grantOperatorRole(address(auctionHouseProxy));
    ERC20ApprovalManager(erc20ApprovalManager).grantOperatorRole(address(auctionHouseProxy));

    // Log deployed addresses
    console.log("ERC721ApprovalManager deployed at:", address(erc721ApprovalManager));
    console.log("ERC20ApprovalManager deployed at:", address(erc20ApprovalManager));
    console.log("SuperRareAuctionHouseV2 implementation deployed at:", address(auctionHouseImplementation));
    console.log("SuperRareAuctionHouseV2 proxy deployed at:", address(auctionHouseProxy));

    vm.stopBroadcast();
  }
}
