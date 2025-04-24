// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../../../src/token/ERC721/superrare/SuperRareV2.sol";

contract SuperRareV2Deploy is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.addr(privateKey);

    vm.startBroadcast(privateKey);

    // Create contract
    new SuperRareV2("SuperRareV2", "SUPR");

    vm.stopBroadcast();
  }
}
