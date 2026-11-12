// contracts/token/ERC721/sovereign/LazySovereignBatchMintFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/proxy/Clones.sol";
import "./LazySovereignBatchMint.sol";
import "../../../royalty/RoyaltySplitReceiver.sol";

contract LazySovereignBatchMintFactory is Ownable {
  address public lazySovereignNFT;
  address public royaltySplitterFactory;

  event LazySovereignBatchMintCreated(address indexed contractAddress, address indexed owner);
  event RoyaltySplitterFactoryUpdated(address indexed previousFactory, address indexed newFactory);
  event RoyaltySplitConfigured(address indexed collection, address indexed splitter, address indexed owner);

  constructor(address _lazySovereignBatchMintImplementation) {
    require(_lazySovereignBatchMintImplementation != address(0), "Implementation address cannot be zero");
    lazySovereignNFT = _lazySovereignBatchMintImplementation;
    LazySovereignBatchMint(lazySovereignNFT).init("Lazy Sovereign Batch Mint", "LSOV", msg.sender, type(uint256).max);
  }

  function setLazySovereignBatchMint(address _lazySovereignNFT) external onlyOwner {
    require(_lazySovereignNFT != address(0), "setLazySovereignBatchMint::lazySovereignNFT cannot be zero address");
    lazySovereignNFT = _lazySovereignNFT;
  }

  function setRoyaltySplitterFactory(address splitterFactory) external onlyOwner {
    require(splitterFactory.code.length != 0, "Invalid royalty splitter factory");
    emit RoyaltySplitterFactoryUpdated(royaltySplitterFactory, splitterFactory);
    royaltySplitterFactory = splitterFactory;
  }

  function createLazySovereignBatchMintWithRoyaltySplit(
    string calldata name,
    string calldata symbol,
    uint256 maxTokens,
    RoyaltySplitConfig calldata config
  ) external returns (address collection, address splitter) {
    require(maxTokens != 0, "createLazySovereignBatchMint::_maxTokens cant be zero");
    require(royaltySplitterFactory.code.length != 0, "Royalty splitter factory is not configured");
    require(lazySovereignNFT.code.length != 0, "Invalid NFT implementation");
    collection = Clones.clone(lazySovereignNFT);
    splitter = IRoyaltySplitInitializable(collection).initWithRoyaltySplit(
      name, symbol, msg.sender, maxTokens, royaltySplitterFactory, config
    );
    emit LazySovereignBatchMintCreated(collection, msg.sender);
    emit RoyaltySplitConfigured(collection, splitter, msg.sender);
  }

  function createLazySovereignBatchMint(
    string memory _name,
    string memory _symbol,
    uint256 _maxTokens
  ) public returns (address) {
    require(_maxTokens != 0, "createLazySovereignBatchMint::_maxTokens cant be zero");
    address sovAddr = Clones.clone(lazySovereignNFT);
    LazySovereignBatchMint(sovAddr).init(_name, _symbol, msg.sender, _maxTokens);

    emit LazySovereignBatchMintCreated(sovAddr, msg.sender);

    return sovAddr;
  }

  function createLazySovereignBatchMint(string memory _name, string memory _symbol) public returns (address) {
    address sovAddr = Clones.clone(lazySovereignNFT);
    LazySovereignBatchMint(sovAddr).init(_name, _symbol, msg.sender, type(uint256).max);

    emit LazySovereignBatchMintCreated(sovAddr, msg.sender);

    return sovAddr;
  }
}
