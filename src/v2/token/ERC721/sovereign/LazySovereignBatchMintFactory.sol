// contracts/token/ERC721/sovereign/LazySovereignBatchMintFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/proxy/Clones.sol";
import "./LazySovereignBatchMint.sol";

contract LazySovereignBatchMintFactory is Ownable {
  address public lazySovereignNFT;

  event LazySovereignBatchMintCreated(address indexed contractAddress, address indexed owner);

  constructor(address _lazySovereignBatchMintImplementation) {
    require(_lazySovereignBatchMintImplementation != address(0), "Implementation address cannot be zero");
    lazySovereignNFT = _lazySovereignBatchMintImplementation;
    LazySovereignBatchMint(lazySovereignNFT).init("Lazy Sovereign Batch Mint", "LSOV", msg.sender, type(uint256).max);
  }

  function setLazySovereignBatchMint(address _lazySovereignNFT) external onlyOwner {
    require(_lazySovereignNFT != address(0), "setLazySovereignBatchMint::lazySovereignNFT cannot be zero address");
    lazySovereignNFT = _lazySovereignNFT;
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
