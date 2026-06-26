// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/StdInvariant.sol";
import "forge-std/Test.sol";

import {RareERC1155} from "../../../token/ERC1155/RareERC1155.sol";
import {RareERC1155ContractFactory} from "../../../token/ERC1155/RareERC1155ContractFactory.sol";

contract RareERC1155SupplyHandler is Test {
  RareERC1155 private token;

  address private minter;
  address[4] private holders;
  mapping(uint256 => uint256) private expectedLifetimeMinted;

  constructor(RareERC1155 _token, address _minter) {
    token = _token;
    minter = _minter;
    holders = [address(0x101), address(0x102), address(0x103), address(0x104)];
  }

  function mintTo(uint256 _tokenSeed, uint256 _receiverSeed, uint256 _amount) external {
    uint256 tokenId = _tokenId(_tokenSeed);
    uint256 amount = _bounded(_amount, 1, 30);

    if (token.totalMintedForToken(tokenId) + amount > token.maxSupplyForToken(tokenId)) {
      vm.prank(minter);
      vm.expectRevert();
      token.mintTo(_holder(_receiverSeed), tokenId, amount);
      return;
    }

    vm.prank(minter);
    token.mintTo(_holder(_receiverSeed), tokenId, amount);
    expectedLifetimeMinted[tokenId] += amount;
  }

  function mintBatch(uint256 _receiverSeed, uint256 _amountA, uint256 _amountB, uint256 _amountC) external {
    uint256[] memory tokenIds = new uint256[](3);
    uint256[] memory amounts = new uint256[](3);
    tokenIds[0] = 1;
    tokenIds[1] = 2;
    tokenIds[2] = 3;
    amounts[0] = _bounded(_amountA, 1, 30);
    amounts[1] = _bounded(_amountB, 1, 30);
    amounts[2] = _bounded(_amountC, 1, 30);

    bool exceedsMaxSupply = false;
    for (uint256 i = 0; i < tokenIds.length; i++) {
      if (token.totalMintedForToken(tokenIds[i]) + amounts[i] > token.maxSupplyForToken(tokenIds[i])) {
        exceedsMaxSupply = true;
      }
    }

    if (exceedsMaxSupply) {
      vm.prank(minter);
      vm.expectRevert();
      token.mintBatchTo(_holder(_receiverSeed), tokenIds, amounts);
      return;
    }

    vm.prank(minter);
    token.mintBatchTo(_holder(_receiverSeed), tokenIds, amounts);
    for (uint256 i = 0; i < tokenIds.length; i++) {
      expectedLifetimeMinted[tokenIds[i]] += amounts[i];
    }
  }

  function burn(uint256 _holderSeed, uint256 _tokenSeed, uint256 _amount) external {
    address tokenHolder = _holder(_holderSeed);
    uint256 tokenId = _tokenId(_tokenSeed);
    uint256 balance = token.balanceOf(tokenHolder, tokenId);
    if (balance == 0) return;

    vm.prank(tokenHolder);
    token.burn(tokenHolder, tokenId, _bounded(_amount, 1, balance));
  }

  function transfer(uint256 _fromSeed, uint256 _toSeed, uint256 _tokenSeed, uint256 _amount) external {
    address from = _holder(_fromSeed);
    address to = _holder(_toSeed);
    uint256 tokenId = _tokenId(_tokenSeed);
    uint256 balance = token.balanceOf(from, tokenId);
    if (balance == 0) return;

    vm.prank(from);
    token.safeTransferFrom(from, to, tokenId, _bounded(_amount, 1, balance), "");
  }

  function expectedMinted(uint256 _id) external view returns (uint256) {
    return expectedLifetimeMinted[_id];
  }

  function holder(uint256 _index) external view returns (address) {
    return holders[_index];
  }

  function holderCount() external pure returns (uint256) {
    return 4;
  }

  function _tokenId(uint256 _seed) private pure returns (uint256) {
    return (_seed % 3) + 1;
  }

  function _holder(uint256 _seed) private view returns (address) {
    return holders[_seed % holders.length];
  }

  function _bounded(uint256 _seed, uint256 _min, uint256 _max) private pure returns (uint256) {
    return _min + (_seed % (_max - _min + 1));
  }
}

contract RareERC1155SupplyInvariantTest is StdInvariant, Test {
  RareERC1155 private token;
  RareERC1155SupplyHandler private handler;

  address private owner = address(0x1111);
  address private minter = address(0x2222);

  function setUp() public {
    RareERC1155ContractFactory factory = new RareERC1155ContractFactory();
    factory.setDefaultMinter(minter);

    vm.prank(owner);
    token = RareERC1155(factory.createRareERC1155Contract("Rare Editions", "RARE1155", "ipfs://base/{id}.json"));

    vm.startPrank(owner);
    assertEq(token.createToken("ipfs://token/1.json", 40, owner), 1);
    assertEq(token.createToken("ipfs://token/2.json", 50, owner), 2);
    assertEq(token.createToken("ipfs://token/3.json", 60, owner), 3);
    vm.stopPrank();

    handler = new RareERC1155SupplyHandler(token, minter);
    targetContract(address(handler));
    bytes4[] memory selectors = new bytes4[](4);
    selectors[0] = RareERC1155SupplyHandler.mintTo.selector;
    selectors[1] = RareERC1155SupplyHandler.mintBatch.selector;
    selectors[2] = RareERC1155SupplyHandler.burn.selector;
    selectors[3] = RareERC1155SupplyHandler.transfer.selector;
    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
  }

  function invariant_lifetimeMintedNeverExceedsMaxSupply() public {
    for (uint256 tokenId = 1; tokenId <= 3; tokenId++) {
      assertLe(token.totalMintedForToken(tokenId), token.maxSupplyForToken(tokenId));
    }
  }

  function invariant_totalSupplyNeverExceedsLifetimeMinted() public {
    for (uint256 tokenId = 1; tokenId <= 3; tokenId++) {
      assertLe(token.totalSupply(tokenId), token.totalMintedForToken(tokenId));
    }
  }

  function invariant_lifetimeMintedIsNotReducedByBurnsOrTransfers() public {
    for (uint256 tokenId = 1; tokenId <= 3; tokenId++) {
      assertEq(token.totalMintedForToken(tokenId), handler.expectedMinted(tokenId));
    }
  }

  function invariant_totalSupplyMatchesTrackedHolderBalances() public {
    for (uint256 tokenId = 1; tokenId <= 3; tokenId++) {
      uint256 trackedBalances = 0;
      for (uint256 i = 0; i < handler.holderCount(); i++) {
        trackedBalances += token.balanceOf(handler.holder(i), tokenId);
      }
      assertEq(token.totalSupply(tokenId), trackedBalances);
    }
  }
}
