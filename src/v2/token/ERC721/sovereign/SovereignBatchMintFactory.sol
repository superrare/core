// contracts/token/ERC721/sovereign/SovereignNFTContractFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/proxy/Clones.sol";
import "./SovereignBatchMint.sol";
import "../../../royalty/RoyaltySplitReceiver.sol";

contract SovereignBatchMintFactory is Ownable {
  address public sovereignNFT;
  address public royaltySplitterFactory;

  event SovereignBatchMintCreated(address indexed contractAddress, address indexed owner);
  event RoyaltySplitterFactoryUpdated(address indexed previousFactory, address indexed newFactory);
  event RoyaltySplitConfigured(address indexed collection, address indexed splitter, address indexed owner);

  constructor(address _sovereignBatchMintImplementation) {
    require(_sovereignBatchMintImplementation != address(0), "Implementation address cannot be zero");
    sovereignNFT = _sovereignBatchMintImplementation;
    SovereignBatchMint(sovereignNFT).init("Sovereign Batch Mint", "SOV", msg.sender, type(uint256).max);
  }

  function setSovereignBatchMint(address _sovereignNFT) external onlyOwner {
    require(_sovereignNFT != address(0));
    sovereignNFT = _sovereignNFT;
  }

  function setRoyaltySplitterFactory(address splitterFactory) external onlyOwner {
    require(splitterFactory.code.length != 0, "Invalid royalty splitter factory");
    emit RoyaltySplitterFactoryUpdated(royaltySplitterFactory, splitterFactory);
    royaltySplitterFactory = splitterFactory;
  }

  function createSovereignBatchMintWithRoyaltySplit(
    string calldata name,
    string calldata symbol,
    uint256 maxTokens,
    RoyaltySplitConfig calldata config
  ) external returns (address collection, address splitter) {
    require(maxTokens != 0, "createSovereignNFTContract::_maxTokens cant be zero");
    require(royaltySplitterFactory.code.length != 0, "Royalty splitter factory is not configured");
    require(sovereignNFT.code.length != 0, "Invalid NFT implementation");
    collection = Clones.clone(sovereignNFT);
    splitter = IRoyaltySplitInitializable(collection).initWithRoyaltySplit(
      name, symbol, msg.sender, maxTokens, royaltySplitterFactory, config
    );
    emit SovereignBatchMintCreated(collection, msg.sender);
    emit RoyaltySplitConfigured(collection, splitter, msg.sender);
  }

  function createSovereignBatchMint(
    string memory _name,
    string memory _symbol,
    uint256 _maxTokens
  ) public returns (address) {
    require(_maxTokens != 0, "createSovereignNFTContract::_maxTokens cant be zero");
    address sovAddr = Clones.clone(sovereignNFT);
    SovereignBatchMint(sovAddr).init(_name, _symbol, msg.sender, _maxTokens);

    emit SovereignBatchMintCreated(sovAddr, msg.sender);

    return address(sovAddr);
  }

  function createSovereignBatchMint(string memory _name, string memory _symbol) public returns (address) {
    address sovAddr = Clones.clone(sovereignNFT);
    SovereignBatchMint(sovAddr).init(_name, _symbol, msg.sender, type(uint256).max);

    emit SovereignBatchMintCreated(sovAddr, msg.sender);

    return address(sovAddr);
  }
}
