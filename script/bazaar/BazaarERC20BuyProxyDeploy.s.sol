// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../../src/bazaar/SuperRareBazaarERC20BuyProxy.sol";

/// @title BazaarERC20BuyProxyDeploy
/// @notice Deployment script for the Bazaar ERC20 purchase proxy
contract BazaarERC20BuyProxyDeploy is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    address bazaarAddress = vm.envAddress("BAZAAR_ADDRESS");

    SuperRareBazaarERC20BuyProxy proxy = new SuperRareBazaarERC20BuyProxy(bazaarAddress);

    console.log("Deployer:", deployer);
    console.log("Bazaar:", bazaarAddress);
    console.log("BazaarERC20BuyProxy deployed at:", address(proxy));

    vm.stopBroadcast();
  }
}
