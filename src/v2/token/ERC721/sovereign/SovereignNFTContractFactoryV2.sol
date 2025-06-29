// contracts/token/ERC721/sovereign/SovereignNFTContractFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/proxy/Clones.sol";
import "./SovereignNFTV2.sol";
import "./extensions/SovereignNFTRoyaltyGuardV2.sol";
import "./extensions/SovereignNFTRoyaltyGuardDeadmanTriggerV2.sol";

contract SovereignNFTContractFactoryV2 is Ownable {
  bytes32 public constant SOVEREIGN_NFT = keccak256("SOVEREIGN_NFT");
  bytes32 public constant ROYALTY_GUARD = keccak256("ROYALTY_GUARD");
  bytes32 public constant ROYALTY_GUARD_DEADMAN = keccak256("ROYALTY_GUARD_DEADMAN");

  address public sovereignNFT;
  address public sovereignNFTRoyaltyGuard;
  address public sovereignNFTRoyaltyGuardDeadmanTrigger;

  event SovereignNFTContractCreatedV2(
    address indexed contractAddress,
    address indexed owner,
    bytes32 indexed contractType
  );

  constructor() {
    SovereignNFTV2 sovNFT = new SovereignNFTV2();
    sovereignNFT = address(sovNFT);

    SovereignNFTRoyaltyGuardV2 sovNFTRG = new SovereignNFTRoyaltyGuardV2();
    sovereignNFTRoyaltyGuard = address(sovNFTRG);

    SovereignNFTRoyaltyGuardDeadmanTriggerV2 sovNFTRGDT = new SovereignNFTRoyaltyGuardDeadmanTriggerV2();
    sovereignNFTRoyaltyGuardDeadmanTrigger = address(sovNFTRGDT);
  }

  function setSovereignNFT(address _sovereignNFT) external onlyOwner {
    require(_sovereignNFT != address(0));
    sovereignNFT = _sovereignNFT;
  }

  function setSovereignNFT(address _sovereignNFT, bytes32 _contractType) external onlyOwner {
    require(_sovereignNFT != address(0));
    if (_contractType == SOVEREIGN_NFT) {
      sovereignNFT = _sovereignNFT;
      return;
    }
    if (_contractType == ROYALTY_GUARD) {
      sovereignNFTRoyaltyGuard = _sovereignNFT;
      return;
    }
    if (_contractType == ROYALTY_GUARD_DEADMAN) {
      sovereignNFTRoyaltyGuardDeadmanTrigger = _sovereignNFT;
      return;
    }

    require(false, "setSovereignNFT::Unsupported _contractType.");
  }

  function createSovereignNFTContract(
    string memory _name,
    string memory _symbol,
    uint256 _maxTokens
  ) public returns (address) {
    require(_maxTokens != 0, "createSovereignNFTContract::_maxTokens cant be zero");
    address sovAddr = Clones.clone(sovereignNFT);
    SovereignNFTV2(sovAddr).init(_name, _symbol, msg.sender, _maxTokens);

    emit SovereignNFTContractCreatedV2(sovAddr, msg.sender, SOVEREIGN_NFT);

    return address(sovereignNFT);
  }

  function createSovereignNFTContract(string memory _name, string memory _symbol) public returns (address) {
    address sovAddr = Clones.clone(sovereignNFT);
    SovereignNFTV2(sovAddr).init(_name, _symbol, msg.sender, type(uint256).max);

    emit SovereignNFTContractCreatedV2(sovAddr, msg.sender, SOVEREIGN_NFT);

    return address(sovereignNFT);
  }

  function createSovereignNFTContract(
    string memory _name,
    string memory _symbol,
    uint256 _maxTokens,
    bytes32 _contractType
  ) public returns (address) {
    require(_maxTokens != 0, "createSovereignNFTContract::_maxTokens cant be zero");

    address sovAddr;
    if (_contractType == SOVEREIGN_NFT) {
      sovAddr = Clones.clone(sovereignNFT);
      SovereignNFTV2(sovAddr).init(_name, _symbol, msg.sender, _maxTokens);
    }
    if (_contractType == ROYALTY_GUARD) {
      sovAddr = Clones.clone(sovereignNFTRoyaltyGuard);
      SovereignNFTRoyaltyGuardV2(sovAddr).init(_name, _symbol, msg.sender, _maxTokens);
    }
    if (_contractType == ROYALTY_GUARD_DEADMAN) {
      sovAddr = Clones.clone(sovereignNFTRoyaltyGuardDeadmanTrigger);
      SovereignNFTRoyaltyGuardDeadmanTriggerV2(sovAddr).init(_name, _symbol, msg.sender, _maxTokens);
    }

    require(sovAddr != address(0), "createSovereignNFTContract::_contractType unsupported contract type.");
    emit SovereignNFTContractCreatedV2(sovAddr, msg.sender, _contractType);

    return address(sovAddr);
  }
}
