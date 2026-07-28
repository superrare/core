// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/utils/SuperRareAdmin.sol";
import "../src/marketplace/MarketplaceSettingsV1.sol";
import "../src/marketplace/MarketplaceSettingsV2.sol";
import "../src/marketplace/MarketplaceSettingsV3.sol";
import "../src/registry/RareAppRegistry.sol";
import "../src/registry/CreatorRegistry.sol";
import "../src/registry/RoyaltyRegistry.sol";
import "../src/registry/SpaceOperatorRegistry.sol";
import "../src/registry/ApprovedTokenRegistry.sol";
import "../src/payments/Payments.sol";
import "../src/token/ERC721/superrare/SuperRareV2.sol";
import "../src/token/ERC721/sovereign/SovereignNFTContractFactory.sol";
import "../src/collection/RareMinter.sol";
import "../src/marketplace/SuperRareMarketplace.sol";
import "../src/auctionhouse/SuperRareAuctionHouse.sol";
import "../src/bazaar/SuperRareBazaar.sol";
import "../src/staking/registry/StakingRegistryStub.sol";

import {FallbackRegistry} from "royalty-registry/FallbackRegistry.sol";
import {ManifoldRoyaltyRegistryStub} from "../src/registry/ManifoldRoyaltyRegistryStub.sol";
import {RoyaltyEngineV1} from "royalty-registry/RoyaltyEngineV1.sol";

/// @title DeploySepolia
/// @notice Deployment script for the full Rare Protocol stack on Sepolia testnet.
contract DeploySepolia is Script {
  function run() external {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);
    address rareToken = vm.envAddress("RARE_ADDRESS");

    vm.startBroadcast(deployerPrivateKey);

    // 1. SuperRareV2 (for SuperRareAdmin)
    SuperRareV2 superRareV2 = new SuperRareV2("SuperRareV2", "SUPR");

    // 2. SuperRareAdmin
    SuperRareAdmin admin = new SuperRareAdmin(address(superRareV2));

    // 3. MarketplaceSettings V1 -> V2 -> V3
    MarketplaceSettingsV1 settingsV1 = new MarketplaceSettingsV1();
    MarketplaceSettingsV2 settingsV2 = new MarketplaceSettingsV2(deployer, address(settingsV1));
    MarketplaceSettingsV3 settingsV3 = new MarketplaceSettingsV3(deployer, address(settingsV2));

    // 4. RareAppRegistry
    RareAppRegistry appRegistry = new RareAppRegistry(deployer);

    // 5. SovereignNFTContractFactory (deploy first for CreatorRegistry)
    SovereignNFTContractFactory sovFactory = new SovereignNFTContractFactory();

    // 6. CreatorRegistry, Rare RoyaltyRegistry
    address[] memory creatorImplementations = new address[](1);
    creatorImplementations[0] = sovFactory.sovereignNFT();
    CreatorRegistry creatorRegistry = new CreatorRegistry(creatorImplementations);
    RoyaltyRegistry rareRoyaltyRegistry = new RoyaltyRegistry(address(creatorRegistry));

    // 7. Royalty stack (Manifold)
    FallbackRegistry fallbackRegistry = new FallbackRegistry(deployer);
    ManifoldRoyaltyRegistryStub manifoldRoyaltyRegistry = new ManifoldRoyaltyRegistryStub();
    RoyaltyEngineV1 royaltyEngine = new RoyaltyEngineV1(address(fallbackRegistry));
    royaltyEngine.initialize(deployer, address(manifoldRoyaltyRegistry));

    // 8. StakingRegistryStub
    StakingRegistryStub stakingStub = new StakingRegistryStub();

    // 9. Payments, ApprovedTokenRegistry, SpaceOperatorRegistry
    Payments payments = new Payments();
    ApprovedTokenRegistry approvedTokenRegistry = new ApprovedTokenRegistry();
    SpaceOperatorRegistry spaceOperatorRegistry = new SpaceOperatorRegistry();
    spaceOperatorRegistry.initialize();

    // 10. RareMinter (impl + proxy)
    RareMinter rareMinterImpl = new RareMinter();
    ERC1967Proxy rareMinterProxy = new ERC1967Proxy(
      address(rareMinterImpl),
      abi.encodeWithSelector(
        RareMinter.initialize.selector,
        deployer,
        address(settingsV3),
        address(spaceOperatorRegistry),
        address(royaltyEngine),
        address(payments),
        address(approvedTokenRegistry),
        address(settingsV3),
        address(stakingStub)
      )
    );
    RareMinter rareMinter = RareMinter(payable(address(rareMinterProxy)));

    // 11. SuperRareMarketplace, SuperRareAuctionHouse, SuperRareBazaar
    SuperRareMarketplace bazaarMarketplace = new SuperRareMarketplace();
    SuperRareAuctionHouse bazaarAuctionHouse = new SuperRareAuctionHouse();
    SuperRareBazaar bazaarImpl = new SuperRareBazaar();

    ERC1967Proxy bazaarProxy = new ERC1967Proxy(
      address(bazaarImpl),
      abi.encodeWithSelector(
        SuperRareBazaar.initialize.selector,
        address(settingsV3),
        address(rareRoyaltyRegistry),
        address(royaltyEngine),
        address(bazaarMarketplace),
        address(bazaarAuctionHouse),
        address(spaceOperatorRegistry),
        address(approvedTokenRegistry),
        address(payments),
        address(stakingStub),
        deployer
      )
    );
    SuperRareBazaar bazaar = SuperRareBazaar(payable(address(bazaarProxy)));

    // 12. Wire: setAppRegistry, grantMarketplaceAccess, addApprovedToken(RARE)
    bazaar.setAppRegistry(address(appRegistry));
    settingsV3.grantMarketplaceAccess(address(bazaar));
    approvedTokenRegistry.addApprovedToken(rareToken);

    vm.stopBroadcast();

    // 13. Write deployment addresses to JSON
    string memory root = "sepolia";
    string memory json = vm.serializeUint(root, "chainId", 11155111);
    json = vm.serializeAddress(root, "rareToken", rareToken);
    json = vm.serializeAddress(root, "superRareAdmin", address(admin));
    json = vm.serializeAddress(root, "marketplaceSettingsV3", address(settingsV3));
    json = vm.serializeAddress(root, "rareAppRegistry", address(appRegistry));
    json = vm.serializeAddress(root, "creatorRegistry", address(creatorRegistry));
    json = vm.serializeAddress(root, "rareRoyaltyRegistry", address(rareRoyaltyRegistry));
    json = vm.serializeAddress(root, "royaltyEngineV1", address(royaltyEngine));
    json = vm.serializeAddress(root, "stakingRegistryStub", address(stakingStub));
    json = vm.serializeAddress(root, "sovereignNFTContractFactory", address(sovFactory));
    json = vm.serializeAddress(root, "rareMinter", address(rareMinterProxy));
    json = vm.serializeAddress(root, "rareMinterImpl", address(rareMinterImpl));
    json = vm.serializeAddress(root, "payments", address(payments));
    json = vm.serializeAddress(root, "approvedTokenRegistry", address(approvedTokenRegistry));
    json = vm.serializeAddress(root, "spaceOperatorRegistry", address(spaceOperatorRegistry));
    json = vm.serializeAddress(root, "superRareMarketplace", address(bazaarMarketplace));
    json = vm.serializeAddress(root, "superRareAuctionHouse", address(bazaarAuctionHouse));
    json = vm.serializeAddress(root, "superRareBazaar", address(bazaarProxy));
    json = vm.serializeAddress(root, "superRareBazaarImpl", address(bazaarImpl));
    json = vm.serializeAddress(root, "deployer", deployer);
    vm.writeJson(json, "deployments/sepolia.json");

    // Log all addresses
    console.log("=== Deployed Addresses ===");
    console.log("RARE Token:", rareToken);
    console.log("SuperRareAdmin:", address(admin));
    console.log("MarketplaceSettingsV3:", address(settingsV3));
    console.log("RareAppRegistry:", address(appRegistry));
    console.log("CreatorRegistry:", address(creatorRegistry));
    console.log("Rare RoyaltyRegistry:", address(rareRoyaltyRegistry));
    console.log("RoyaltyEngineV1:", address(royaltyEngine));
    console.log("StakingRegistryStub:", address(stakingStub));
    console.log("SovereignNFTContractFactory:", address(sovFactory));
    console.log("RareMinter:", address(rareMinterProxy));
    console.log("RareMinter impl:", address(rareMinterImpl));
    console.log("Payments:", address(payments));
    console.log("ApprovedTokenRegistry:", address(approvedTokenRegistry));
    console.log("SpaceOperatorRegistry:", address(spaceOperatorRegistry));
    console.log("SuperRareMarketplace:", address(bazaarMarketplace));
    console.log("SuperRareAuctionHouse:", address(bazaarAuctionHouse));
    console.log("SuperRareBazaar:", address(bazaarProxy));
    console.log("SuperRareBazaar impl:", address(bazaarImpl));
    console.log("Deployer:", deployer);
    console.log("");
    console.log("Addresses written to deployments/sepolia.json");
  }
}
