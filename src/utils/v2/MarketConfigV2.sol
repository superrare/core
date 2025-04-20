// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IApprovedTokenRegistry} from "rareprotocol/aux/registry/interfaces/IApprovedTokenRegistry.sol";
import {IStakingSettings} from "rareprotocol/aux/marketplace/IStakingSettings.sol";
import {IMarketplaceSettings} from "rareprotocol/aux/marketplace/IMarketplaceSettings.sol";
import {ISpaceOperatorRegistry} from "rareprotocol/aux/registry/interfaces/ISpaceOperatorRegistry.sol";
import {IPayments} from "rareprotocol/aux/payments/IPayments.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";
import {IERC20ApprovalManager} from "../../approver/ERC20/IERC20ApprovalManager.sol";
import {IERC721ApprovalManager} from "../../approver/ERC721/IERC721ApprovalManager.sol";

import {IRareStakingRegistry} from "../../staking/registry/IRareStakingRegistry.sol";

library MarketConfigV2 {
  struct Config {
    // Existing fields from V1
    address networkBeneficiary;
    IMarketplaceSettings marketplaceSettings;
    ISpaceOperatorRegistry spaceOperatorRegistry;
    IRoyaltyEngineV1 royaltyEngine;
    IPayments payments;
    IApprovedTokenRegistry approvedTokenRegistry;
    IStakingSettings stakingSettings;
    IRareStakingRegistry stakingRegistry;
    // New V2 fields
    IERC20ApprovalManager erc20ApprovalManager;
    IERC721ApprovalManager erc721ApprovalManager;
  }

  // Events from V1
  event NetworkBeneficiaryUpdated(address indexed newNetworkBeneficiary);
  event MarketplaceSettingsUpdated(address indexed newMarketplaceSettings);
  event SpaceOperatorRegistryUpdated(address indexed newSpaceOperatorRegistry);
  event RoyaltyEngineUpdated(address indexed newRoyaltyEngine);
  event PaymentsUpdated(address indexed newPayments);
  event ApprovedTokenRegistryUpdated(address indexed newApprovedTokenRegistry);
  event StakingSettingsUpdated(address indexed newStakingSettings);
  event StakingRegistryUpdated(address indexed newStakingRegistry);

  // New V2 events
  event ERC20ApprovalManagerUpdated(address indexed newERC20ApprovalManager);
  event ERC721ApprovalManagerUpdated(address indexed newERC721ApprovalManager);

  function generateMarketConfig(
    address _networkBeneficiary,
    address _marketplaceSettings,
    address _spaceOperatorRegistry,
    address _royaltyEngine,
    address _payments,
    address _approvedTokenRegistry,
    address _stakingSettings,
    address _stakingRegistry,
    address _erc20ApprovalManager,
    address _erc721ApprovalManager
  ) public pure returns (Config memory) {
    require(_networkBeneficiary != address(0), "generateMarketConfig::Network beneficiary address cannot be zero");
    require(_marketplaceSettings != address(0), "generateMarketConfig::Marketplace settings address cannot be zero");
    require(
      _spaceOperatorRegistry != address(0),
      "generateMarketConfig::Space operator registry address cannot be zero"
    );
    require(_royaltyEngine != address(0), "generateMarketConfig::Royalty engine address cannot be zero");
    require(_payments != address(0), "generateMarketConfig::Payments address cannot be zero");
    require(
      _approvedTokenRegistry != address(0),
      "generateMarketConfig::Approved token registry address cannot be zero"
    );
    require(_stakingSettings != address(0), "generateMarketConfig::Staking settings address cannot be zero");
    require(_stakingRegistry != address(0), "generateMarketConfig::Staking registry address cannot be zero");
    require(_erc20ApprovalManager != address(0), "generateMarketConfig::ERC20 approval manager address cannot be zero");
    require(
      _erc721ApprovalManager != address(0),
      "generateMarketConfig::ERC721 approval manager address cannot be zero"
    );

    return
      MarketConfigV2.Config(
        _networkBeneficiary,
        IMarketplaceSettings(_marketplaceSettings),
        ISpaceOperatorRegistry(_spaceOperatorRegistry),
        IRoyaltyEngineV1(_royaltyEngine),
        IPayments(_payments),
        IApprovedTokenRegistry(_approvedTokenRegistry),
        IStakingSettings(_stakingSettings),
        IRareStakingRegistry(_stakingRegistry),
        IERC20ApprovalManager(_erc20ApprovalManager),
        IERC721ApprovalManager(_erc721ApprovalManager)
      );
  }

  // Existing V1 update functions
  function updateNetworkBeneficiary(Config storage _config, address _networkBeneficiary) public {
    _config.networkBeneficiary = _networkBeneficiary;
    emit NetworkBeneficiaryUpdated(_networkBeneficiary);
  }

  function updateMarketplaceSettings(Config storage _config, address _marketplaceSettings) public {
    _config.marketplaceSettings = IMarketplaceSettings(_marketplaceSettings);
    emit MarketplaceSettingsUpdated(_marketplaceSettings);
  }

  function updateSpaceOperatorRegistry(Config storage _config, address _spaceOperatorRegistry) public {
    _config.spaceOperatorRegistry = ISpaceOperatorRegistry(_spaceOperatorRegistry);
    emit SpaceOperatorRegistryUpdated(_spaceOperatorRegistry);
  }

  function updateRoyaltyEngine(Config storage _config, address _royaltyEngine) public {
    _config.royaltyEngine = IRoyaltyEngineV1(_royaltyEngine);
    emit RoyaltyEngineUpdated(_royaltyEngine);
  }

  function updatePayments(Config storage _config, address _payments) public {
    _config.payments = IPayments(_payments);
    emit PaymentsUpdated(_payments);
  }

  function updateApprovedTokenRegistry(Config storage _config, address _approvedTokenRegistry) public {
    _config.approvedTokenRegistry = IApprovedTokenRegistry(_approvedTokenRegistry);
    emit ApprovedTokenRegistryUpdated(_approvedTokenRegistry);
  }

  function updateStakingSettings(Config storage _config, address _stakingSettings) public {
    _config.stakingSettings = IStakingSettings(_stakingSettings);
    emit StakingSettingsUpdated(_stakingSettings);
  }

  function updateStakingRegistry(Config storage _config, address _stakingRegistry) public {
    _config.stakingRegistry = IRareStakingRegistry(_stakingRegistry);
    emit StakingRegistryUpdated(_stakingRegistry);
  }

  // New V2 update functions
  function updateERC20ApprovalManager(Config storage _config, address _erc20ApprovalManager) public {
    _config.erc20ApprovalManager = IERC20ApprovalManager(_erc20ApprovalManager);
    emit ERC20ApprovalManagerUpdated(_erc20ApprovalManager);
  }

  function updateERC721ApprovalManager(Config storage _config, address _erc721ApprovalManager) public {
    _config.erc721ApprovalManager = IERC721ApprovalManager(_erc721ApprovalManager);
    emit ERC721ApprovalManagerUpdated(_erc721ApprovalManager);
  }
}
