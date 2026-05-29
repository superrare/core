// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {IMarketplaceSettings} from "rareprotocol/aux/marketplace/IMarketplaceSettings.sol";
import {IStakingSettings} from "rareprotocol/aux/marketplace/IStakingSettings.sol";
import {ISpaceOperatorRegistry} from "rareprotocol/aux/registry/interfaces/ISpaceOperatorRegistry.sol";
import {IApprovedTokenRegistry} from "rareprotocol/aux/registry/interfaces/IApprovedTokenRegistry.sol";

import {SuperRareBazaar} from "../../bazaar/SuperRareBazaar.sol";
import {SuperRareBazaarERC20BuyProxy} from "../../bazaar/SuperRareBazaarERC20BuyProxy.sol";
import {SuperRareMarketplace} from "../../marketplace/SuperRareMarketplace.sol";
import {SuperRareAuctionHouse} from "../../auctionhouse/SuperRareAuctionHouse.sol";
import {RareMinter} from "../../collection/RareMinter.sol";
import {IRareStakingRegistry} from "../../staking/registry/IRareStakingRegistry.sol";
import {Payments} from "rareprotocol/aux/payments/Payments.sol";
import {TestNFT} from "../v2/utils/TestNft.sol";
import {TestRare} from "../utils/TestRare.sol";

contract SameTransactionBuyer {
  function approveAndBuy(
    IERC20 _currency,
    SuperRareBazaarERC20BuyProxy _proxy,
    address _originContract,
    uint256 _tokenId,
    uint256 _approvalAmount,
    uint256 _amount,
    address _recipient
  ) external {
    _currency.approve(address(_proxy), _approvalAmount);
    _proxy.buy(_originContract, _tokenId, address(_currency), _amount, _recipient);
  }
}

contract SameTransactionMinter {
  function approveAndMint(
    IERC20 _currency,
    SuperRareBazaarERC20BuyProxy _proxy,
    address _originContract,
    uint256 _approvalAmount,
    uint256 _amount,
    uint8 _numMints,
    bytes32[] calldata _proof,
    address _recipient
  ) external {
    _currency.approve(address(_proxy), _approvalAmount);
    _proxy.mint(_originContract, address(_currency), _amount, _numMints, _proof, _recipient);
  }
}

contract TestMintNFT is ERC721, Ownable {
  uint256 private tokenCount;

  constructor() ERC721("Test Mint NFT", "TMNFT") {}

  function mintTo(address _receiver) external returns (uint256) {
    tokenCount++;
    _safeMint(_receiver, tokenCount);
    return tokenCount;
  }
}

contract MockMarketplaceSettings {
  uint256 private immutable fee;

  constructor(uint256 _fee) {
    fee = _fee;
  }

  function calculateMarketplaceFee(uint256) external view returns (uint256) {
    return fee;
  }
}

contract MockBazaarSettings {
  address private immutable settings;

  constructor(address _settings) {
    settings = _settings;
  }

  function marketplaceSettings() external view returns (address) {
    return settings;
  }
}

contract CallbackCountingRareMinter {
  uint8 private immutable mintedCount;
  address private immutable unexpectedOriginContract;
  bool private immutable mintUnexpectedToken;

  constructor(uint8 _mintedCount, address _unexpectedOriginContract, bool _mintUnexpectedToken) {
    mintedCount = _mintedCount;
    unexpectedOriginContract = _unexpectedOriginContract;
    mintUnexpectedToken = _mintUnexpectedToken;
  }

  function mintDirectSale(address _originContract, address, uint256, uint8, bytes32[] calldata) external {
    for (uint256 i = 0; i < mintedCount; i++) {
      TestMintNFT(_originContract).mintTo(msg.sender);
    }

    if (mintUnexpectedToken) {
      TestMintNFT(unexpectedOriginContract).mintTo(msg.sender);
    }
  }
}

contract SuperRareBazaarERC20BuyProxyTest is Test {
  uint256 private constant SALE_PRICE = 100 ether;
  uint256 private constant MARKETPLACE_FEE = 3 ether;
  uint256 private constant REQUIRED_AMOUNT = SALE_PRICE + MARKETPLACE_FEE;
  uint256 private constant TOKEN_ID = 0;
  uint256 private constant MINT_PRICE = 50 ether;
  uint8 private constant MINT_COUNT = 2;
  uint256 private constant MINT_TOTAL_PRICE = MINT_PRICE * MINT_COUNT;
  uint256 private constant MINT_REQUIRED_AMOUNT = MINT_TOTAL_PRICE + MARKETPLACE_FEE;

  TestRare private currency;
  TestNFT private nft;
  TestMintNFT private mintNft;
  SuperRareMarketplace private marketplace;
  SuperRareAuctionHouse private auctionHouse;
  SuperRareBazaar private bazaar;
  RareMinter private rareMinter;
  SuperRareBazaarERC20BuyProxy private proxy;
  SameTransactionBuyer private sameTransactionBuyer;
  SameTransactionMinter private sameTransactionMinter;

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
  bytes32[] private emptyProof;

  function setUp() public {
    currency = new TestRare();
    nft = new TestNFT();
    mintNft = new TestMintNFT();
    marketplace = new SuperRareMarketplace();
    auctionHouse = new SuperRareAuctionHouse();
    bazaar = new SuperRareBazaar();
    rareMinter = new RareMinter();
    proxy = new SuperRareBazaarERC20BuyProxy(address(bazaar), address(rareMinter));
    sameTransactionBuyer = new SameTransactionBuyer();
    sameTransactionMinter = new SameTransactionMinter();

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
    rareMinter.initialize(
      networkBeneficiary,
      marketplaceSettings,
      spaceOperatorRegistry,
      royaltyEngine,
      address(payments),
      approvedTokenRegistry,
      marketplaceSettings,
      stakingRegistry
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

    mintNft.transferOwnership(seller);
    vm.prank(seller);
    _prepareDirectSale();

    _setSalePrice();
  }

  function test_approveCurrency_success() public {
    proxy.approveCurrency(address(currency), type(uint256).max);

    assertEq(currency.allowance(address(proxy), address(bazaar)), type(uint256).max);
    assertEq(currency.allowance(address(proxy), address(rareMinter)), type(uint256).max);
  }

  function test_approveCurrency_onlyOwner() public {
    vm.prank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    proxy.approveCurrency(address(currency), SALE_PRICE);
  }

  function test_approveCurrency_revertWhenCurrencyZero() public {
    vm.expectRevert(SuperRareBazaarERC20BuyProxy.CurrencyAddressCannotBeZero.selector);
    proxy.approveCurrency(address(0), SALE_PRICE);
  }

  function test_buy_success_sameTransactionFunding() public {
    proxy.approveCurrency(address(currency), type(uint256).max);
    currency.transfer(address(sameTransactionBuyer), REQUIRED_AMOUNT);

    sameTransactionBuyer.approveAndBuy(
      IERC20(address(currency)),
      proxy,
      address(nft),
      TOKEN_ID,
      REQUIRED_AMOUNT,
      SALE_PRICE,
      recipient
    );

    assertEq(nft.ownerOf(TOKEN_ID), recipient);
    assertEq(currency.balanceOf(seller), SALE_PRICE);
    assertEq(currency.balanceOf(networkBeneficiary), MARKETPLACE_FEE);
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

  function test_constructor_revertWhenBazaarZero() public {
    vm.expectRevert(SuperRareBazaarERC20BuyProxy.BazaarCannotBeZeroAddress.selector);
    new SuperRareBazaarERC20BuyProxy(address(0), address(rareMinter));
  }

  function test_constructor_revertWhenRareMinterZero() public {
    vm.expectRevert(SuperRareBazaarERC20BuyProxy.RareMinterCannotBeZeroAddress.selector);
    new SuperRareBazaarERC20BuyProxy(address(bazaar), address(0));
  }

  function test_mint_success_sameTransactionFunding() public {
    proxy.approveCurrency(address(currency), type(uint256).max);
    currency.transfer(address(sameTransactionMinter), MINT_REQUIRED_AMOUNT);

    sameTransactionMinter.approveAndMint(
      IERC20(address(currency)),
      proxy,
      address(mintNft),
      MINT_REQUIRED_AMOUNT,
      MINT_PRICE,
      MINT_COUNT,
      emptyProof,
      recipient
    );

    assertEq(mintNft.ownerOf(1), recipient);
    assertEq(mintNft.ownerOf(2), recipient);
    assertEq(currency.balanceOf(seller), MINT_TOTAL_PRICE);
    assertEq(currency.balanceOf(networkBeneficiary), MARKETPLACE_FEE);
    assertEq(currency.balanceOf(address(proxy)), 0);
    assertEq(currency.balanceOf(address(rareMinter)), 0);
    assertEq(currency.balanceOf(address(sameTransactionMinter)), 0);
  }

  function test_mint_revertWhenCurrencyZero() public {
    vm.expectRevert(SuperRareBazaarERC20BuyProxy.CurrencyAddressCannotBeZero.selector);
    proxy.mint(address(mintNft), address(0), MINT_PRICE, MINT_COUNT, emptyProof, recipient);
  }

  function test_mint_revertWhenRecipientZero() public {
    vm.expectRevert(SuperRareBazaarERC20BuyProxy.RecipientCannotBeZero.selector);
    proxy.mint(address(mintNft), address(currency), MINT_PRICE, MINT_COUNT, emptyProof, address(0));
  }

  function test_mint_revertWhenMintedTokenCountDoesNotMatchRequestedCount() public {
    MockMarketplaceSettings mockSettings = new MockMarketplaceSettings(MARKETPLACE_FEE);
    MockBazaarSettings mockBazaar = new MockBazaarSettings(address(mockSettings));
    CallbackCountingRareMinter mismatchRareMinter = new CallbackCountingRareMinter(1, address(0), false);
    SuperRareBazaarERC20BuyProxy mismatchProxy =
      new SuperRareBazaarERC20BuyProxy(address(mockBazaar), address(mismatchRareMinter));
    TestRare localCurrency = new TestRare();
    TestMintNFT localMintNft = new TestMintNFT();

    mismatchProxy.approveCurrency(address(localCurrency), type(uint256).max);
    localCurrency.approve(address(mismatchProxy), MINT_REQUIRED_AMOUNT);

    vm.expectRevert(
      abi.encodeWithSelector(
        SuperRareBazaarERC20BuyProxy.UnexpectedMintedTokenCount.selector, uint256(MINT_COUNT), uint256(1)
      )
    );
    mismatchProxy.mint(address(localMintNft), address(localCurrency), MINT_PRICE, MINT_COUNT, emptyProof, recipient);
  }

  function test_mint_ignoresCallbacksFromUnexpectedOriginContract() public {
    MockMarketplaceSettings mockSettings = new MockMarketplaceSettings(MARKETPLACE_FEE);
    MockBazaarSettings mockBazaar = new MockBazaarSettings(address(mockSettings));
    TestMintNFT localMintNft = new TestMintNFT();
    TestMintNFT unrelatedMintNft = new TestMintNFT();
    CallbackCountingRareMinter gatedRareMinter =
      new CallbackCountingRareMinter(1, address(unrelatedMintNft), true);
    SuperRareBazaarERC20BuyProxy gatedProxy =
      new SuperRareBazaarERC20BuyProxy(address(mockBazaar), address(gatedRareMinter));
    TestRare localCurrency = new TestRare();

    gatedProxy.approveCurrency(address(localCurrency), type(uint256).max);
    localCurrency.approve(address(gatedProxy), MINT_PRICE + MARKETPLACE_FEE);

    gatedProxy.mint(address(localMintNft), address(localCurrency), MINT_PRICE, 1, emptyProof, recipient);

    assertEq(localMintNft.ownerOf(1), recipient);
    assertEq(unrelatedMintNft.ownerOf(1), address(gatedProxy));
  }

  function test_onERC721Received_success() public {
    bytes4 selector = proxy.onERC721Received(address(this), seller, TOKEN_ID, "");

    assertEq(selector, IERC721Receiver.onERC721Received.selector);
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
      abi.encode(MARKETPLACE_FEE)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, MINT_TOTAL_PRICE),
      abi.encode(MARKETPLACE_FEE)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, SALE_PRICE),
      abi.encode(MARKETPLACE_FEE)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, MINT_TOTAL_PRICE),
      abi.encode(MARKETPLACE_FEE)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, SALE_PRICE),
      abi.encode(0)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, MINT_TOTAL_PRICE),
      abi.encode(0)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(nft), TOKEN_ID),
      abi.encode(false)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(mintNft), 1),
      abi.encode(false)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(mintNft), 2),
      abi.encode(false)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, address(nft)),
      abi.encode(0)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, address(mintNft)),
      abi.encode(0)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.markERC721Token.selector, address(nft), TOKEN_ID, true),
      abi.encode()
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.markERC721Token.selector, address(mintNft), 1, true),
      abi.encode()
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.markERC721Token.selector, address(mintNft), 2, true),
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

  function _prepareDirectSale() internal {
    address payable[] memory splitAddrs = new address payable[](1);
    splitAddrs[0] = payable(seller);

    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;

    rareMinter.prepareMintDirectSale(address(mintNft), address(currency), MINT_PRICE, 0, 0, splitAddrs, splitRatios);
  }
}
