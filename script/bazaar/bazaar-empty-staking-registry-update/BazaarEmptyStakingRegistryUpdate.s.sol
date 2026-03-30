// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";

import "../../../src/bazaar/SuperRareBazaar.sol";
import "../../../src/staking/registry/EmptyRareStakingRegistry.sol";

/// @title BazaarEmptyStakingRegistryUpdate
/// @notice Deploys an empty staking registry and updates Bazaar to use it.
contract BazaarEmptyStakingRegistryUpdate is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address bazaarAddress = vm.envAddress("BAZAAR_ADDRESS");

    vm.startBroadcast(privateKey);

    EmptyRareStakingRegistry stakingRegistry = new EmptyRareStakingRegistry();
    SuperRareBazaar bazaar = SuperRareBazaar(bazaarAddress);

    bazaar.setStakingRegistry(address(stakingRegistry));

    console.log("Bazaar:", bazaarAddress);
    console.log("EmptyRareStakingRegistry deployed at:", address(stakingRegistry));

    vm.stopBroadcast();
  }
}
