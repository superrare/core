// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../../../../src/v2/token/ERC721/sovereign/SovereignBatchMintFactory.sol";
import "../../../../src/v2/token/ERC721/sovereign/SovereignBatchMint.sol";

/// @title SovereignBatchMintFactoryDeploy
/// @notice Deployment script for SovereignBatchMintFactory contract
contract SovereignBatchMintFactoryDeploy is Script {
  function run() external {
    // 1. Load private key and start broadcast
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    // 2. Load environment variables
    address factoryOwner = vm.envOr("FACTORY_OWNER", deployer);
    address sovereignBatchMintImplementation = vm.envOr("SOVEREIGN_BATCH_MINT_IMPLEMENTATION", address(0));

    // 3. Deploy SovereignBatchMint implementation if not provided
    if (sovereignBatchMintImplementation == address(0)) {
      SovereignBatchMint implementation = new SovereignBatchMint();
      sovereignBatchMintImplementation = address(implementation);
      console.log("SovereignBatchMint implementation deployed at:", sovereignBatchMintImplementation);
    } else {
      console.log("Using existing SovereignBatchMint implementation at:", sovereignBatchMintImplementation);
    }

    // 4. Deploy SovereignBatchMintFactory with the implementation address
    SovereignBatchMintFactory factory = new SovereignBatchMintFactory(sovereignBatchMintImplementation);

    // 5. Transfer ownership if a different owner was specified
    if (factoryOwner != deployer) {
      factory.transferOwnership(factoryOwner);
    }

    // 6. Log deployed addresses
    console.log("SovereignBatchMintFactory deployed at:", address(factory));
    console.log("SovereignBatchMint implementation at:", factory.sovereignNFT());
    console.log("Factory owner:", factory.owner());
    console.log("Deployer:", deployer);

    vm.stopBroadcast();
  }
}
