// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import "../../../../src/v2/marketplace/RareBatchListingMarketplace.sol";
import "../../../../src/v2/marketplace/IRareBatchListingMarketplace.sol";

/// @title ConfigureBatchListingScript
/// @notice Script to configure a batch listing on RareBatchListingMarketplace
contract ConfigureBatchListingScript is Script {
  function run() external {
    // 1. Load private key and start broadcast
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);

    // 2. Load environment variables
    address marketplaceAddress = vm.envAddress("MARKETPLACE_ADDRESS");
    bytes32 merkleRoot = vm.envBytes32("MERKLE_ROOT");
    
    // Currency: address(0) for ETH, or specific ERC20 address
    address currency = vm.envOr("CURRENCY", address(0));
    
    // Sale price amount (in wei for ETH, or smallest unit for ERC20)
    uint256 amount = vm.envUint("SALE_PRICE_AMOUNT");
    
    // Optional: NFT contract address for marketplace approval
    address nftContract = vm.envOr("NFT_CONTRACT", address(0));
    
    // Optional: ERC721ApprovalManager address (required if NFT_CONTRACT is set)
    address erc721ApprovalManager = vm.envOr("ERC721_APPROVAL_MANAGER", address(0));

    // 3. Get marketplace instance
    IRareBatchListingMarketplace marketplace = IRareBatchListingMarketplace(marketplaceAddress);

    // 4. Prepare split configuration (optional)
    // Use Foundry's built-in array parsing with comma delimiter
    address[] memory splitAddressesArray = vm.envOr("SPLIT_ADDRESSES", ",", new address[](0));
    uint256[] memory splitRatiosArray = vm.envOr("SPLIT_RATIOS", ",", new uint256[](0));
    
    require(
      splitAddressesArray.length == splitRatiosArray.length,
      "Split addresses and ratios length mismatch"
    );
    
    // Convert to payable addresses and uint8 ratios
    address payable[] memory splitAddresses = new address payable[](splitAddressesArray.length);
    uint8[] memory splitRatios = new uint8[](splitRatiosArray.length);
    
    for (uint256 i = 0; i < splitAddressesArray.length; i++) {
      splitAddresses[i] = payable(splitAddressesArray[i]);
      require(splitRatiosArray[i] <= type(uint8).max, "Split ratio exceeds uint8 max");
      splitRatios[i] = uint8(splitRatiosArray[i]);
    }

    // 5. Check if root is already registered and warn about nonce increment
    bytes32[] memory existingRoots = marketplace.getUserSalePriceMerkleRoots(msg.sender);
    bool rootExists = false;
    uint256 currentNonce = 0;
    for (uint256 i = 0; i < existingRoots.length; i++) {
      if (existingRoots[i] == merkleRoot) {
        rootExists = true;
        currentNonce = marketplace.getCreatorSalePriceMerkleRootNonce(msg.sender, merkleRoot);
        break;
      }
    }
    
    if (rootExists) {
      console.log("\nWARNING: This Merkle root is already registered!");
      console.log("Current nonce:", currentNonce);
      console.log("Re-registering will:");
      console.log("  - Increment nonce to", currentNonce + 1);
      console.log("  - Update currency, amount, and splits");
      console.log("  - Allow previously sold tokens to be sold again");
    }
    
    // Register the sale price Merkle root
    console.log("\nRegistering sale price Merkle root...");
    console.log("Marketplace:", marketplaceAddress);
    console.log("Merkle Root:", vm.toString(merkleRoot));
    console.log("Currency:", currency);
    console.log("Amount:", amount);
    
    marketplace.registerSalePriceMerkleRoot(
      merkleRoot,
      currency,
      amount,
      splitAddresses,
      splitRatios
    );
    
    uint256 newNonce = marketplace.getCreatorSalePriceMerkleRootNonce(msg.sender, merkleRoot);
    console.log("Sale price Merkle root registered successfully!");
    console.log("New nonce:", newNonce);

    // 6. Approve marketplace for NFT transfers (if NFT contract is provided)
    if (nftContract != address(0)) {
      if (erc721ApprovalManager == address(0)) {
        revert("ERC721_APPROVAL_MANAGER is required when NFT_CONTRACT is set");
      }
      
      console.log("\nApproving marketplace for NFT transfers...");
      console.log("NFT Contract:", nftContract);
      console.log("ERC721 Approval Manager:", erc721ApprovalManager);
      
      IERC721 nft = IERC721(nftContract);
      
      // Check current approval status
      bool alreadyApproved = nft.isApprovedForAll(msg.sender, erc721ApprovalManager);
      
      if (alreadyApproved) {
        console.log("Marketplace already approved for this NFT contract");
      } else {
        // Approve the ERC721ApprovalManager to transfer NFTs on behalf of the creator
        nft.setApprovalForAll(erc721ApprovalManager, true);
        console.log("Marketplace approval granted successfully!");
      }
    }

    // 7. Optionally configure allowlist
    bytes32 allowListRoot = vm.envOr("ALLOWLIST_ROOT", bytes32(0));
    if (allowListRoot != bytes32(0)) {
      uint256 allowListEndTimestamp = vm.envUint("ALLOWLIST_END_TIMESTAMP");
      
      console.log("Setting allowlist configuration...");
      console.log("Allowlist Root:", vm.toString(allowListRoot));
      console.log("End Timestamp:", allowListEndTimestamp);
      
      marketplace.setAllowListConfig(merkleRoot, allowListRoot, allowListEndTimestamp);
      
      console.log("Allowlist configuration set successfully!");
    }

    // 8. Display configuration
    IRareBatchListingMarketplace.MerkleSalePriceConfig memory config = 
      marketplace.getMerkleSalePriceConfig(msg.sender, merkleRoot);
    
    console.log("\n=== Configuration Summary ===");
    console.log("Creator:", msg.sender);
    console.log("Merkle Root:", vm.toString(merkleRoot));
    console.log("Currency:", config.currency);
    console.log("Amount:", config.amount);
    console.log("Nonce:", config.nonce);
    console.log("Split Recipients Count:", config.splitRecipients.length);
    
    if (allowListRoot != bytes32(0)) {
      IRareBatchListingMarketplace.AllowListConfig memory allowListConfig = 
        marketplace.getAllowListConfig(msg.sender, merkleRoot);
      console.log("Allowlist Root:", vm.toString(allowListConfig.root));
      console.log("Allowlist End Timestamp:", allowListConfig.endTimestamp);
    }

    vm.stopBroadcast();
  }
}
