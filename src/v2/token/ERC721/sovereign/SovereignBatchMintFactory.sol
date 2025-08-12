// contracts/token/ERC721/sovereign/SovereignNFTContractFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/proxy/Clones.sol";
import "./SovereignBatchMint.sol";

contract SovereignBatchMintFactory is Ownable {
  address public sovereignNFT;

  event SovereignBatchMintCreated(address indexed contractAddress, address indexed owner);

  constructor(address _sovereignBatchMintImplementation) {
    require(_sovereignBatchMintImplementation != address(0), "Implementation address cannot be zero");
    sovereignNFT = _sovereignBatchMintImplementation;
  }

  function setSovereignBatchMint(address _sovereignNFT) external onlyOwner {
    require(_sovereignNFT != address(0));
    sovereignNFT = _sovereignNFT;
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
