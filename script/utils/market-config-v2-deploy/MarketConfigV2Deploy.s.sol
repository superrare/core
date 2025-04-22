// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import {MarketConfigV2} from "../../../src/v2/utils/MarketConfigV2.sol";

/// @title MarketConfigV2Deploy
/// @notice Deployment script for MarketConfigV2 library
contract MarketConfigV2Deploy is Script {
  function run() external {
    // 1. Load private key and start broadcast
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    // 2. Deploy library using deployCode
    address lib = deployCode("MarketConfigV2.sol");

    // 3. Log deployed addresses
    console.log("MarketConfigV2 library deployed at:", lib);
    console.log("Deployed by:", deployer);

    vm.stopBroadcast();
  }
}
