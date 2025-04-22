// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";

contract TestNFT is ERC721 {
  uint256 private _nextTokenId;

  constructor() ERC721("Test NFT", "TNFT") {}

  function mint(address to) public returns (uint256) {
    uint256 tokenId = _nextTokenId++;
    _mint(to, tokenId);
    return tokenId;
  }

  function mintBatch(address to, uint256 count) public returns (uint256[] memory) {
    uint256[] memory tokenIds = new uint256[](count);
    for (uint256 i = 0; i < count; i++) {
      tokenIds[i] = mint(to);
    }
    return tokenIds;
  }
}
