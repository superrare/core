// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";

import "../../../src/v2/auctionhouse/RareBatchAuctionHouse.sol";
import "../../../src/v2/approver/ERC721/ERC721ApprovalManager.sol";
import "../../../src/v2/approver/ERC20/ERC20ApprovalManager.sol";

/// @title SuperRareAuctionHouseV2Deploy
/// @notice Deployment script for RareBatchAuctionHouse and its dependencies
contract RareBatchAuctionHouseSeedSepolia is Script {
  function _createMerkleRoot(address[] memory contracts, uint256[] memory tokenIds) internal pure returns (bytes32) {
    require(contracts.length == tokenIds.length, "Length mismatch");
    bytes32[] memory leaves = new bytes32[](contracts.length);

    // Create leaves by hashing contract address and token ID pairs
    for (uint256 i = 0; i < contracts.length; i++) {
      leaves[i] = keccak256(abi.encodePacked(contracts[i], tokenIds[i]));
    }

    // For two leaves, we can directly hash them together to get the root
    // This is equivalent to creating a tree with these two leaves
    return keccak256(abi.encodePacked(leaves[0], leaves[1]));
  }

  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);
    // Ensure we're on Sepolia testnet
    uint256 sepoliaChainId = 11155111;
    require(block.chainid == sepoliaChainId, "This script must be run on Sepolia testnet");

    RareBatchAuctionHouse rareBatchAuctionHouse = RareBatchAuctionHouse(
      payable(vm.envAddress("RARE_BATCH_AUCTIONHOUSE"))
    );
    address erc721ApprovalManager = vm.envAddress("ERC721_APPROVAL_MANAGER");
    ERC721 erc721 = ERC721(vm.envAddress("ERC721_CONTRACT"));
    uint256 tokenId1 = vm.envUint("TOKEN_ID_1");
    uint256 tokenId2 = vm.envUint("TOKEN_ID_2");

    console.log("Approving ERC721Approval Manager for token contract", address(erc721));
    erc721.setApprovalForAll(address(erc721ApprovalManager), true);

    // Create arrays for Merkle root generation
    address[] memory contracts = new address[](2);
    contracts[0] = address(erc721);
    contracts[1] = address(erc721);

    uint256[] memory tokenIds = new uint256[](2);
    tokenIds[0] = tokenId1;
    tokenIds[1] = tokenId2;

    // Generate Merkle root
    bytes32 merkleRoot = _createMerkleRoot(contracts, tokenIds);
    console.log("Generated Merkle root:", vm.toString(merkleRoot));

    // Register the Merkle root with the auction house
    address payable[] memory splitAddresses = new address payable[](1);
    splitAddresses[0] = payable(deployer); // Set the deployer as the recipient
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100; // 100% to the deployer

    // Register the Merkle root for the auction
    rareBatchAuctionHouse.registerAuctionMerkleRoot(
      merkleRoot,
      address(0), // Using ETH as currency
      0.01 ether, // Starting amount of 1 ETH
      1 days, // 1 day auction duration
      splitAddresses,
      splitRatios
    );

    console.log("Merkle root registered with auction house");
    console.log("Contract address:", address(erc721));
    console.log("Token IDs:", tokenId1, tokenId2);

    vm.stopBroadcast();
  }
}
