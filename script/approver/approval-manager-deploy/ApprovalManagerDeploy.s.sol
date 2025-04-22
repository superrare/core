// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import {ERC20ApprovalManager} from "../../../src/v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../../src/v2/approver/ERC721/ERC721ApprovalManager.sol";

/// @title ApprovalManagerDeploy
/// @notice Deployment script for ERC20ApprovalManager and ERC721ApprovalManager
contract ApprovalManagerDeploy is Script {
  function run() external {
    // 1. Load private key and start broadcast
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    // 2. Deploy ERC20 Approval Manager
    ERC20ApprovalManager erc20ApprovalManager = new ERC20ApprovalManager();

    // 3. Deploy ERC721 Approval Manager
    ERC721ApprovalManager erc721ApprovalManager = new ERC721ApprovalManager();

    // 4. Log deployed addresses
    console.log("ERC20ApprovalManager deployed at:", address(erc20ApprovalManager));
    console.log("ERC721ApprovalManager deployed at:", address(erc721ApprovalManager));

    vm.stopBroadcast();
  }
}
