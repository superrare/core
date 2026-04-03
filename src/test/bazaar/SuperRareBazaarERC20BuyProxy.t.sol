// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketplaceSettings} from "rareprotocol/aux/marketplace/IMarketplaceSettings.sol";
import {IStakingSettings} from "rareprotocol/aux/marketplace/IStakingSettings.sol";
import {ISpaceOperatorRegistry} from "rareprotocol/aux/registry/interfaces/ISpaceOperatorRegistry.sol";
import {IApprovedTokenRegistry} from "rareprotocol/aux/registry/interfaces/IApprovedTokenRegistry.sol";

import {SuperRareBazaar} from "../../bazaar/SuperRareBazaar.sol";
import {SuperRareBazaarERC20BuyProxy} from "../../bazaar/SuperRareBazaarERC20BuyProxy.sol";
import {SuperRareMarketplace} from "../../marketplace/SuperRareMarketplace.sol";
import {SuperRareAuctionHouse} from "../../auctionhouse/SuperRareAuctionHouse.sol";
import {IRareStakingRegistry} from "../../staking/registry/IRareStakingRegistry.sol";
import {Payments} from "rareprotocol/aux/payments/Payments.sol";
import {TestNFT} from "../v2/utils/TestNft.sol";
import {TestRare} from "../utils/TestRare.sol";

contract SameTransactionBuyer {
  using SafeERC20 for IERC20;

  function fundAndBuy(
    IERC20 _currency,
    SuperRareBazaarERC20BuyProxy _proxy,
    address _originContract,
    uint256 _tokenId,
    uint256 _amount,
    address _recipient
  ) external {
    _currency.safeTransfer(address(_proxy), _amount);
    _proxy.buy(_originContract, _tokenId, address(_currency), _amount, _recipient);
  }
}

contract SuperRareBazaarERC20BuyProxyTest is Test {
  uint256 private constant SALE_PRICE = 100 ether;
  uint256 private constant TOKEN_ID = 0;

  TestRare private currency;
  TestNFT private nft;
  SuperRareMarketplace private marketplace;
  SuperRareAuctionHouse private auctionHouse;
  SuperRareBazaar private bazaar;
  SuperRareBazaarERC20BuyProxy private proxy;
  SameTransactionBuyer private sameTransactionBuyer;

  address private marketplaceSettings = address(0xabadaba1);
  address private royaltyRegistry = address(0xabadaba2);
  address private royaltyEngine = address(0xabadaba3);
  address private spaceOperatorRegistry = address(0xabadaba6);
  address private approvedTokenRegistry = address(0xabadaba7);
  address private stakingRegistry = address(0xabadaba9);
  address private networkBeneficiary = address(0xabadabaa);

  address private immutable seller = vm.addr(0x111);
  address private immutable recipient = vm.addr(0x222);
  address private immutable nonOwner = vm.addr(0x333);

  function setUp() public {
    currency = new TestRare();
    nft = new TestNFT();
    marketplace = new SuperRareMarketplace();
    auctionHouse = new SuperRareAuctionHouse();
    bazaar = new SuperRareBazaar();
    proxy = new SuperRareBazaarERC20BuyProxy(address(bazaar));
    sameTransactionBuyer = new SameTransactionBuyer();

    Payments payments = new Payments();
    bazaar.initialize(
      marketplaceSettings,
      royaltyRegistry,
      royaltyEngine,
      address(marketplace),
      address(auctionHouse),
      spaceOperatorRegistry,
      approvedTokenRegistry,
      address(payments),
      stakingRegistry,
      networkBeneficiary
    );

    vm.etch(marketplaceSettings, address(currency).code);
    vm.etch(royaltyRegistry, address(currency).code);
    vm.etch(royaltyEngine, address(currency).code);
    vm.etch(spaceOperatorRegistry, address(currency).code);
    vm.etch(approvedTokenRegistry, address(currency).code);
    vm.etch(stakingRegistry, address(currency).code);

    nft.mint(seller);

    vm.prank(seller);
    nft.setApprovalForAll(address(bazaar), true);

    _mockMarketDependencies();
    _setSalePrice();
  }

  function test_approveCurrency_success() public {
    proxy.approveCurrency(address(currency), type(uint256).max);

    assertEq(currency.allowance(address(proxy), address(bazaar)), type(uint256).max);
  }

  function test_approveCurrency_onlyOwner() public {
    vm.prank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    proxy.approveCurrency(address(currency), SALE_PRICE);
  }

  function test_buy_success_sameTransactionFunding() public {
    proxy.approveCurrency(address(currency), type(uint256).max);
    currency.transfer(address(sameTransactionBuyer), SALE_PRICE);

    sameTransactionBuyer.fundAndBuy(
      IERC20(address(currency)),
      proxy,
      address(nft),
      TOKEN_ID,
      SALE_PRICE,
      recipient
    );

    assertEq(nft.ownerOf(TOKEN_ID), recipient);
    assertEq(currency.balanceOf(seller), SALE_PRICE);
    assertEq(currency.balanceOf(address(proxy)), 0);
    assertEq(currency.balanceOf(address(bazaar)), 0);
    assertEq(currency.balanceOf(address(sameTransactionBuyer)), 0);
  }

  function test_buy_revertWhenCurrencyZero() public {
    vm.expectRevert(SuperRareBazaarERC20BuyProxy.CurrencyAddressCannotBeZero.selector);
    proxy.buy(address(nft), TOKEN_ID, address(0), SALE_PRICE, recipient);
  }

  function test_buy_revertWhenRecipientZero() public {
    vm.expectRevert(SuperRareBazaarERC20BuyProxy.RecipientCannotBeZero.selector);
    proxy.buy(address(nft), TOKEN_ID, address(currency), SALE_PRICE, address(0));
  }

  function _mockMarketDependencies() internal {
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(currency)),
      abi.encode(true)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, SALE_PRICE),
      abi.encode(0)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, SALE_PRICE),
      abi.encode(0)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, SALE_PRICE),
      abi.encode(0)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(nft), TOKEN_ID),
      abi.encode(false)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, address(nft)),
      abi.encode(0)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.markERC721Token.selector, address(nft), TOKEN_ID, true),
      abi.encode()
    );
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, seller),
      abi.encode(address(0))
    );
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, seller),
      abi.encode(false)
    );
  }

  function _setSalePrice() internal {
    address payable[] memory splitAddrs = new address payable[](1);
    splitAddrs[0] = payable(seller);

    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;

    vm.prank(seller);
    bazaar.setSalePrice(address(nft), TOKEN_ID, address(currency), SALE_PRICE, address(0), splitAddrs, splitRatios);
  }
}
