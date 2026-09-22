// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "src/memberships/CreatorMemberships.sol";

/// @title CreatorMemberships deployment
/// @notice Deploys the same non-upgradeable billing contract on Sepolia or mainnet.
contract CreatorMembershipsDeploy is Script {
  function run() external returns (CreatorMemberships deployed) {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address token = vm.envAddress("MEMBERSHIPS_USDC_TOKEN");
    address treasury = vm.envAddress("MEMBERSHIPS_TREASURY");
    address operator = vm.envAddress("MEMBERSHIPS_OPERATOR");
    address owner = vm.envAddress("MEMBERSHIPS_OWNER");
    require(block.chainid == vm.envUint("CHAIN_ID"), "Unexpected chain");
    require(block.chainid == 1 || block.chainid == 11155111, "Unsupported chain");
    require(
      token ==
        (block.chainid == 1 ? 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 : 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238),
      "Native USDC required"
    );
    vm.startBroadcast(privateKey);
    deployed = new CreatorMemberships(token, treasury, operator, owner);
    vm.stopBroadcast();
  }
}
