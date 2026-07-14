// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../../../../src/v2/token/ERC721/sovereign/LazySovereignBatchMintFactory.sol";
import "../../../../src/v2/token/ERC721/sovereign/LazySovereignBatchMint.sol";

/// @title PrepareMintScript
/// @notice Script to create a new LazySovereignBatchMint contract and prepare minting
contract PrepareMintScript is Script {
  function run() external {
    // 1. Load private key and start broadcast
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);

    // 2. Load environment variables
    address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
    string memory nftName = vm.envOr("NFT_NAME", string("My Lazy NFT"));
    string memory nftSymbol = vm.envOr("NFT_SYMBOL", string("LAZY"));
    uint256 maxTokens = vm.envOr("MAX_TOKENS", uint256(10000));
    
    // 3. Prepare mint parameters
    string memory baseURI = vm.envOr("BASE_URI", string("https://example.com/metadata/"));
    uint256 numberOfTokens = vm.envUint("NUMBER_OF_TOKENS");

    // 4. Get factory instance
    LazySovereignBatchMintFactory factory = LazySovereignBatchMintFactory(factoryAddress);

    // 5. Create new NFT contract via factory
    address nftAddress = factory.createLazySovereignBatchMint(nftName, nftSymbol, maxTokens);
    console.log("Created LazySovereignBatchMint contract at:", nftAddress);

    // 6. Get NFT contract instance
    LazySovereignBatchMint nft = LazySovereignBatchMint(nftAddress);

    // 7. Call prepareMint (must be called by the owner, which is the deployer)
    nft.prepareMint(baseURI, numberOfTokens);
    console.log("Prepared mint for", numberOfTokens, "tokens");
    console.log("Base URI:", baseURI);
    console.log("NFT contract owner:", nft.owner());
    console.log("Total batches:", nft.getBatchCount());

    vm.stopBroadcast();
  }
}
