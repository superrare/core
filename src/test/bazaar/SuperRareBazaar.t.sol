// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";

import {ISuperRareBazaar, SuperRareBazaar} from "../../bazaar/SuperRareBazaar.sol";
import {ISuperRareMarketplace, SuperRareMarketplace} from "../../marketplace/SuperRareMarketplace.sol";
import {IMarketplaceSettings} from "rareprotocol/aux/marketplace/IMarketplaceSettings.sol";
import {IStakingSettings} from "rareprotocol/aux/marketplace/IStakingSettings.sol";
import {IRareRoyaltyRegistry} from "rareprotocol/aux/registry/interfaces/IRareRoyaltyRegistry.sol";
import {IPayments} from "rareprotocol/aux/payments/IPayments.sol";
import {Payments} from "rareprotocol/aux/payments/Payments.sol";
import {ISpaceOperatorRegistry} from "rareprotocol/aux/registry/interfaces/ISpaceOperatorRegistry.sol";
import {IApprovedTokenRegistry} from "rareprotocol/aux/registry/interfaces/IApprovedTokenRegistry.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";
import {Payments} from "rareprotocol/aux/payments/Payments.sol";
import {ISuperRareAuctionHouse, SuperRareAuctionHouse} from "../../auctionhouse/SuperRareAuctionHouse.sol";
import {IRareStakingRegistry} from "../../staking/registry/IRareStakingRegistry.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SuperFakeNFT} from "../../test/utils/SuperFakeNFT.sol";
import {TestRare} from "../../test/utils/TestRare.sol";
import {RareAppRegistry} from "../../registry/RareAppRegistry.sol";

contract SuperRareBazaarTest is Test {
  TestRare private superRareToken;
  SuperRareMarketplace private superRareMarketplace;
  SuperRareAuctionHouse private superRareAuctionHouse;
  SuperRareBazaar private superRareBazaar;


  address marketplaceSettings = address(0xabadaba1);
  address royaltyRegistry = address(0xabadaba2);
  address royaltyEngine = address(0xabadaba3);
  address spaceOperatorRegistry = address(0xabadaba6);
  address approvedTokenRegistry = address(0xabadaba7);
  address stakingRegistry = address(0xabadaba9);
  address networkBeneficiary = address(0xabadabaa);
  address rewardPool = address(0xcccc);

  address private immutable exploiter = vm.addr(0x123);
  address private immutable exploiter1 = vm.addr(0x231);
  address private immutable bidder = vm.addr(0x321);

  uint256 private constant TARGET_AMOUNT = 249.6 ether;

  uint256 private constant _lengthOfAuction = 1;

  bytes32 private constant SCHEDULED_AUCTION = "SCHEDULED_AUCTION";

  SuperFakeNFT private sfn;

  function setUp() public {
    // Create market, auction, bazaar, and token contracts
    superRareToken = new TestRare();
    superRareMarketplace = new SuperRareMarketplace();
    superRareAuctionHouse = new SuperRareAuctionHouse();
    superRareBazaar = new SuperRareBazaar();

    // Deploy Payments
    Payments payments = new Payments();

    // Initialize the bazaar
    superRareBazaar.initialize(marketplaceSettings, royaltyRegistry, royaltyEngine, address(superRareMarketplace), address(superRareAuctionHouse), spaceOperatorRegistry, approvedTokenRegistry, address(payments), stakingRegistry, networkBeneficiary);

    SuperFakeNFT _sfn = new SuperFakeNFT(address(superRareBazaar));
    sfn = _sfn;

    sfn.mint(exploiter, 1);
    superRareToken.transfer(bidder, 300 ether);
    vm.deal(address(superRareBazaar), 300 ether);

    vm.prank(bidder);
    superRareToken.approve(address(superRareBazaar), type(uint256).max);

    vm.prank(exploiter);
    sfn.setApprovalForAll(address(superRareBazaar), true);

    vm.prank(exploiter1);
    sfn.setApprovalForAll(address(superRareBazaar), true);

    // etch code into these so we can stub out methods. Need some
    vm.etch(marketplaceSettings, address(superRareToken).code);
    vm.etch(stakingRegistry, address(superRareToken).code);
    vm.etch(royaltyRegistry, address(superRareToken).code);
    vm.etch(royaltyEngine, address(superRareToken).code);
    vm.etch(spaceOperatorRegistry, address(superRareToken).code);
    vm.etch(approvedTokenRegistry, address(superRareToken).code);
  }

  function test_auctions_with_eth_sucess() public {

  }

  function test_auctions_with_erc20_success() public {

  }

  function test_convert_offer_currency_exploit() external {
    /*///////////////////////////////////////////////////
                        Mock Calls
    ///////////////////////////////////////////////////*/
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, exploiter1),
      abi.encode(address(0))
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, TARGET_AMOUNT),
      abi.encode((TARGET_AMOUNT * 3) / 100)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, TARGET_AMOUNT),
      abi.encode(0)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(uint16(300))
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceMaxValue.selector),
      abi.encode(type(uint256).max)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, TARGET_AMOUNT),
      abi.encode((TARGET_AMOUNT * 3) / 100)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(sfn), 1),
      abi.encode(false)
    );
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, exploiter1),
      abi.encode(false)
    );
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(superRareToken)),
      abi.encode(true)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, address(sfn)),
      abi.encode(uint16(1500))
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.markERC721Token.selector, address(sfn)),
      abi.encode()
    );

    /*///////////////////////////////////////////////////
                        Test
    ///////////////////////////////////////////////////*/
    configureAuction();
  }


  /*//////////////////////////////////////////////////////////////////////////
                          Helper Functions
  //////////////////////////////////////////////////////////////////////////*/

  // Receive function for test contract to be sent value
  receive() external payable {
    console2.log("Amount Recieved by Attacker:", msg.value);
  }
  
  // Verify convertOfferToAuction is deprecated and reverts
  function configureAuction() internal {
    createOffer();

    address payable[] memory _splitAddresses = new address payable[](1);
    _splitAddresses[0] = payable(address(this));

    uint16[] memory _splitRatios = new uint16[](1);
    _splitRatios[0] = 10000;

    vm.prank(exploiter);
    vm.expectRevert("convertOfferToAuction::Deprecated");
    superRareBazaar.convertOfferToAuction(
      address(sfn),
      1,
      address(superRareToken),
      TARGET_AMOUNT,
      _lengthOfAuction,
      _splitAddresses,
      _splitRatios
    );
  }

  function createOffer() internal {
    console2.log("Before Attack: SuperRareBazaar ETH Balance:", address(superRareBazaar).balance);

    //@exploit: Create an Offer using a custom NFT and the superRareToken as Currency
    vm.prank(bidder);
    superRareBazaar.offer(address(sfn), 1, address(superRareToken), TARGET_AMOUNT, true, address(0));
  }

  function test_buy_with_app_zero_no_fees() public {
    RareAppRegistry appRegistry = new RareAppRegistry(address(this));
    superRareBazaar.setAppRegistry(address(appRegistry));

    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, address(sfn), 1, TARGET_AMOUNT),
      abi.encode(new address payable[](0), new uint256[](0))
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(sfn), 1),
      abi.encode(false)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.markERC721Token.selector, address(sfn), 1, true),
      abi.encode()
    );
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(superRareToken)),
      abi.encode(true)
    );

    address payable[] memory splitAddresses = new address payable[](1);
    splitAddresses[0] = payable(exploiter);
    uint16[] memory splitRatios = new uint16[](1);
    splitRatios[0] = 10000;

    vm.prank(exploiter);
    superRareBazaar.setSalePrice(
      address(sfn),
      1,
      address(superRareToken),
      TARGET_AMOUNT,
      address(0),
      splitAddresses,
      splitRatios,
      address(0) // _app = 0, no fees
    );

    uint256 sellerBalanceBefore = superRareToken.balanceOf(exploiter);
    vm.prank(bidder);
    superRareBazaar.buy(address(sfn), 1, address(superRareToken), TARGET_AMOUNT);
    uint256 sellerBalanceAfter = superRareToken.balanceOf(exploiter);

    assertEq(sellerBalanceAfter - sellerBalanceBefore, TARGET_AMOUNT, "Seller should get full amount when _app is 0");
  }

  function test_buy_with_registered_app_fee_split() public {
    RareAppRegistry appRegistry = new RareAppRegistry(address(this));
    address appAddr = address(0x999);
    address appFeeRecipient = address(0x888);
    vm.prank(appAddr);
    appRegistry.registerApp(250, appFeeRecipient); // 2.5%

    superRareBazaar.setAppRegistry(address(appRegistry));

    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, address(sfn), 1, TARGET_AMOUNT),
      abi.encode(new address payable[](0), new uint256[](0))
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(sfn), 1),
      abi.encode(false)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.markERC721Token.selector, address(sfn), 1, true),
      abi.encode()
    );
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(superRareToken)),
      abi.encode(true)
    );

    address payable[] memory splitAddresses = new address payable[](1);
    splitAddresses[0] = payable(exploiter);
    uint16[] memory splitRatios = new uint16[](1);
    splitRatios[0] = 10000;

    vm.prank(exploiter);
    superRareBazaar.setSalePrice(
      address(sfn),
      1,
      address(superRareToken),
      TARGET_AMOUNT,
      address(0),
      splitAddresses,
      splitRatios,
      appAddr // registered app
    );

    uint256 sellerBalanceBefore = superRareToken.balanceOf(exploiter);
    uint256 appBalanceBefore = superRareToken.balanceOf(appFeeRecipient);
    uint256 protocolBalanceBefore = superRareToken.balanceOf(networkBeneficiary);

    vm.prank(bidder);
    superRareBazaar.buy(address(sfn), 1, address(superRareToken), TARGET_AMOUNT);

    (uint256 appShare, uint256 protocolShare, uint256 totalFee) =
      appRegistry.calculateFeeSplit(appAddr, TARGET_AMOUNT);

    uint256 sellerBalanceAfter = superRareToken.balanceOf(exploiter);
    uint256 appBalanceAfter = superRareToken.balanceOf(appFeeRecipient);
    uint256 protocolBalanceAfter = superRareToken.balanceOf(networkBeneficiary);

    assertEq(appBalanceAfter - appBalanceBefore, appShare, "App should receive appShare");
    assertEq(protocolBalanceAfter - protocolBalanceBefore, protocolShare, "Protocol should receive protocolShare");
    assertEq(sellerBalanceAfter - sellerBalanceBefore, TARGET_AMOUNT - totalFee, "Seller should get amount minus fee");
  }
}