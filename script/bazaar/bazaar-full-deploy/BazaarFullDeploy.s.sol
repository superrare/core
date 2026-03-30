// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Core Bazaar Contracts
import "../../../src/bazaar/SuperRareBazaar.sol";
import "../../../src/marketplace/SuperRareMarketplace.sol";
import "../../../src/auctionhouse/SuperRareAuctionHouse.sol";

// Marketplace Settings (V1, V2, V3 chain)
import "../../../src/marketplace/MarketplaceSettingsV1.sol";
import "../../../src/marketplace/MarketplaceSettingsV2.sol";
import "../../../src/marketplace/MarketplaceSettingsV3.sol";
import "../../../src/bazaar/BaseSepoliaZeroRoyaltyEngine.sol";
import "../../../src/staking/registry/EmptyRareStakingRegistry.sol";

// Registry Contracts
import "../../../src/registry/SpaceOperatorRegistry.sol";
import "../../../src/registry/ApprovedTokenRegistry.sol";

// Payment Contract
import "../../../src/payments/Payments.sol";

/// @title BazaarFullDeploy
/// @notice Deployment script for SuperRareBazaar and all its dependencies for a new blockchain
contract BazaarFullDeploy is Script {
  uint256 internal constant BASE_CHAIN_ID = 8453;
  uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
  address internal constant BASE_ROYALTY_ENGINE = 0xEF770dFb6D5620977213f55f99bfd781D04BBE15;

  function run() external {
    // 1. Load private key and start broadcast
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    // 2. Load environment variables
    address networkBeneficiary = vm.envAddress("NETWORK_BENEFICIARY");
    address royaltyRegistry = vm.envAddress("ROYALTY_REGISTRY");
    address stakingRegistry;
    address royaltyEngine = vm.envOr("ROYALTY_ENGINE", address(0));
    uint256 chainId = block.chainid;

    console.log("=== Starting Bazaar Full Deployment ===");
    console.log("Deployer:", deployer);
    console.log("Network Beneficiary:", networkBeneficiary);
    console.log("Royalty Registry (env):", royaltyRegistry);
    console.log("Chain ID:", chainId);

    // 3. Resolve Royalty Engine
    if (royaltyEngine == address(0)) {
      if (chainId == BASE_CHAIN_ID) {
        royaltyEngine = BASE_ROYALTY_ENGINE;
        console.log("Using fixed Base royalty engine:", royaltyEngine);
      } else if (chainId == BASE_SEPOLIA_CHAIN_ID) {
        royaltyEngine = address(new BaseSepoliaZeroRoyaltyEngine());
        console.log("Deployed Base Sepolia zero-royalty engine:", royaltyEngine);
      } else {
        revert("Unsupported chain without ROYALTY_ENGINE override");
      }
    } else {
      console.log("Using env-provided royalty engine:", royaltyEngine);
    }

    // 4. Deploy Registry Dependencies
    console.log("\n=== Deploying Registry Contracts ===");
    console.log("Using existing RoyaltyRegistry:", royaltyRegistry);

    EmptyRareStakingRegistry emptyStakingRegistry = new EmptyRareStakingRegistry();
    stakingRegistry = address(emptyStakingRegistry);
    console.log("EmptyRareStakingRegistry deployed at:", stakingRegistry);

    // Deploy Space Operator Registry (upgradeable)
    SpaceOperatorRegistry spaceOperatorRegistryImpl = new SpaceOperatorRegistry();
    ERC1967Proxy spaceOperatorRegistryProxy = new ERC1967Proxy(address(spaceOperatorRegistryImpl), "");
    SpaceOperatorRegistry spaceOperatorRegistry = SpaceOperatorRegistry(address(spaceOperatorRegistryProxy));
    spaceOperatorRegistry.initialize();
    console.log("SpaceOperatorRegistry implementation deployed at:", address(spaceOperatorRegistryImpl));
    console.log("SpaceOperatorRegistry proxy deployed at:", address(spaceOperatorRegistry));

    // Deploy Approved Token Registry
    ApprovedTokenRegistry approvedTokenRegistry = new ApprovedTokenRegistry();
    console.log("ApprovedTokenRegistry deployed at:", address(approvedTokenRegistry));

    // 5. Deploy Payment Contract
    console.log("\n=== Deploying Payment Contract ===");
    Payments payments = new Payments();
    console.log("Payments deployed at:", address(payments));

    // 6. Deploy Marketplace Settings Chain (V1 -> V2 -> V3)
    console.log("\n=== Deploying Marketplace Settings Chain ===");

    MarketplaceSettingsV1 marketplaceSettingsV1 = new MarketplaceSettingsV1();
    console.log("MarketplaceSettingsV1 deployed at:", address(marketplaceSettingsV1));

    MarketplaceSettingsV2 marketplaceSettingsV2 = new MarketplaceSettingsV2(deployer, address(marketplaceSettingsV1));
    console.log("MarketplaceSettingsV2 deployed at:", address(marketplaceSettingsV2));

    MarketplaceSettingsV3 marketplaceSettingsV3 = new MarketplaceSettingsV3(deployer, address(marketplaceSettingsV2));
    console.log("MarketplaceSettingsV3 deployed at:", address(marketplaceSettingsV3));

    // 7. Deploy Core Bazaar Logic Contracts
    console.log("\n=== Deploying Bazaar Logic Contracts ===");

    SuperRareMarketplace superRareMarketplace = new SuperRareMarketplace();
    console.log("SuperRareMarketplace deployed at:", address(superRareMarketplace));

    SuperRareAuctionHouse superRareAuctionHouse = new SuperRareAuctionHouse();
    console.log("SuperRareAuctionHouse deployed at:", address(superRareAuctionHouse));

    // 8. Deploy and Initialize Bazaar
    console.log("\n=== Deploying Bazaar Main Contract ===");

    SuperRareBazaar bazaar = new SuperRareBazaar();
    console.log("SuperRareBazaar deployed at:", address(bazaar));

    // Initialize the Bazaar
    bazaar.initialize(
      address(marketplaceSettingsV3),
      royaltyRegistry,
      royaltyEngine,
      address(superRareMarketplace),
      address(superRareAuctionHouse),
      address(spaceOperatorRegistry),
      address(approvedTokenRegistry),
      address(payments),
      stakingRegistry,
      networkBeneficiary
    );
    console.log("SuperRareBazaar initialized successfully");

    // 9. Perform post-deployment configuration
    console.log("\n=== Post-Deployment Configuration ===");

    // Grant marketplace access to the bazaar
    marketplaceSettingsV3.grantMarketplaceAccess(address(bazaar));
    console.log("Granted marketplace access to bazaar");

    // Set primary sale fee percentage (default to 0% if not specified)
    uint8 primarySaleFeePercentage = uint8(vm.envOr("PRIMARY_SALE_FEE_PERCENTAGE", uint256(0)));
    marketplaceSettingsV3.setPrimarySaleFeePercentage(primarySaleFeePercentage);
    console.log("Set primary sale fee percentage to:", primarySaleFeePercentage);

    // Set staking fee percentage (default to 1% if not specified)
    uint8 stakingFeePercentage = 1;
    try vm.envUint("STAKING_FEE_PERCENTAGE") returns (uint256 fee) {
      stakingFeePercentage = uint8(fee);
    } catch {
      // Use default value
    }
    marketplaceSettingsV3.setStakingFeePercentage(stakingFeePercentage);
    console.log("Set staking fee percentage to:", stakingFeePercentage);

    // 10. Log all deployed addresses for easy reference
    console.log("\n=== DEPLOYMENT SUMMARY ===");
    console.log("RoyaltyRegistry:", royaltyRegistry);
    console.log("RoyaltyEngine:", royaltyEngine);
    console.log("StakingRegistry:", stakingRegistry);
    console.log("SpaceOperatorRegistry (proxy):", address(spaceOperatorRegistry));
    console.log("ApprovedTokenRegistry:", address(approvedTokenRegistry));
    console.log("Payments:", address(payments));
    console.log("MarketplaceSettingsV1:", address(marketplaceSettingsV1));
    console.log("MarketplaceSettingsV2:", address(marketplaceSettingsV2));
    console.log("MarketplaceSettingsV3:", address(marketplaceSettingsV3));
    console.log("SuperRareMarketplace:", address(superRareMarketplace));
    console.log("SuperRareAuctionHouse:", address(superRareAuctionHouse));
    console.log("SuperRareBazaar:", address(bazaar));

    console.log("\n=== MAIN CONTRACT ADDRESSES ===");
    console.log("BAZAAR_ADDRESS=", address(bazaar));
    console.log("MARKETPLACE_SETTINGS=", address(marketplaceSettingsV3));
    console.log("ROYALTY_REGISTRY=", royaltyRegistry);
    console.log("ROYALTY_ENGINE=", royaltyEngine);
    console.log("STAKING_REGISTRY=", stakingRegistry);
    console.log("SPACE_OPERATOR_REGISTRY=", address(spaceOperatorRegistry));
    console.log("APPROVED_TOKEN_REGISTRY=", address(approvedTokenRegistry));
    console.log("PAYMENTS=", address(payments));

    vm.stopBroadcast();

    console.log("\n=== Deployment Complete! ===");
  }
}
