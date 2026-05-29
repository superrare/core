// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IMarketplaceSettings} from "rareprotocol/aux/marketplace/IMarketplaceSettings.sol";

import {SuperRareBazaarERC20BuyProxy} from "../../../../bazaar/SuperRareBazaarERC20BuyProxy.sol";
import {IRareMinter} from "../../../../collection/IRareMinter.sol";

interface IBazaarSettings {
  function marketplaceSettings() external view returns (address);
}

contract SuperRareBazaarERC20BuyProxySepolia is Test {
  address private constant BAZAAR = 0xC8Edc7049b233641ad3723D6C60019D1c8771612;
  address private constant PROXY = 0xC68D3f1D951DEb15c384E6534d82fb4dd9e87717;
  address private constant RARE_MINTER = 0xd28Dc0B89104d7BBd902F338a0193fF063617ccE;
  address private constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
  address private constant NFT_CONTRACT = 0xf07956E787177912543Fe52e687Fd8b8706F1E3C;
  address private constant BUYER = 0x3B9C3C5EA16E7d3c9C0bb293a549aFa4066dc162;

  uint8 private constant NUM_MINTS = 3;

  SuperRareBazaarERC20BuyProxy private proxy;
  bytes32[] private emptyProof;

  function setUp() public {
    vm.createSelectFork(vm.envString("RPC_URL"));
    require(block.chainid == 11155111, "This test must run on a Sepolia fork");

    proxy = SuperRareBazaarERC20BuyProxy(PROXY);
  }

  function test_sepolia_mintDirectSale_withProxy() public {
    IRareMinter.DirectSaleConfig memory directSaleConfig = IRareMinter(RARE_MINTER).getDirectSaleConfig(NFT_CONTRACT);
    assertEq(directSaleConfig.currencyAddress, USDC);
    assertGt(directSaleConfig.price, 0);

    uint256 totalPrice = directSaleConfig.price * NUM_MINTS;
    uint256 marketplaceFee =
      IMarketplaceSettings(IBazaarSettings(BAZAAR).marketplaceSettings()).calculateMarketplaceFee(totalPrice);
    uint256 requiredAmount = totalPrice + marketplaceFee;

    uint256 buyerNftBalanceBefore = IERC721(NFT_CONTRACT).balanceOf(BUYER);

    deal(USDC, BUYER, IERC20(USDC).balanceOf(BUYER) + requiredAmount);

    vm.startPrank(BUYER);
    IERC20(USDC).approve(address(proxy), type(uint256).max);
    proxy.mint(NFT_CONTRACT, USDC, directSaleConfig.price, NUM_MINTS, emptyProof, BUYER);
    vm.stopPrank();

    assertEq(IERC721(NFT_CONTRACT).balanceOf(BUYER), buyerNftBalanceBefore + NUM_MINTS);
    assertEq(IERC20(USDC).balanceOf(address(proxy)), 0);
    assertEq(IERC721(NFT_CONTRACT).balanceOf(address(proxy)), 0);
  }
}
