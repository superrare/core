// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import {MarketUtilsV2} from "../../../src/v2/utils/MarketUtilsV2.sol";

/// @title MarketUtilsV2Deploy
/// @notice Deployment script for MarketUtilsV2 library
contract MarketUtilsV2Deploy is Script {
  function run() external {
    // 1. Load private key and start broadcast
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    // 2. Deploy library using deployCode
    address lib = deployCode("MarketUtilsV2.sol");

    // 3. Log deployed addresses
    console.log("MarketUtilsV2 library deployed at:", lib);
    console.log("Deployed by:", deployer);

    vm.stopBroadcast();
  }
}
