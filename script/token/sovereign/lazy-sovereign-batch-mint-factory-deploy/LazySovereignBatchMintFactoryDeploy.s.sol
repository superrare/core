// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../../../../src/v2/token/ERC721/sovereign/LazySovereignBatchMintFactory.sol";
import "../../../../src/v2/token/ERC721/sovereign/LazySovereignBatchMint.sol";

/// @title LazySovereignBatchMintFactoryDeploy
/// @notice Deployment script for LazySovereignBatchMintFactory contract
contract LazySovereignBatchMintFactoryDeploy is Script {
  function run() external {
    // 1. Load private key and start broadcast
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    // 2. Load environment variables
    address factoryOwner = vm.envOr("FACTORY_OWNER", deployer);
    address lazySovereignBatchMintImplementation = vm.envOr("LAZY_SOVEREIGN_BATCH_MINT_IMPLEMENTATION", address(0));

    // 3. Deploy LazySovereignBatchMint implementation if not provided
    if (lazySovereignBatchMintImplementation == address(0)) {
      LazySovereignBatchMint implementation = new LazySovereignBatchMint();
      lazySovereignBatchMintImplementation = address(implementation);
      console.log("LazySovereignBatchMint implementation deployed at:", lazySovereignBatchMintImplementation);
    } else {
      console.log("Using existing LazySovereignBatchMint implementation at:", lazySovereignBatchMintImplementation);
    }

    // 4. Deploy LazySovereignBatchMintFactory with the implementation address
    LazySovereignBatchMintFactory factory = new LazySovereignBatchMintFactory(lazySovereignBatchMintImplementation);

    // 5. Transfer ownership if a different owner was specified
    if (factoryOwner != deployer) {
      factory.transferOwnership(factoryOwner);
    }

    // 6. Log deployed addresses
    console.log("LazySovereignBatchMintFactory deployed at:", address(factory));
    console.log("LazySovereignBatchMint implementation at:", factory.lazySovereignNFT());
    console.log("Factory owner:", factory.owner());
    console.log("Deployer:", deployer);

    vm.stopBroadcast();
  }
}
