// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {SuperRareAuctionHouseV2} from "../../../v2/auctionhouse/SuperRareAuctionHouseV2.sol";
import {ISuperRareAuctionHouseV2} from "../../../v2/auctionhouse/ISuperRareAuctionHouseV2.sol";
import {TestNFT} from "../utils/TestNft.sol";
import {TestToken} from "../utils/TestToken.sol";
import {ERC20ApprovalManager} from "../../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../../v2/approver/ERC721/ERC721ApprovalManager.sol";

/// @title SuperRareAuctionHouseV2StandardTest
/// @notice Tests for the standard auction functionality in SuperRareAuctionHouseV2
contract SuperRareAuctionHouseV2StandardTest is Test {
  // Core contracts
  SuperRareAuctionHouseV2 public auctionHouse;
  TestNFT public nft;
  TestToken public currency;
  ERC20ApprovalManager public erc20ApprovalManager;
  ERC721ApprovalManager public erc721ApprovalManager;

  // Mock addresses for dependencies
  address public marketplaceSettings;
  address public royaltyEngine;
  address public spaceOperatorRegistry;
  address public approvedTokenRegistry;
  address public payments;
  address public stakingRegistry;
  address public stakingSettings;
  address public networkBeneficiary;

  // Test accounts
  address public admin;
  address public creator;
  address public bidder;
  address public otherBidder;

  // Test data
  uint256 public tokenId;
  address payable[] public splitRecipients;
  uint8[] public splitRatios;

  // Constants
  uint256 public constant STARTING_BID = 1 ether;
  uint256 public constant AUCTION_DURATION = 1 days;
  uint256 public constant MIN_BID_INCREMENT = 1; // 1%
  uint256 public constant MAX_AUCTION_LENGTH = 7 days;
  uint256 public constant AUCTION_EXTENSION = 15 minutes;
  uint256 public constant MARKETPLACE_FEE = 3; // 3%

  bytes32 public constant COLDIE = keccak256("COLDIE_AUCTION");
  bytes32 public constant SCHEDULED = keccak256("SCHEDULED_AUCTION");

  function setUp() public {
    // Setup test accounts
    admin = makeAddr("admin");
    creator = makeAddr("creator");
    bidder = makeAddr("bidder");
    otherBidder = makeAddr("otherBidder");

    // Setup mock addresses
    marketplaceSettings = makeAddr("marketplaceSettings");
    royaltyEngine = makeAddr("royaltyEngine");
    spaceOperatorRegistry = makeAddr("spaceOperatorRegistry");
    approvedTokenRegistry = makeAddr("approvedTokenRegistry");
    payments = makeAddr("payments");
    stakingRegistry = makeAddr("stakingRegistry");
    stakingSettings = makeAddr("stakingSettings");
    networkBeneficiary = makeAddr("networkBeneficiary");

    // Deploy core contracts
    nft = new TestNFT();
    currency = new TestToken();
    erc20ApprovalManager = new ERC20ApprovalManager();
    erc721ApprovalManager = new ERC721ApprovalManager();
    auctionHouse = new SuperRareAuctionHouseV2();

    // Initialize auction house
    auctionHouse.initialize(
      marketplaceSettings,
      royaltyEngine,
      spaceOperatorRegistry,
      approvedTokenRegistry,
      payments,
      stakingRegistry,
      stakingSettings,
      networkBeneficiary,
      address(erc20ApprovalManager),
      address(erc721ApprovalManager)
    );

    // Setup mock behaviors
    vm.mockCall(marketplaceSettings, abi.encodeWithSignature("getMarketplaceMaxValue()"), abi.encode(1000 ether));
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSignature("getMarketplaceFeePercentage()"),
      abi.encode(MARKETPLACE_FEE)
    );
    vm.mockCall(approvedTokenRegistry, abi.encodeWithSignature("isApprovedToken(address)"), abi.encode(true));
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSignature("calculateMarketplaceFee(uint256)"),
      abi.encode(.03 ether) // 3% of 1 ether
    );
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSignature("getRewardAccumulatorAddressForUser(address)"),
      abi.encode(address(0))
    );
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSignature("calculateMarketplacePayoutFee(uint256)"),
      abi.encode(.03 ether) // Using same 3% fee for consistency
    );
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSignature("calculateStakingFee(uint256)"),
      abi.encode(0) // Using same 3% fee for consistency
    );
    vm.mockCall(marketplaceSettings, abi.encodeWithSignature("hasERC721TokenSold(address,uint256)"), abi.encode(false));
    vm.mockCall(spaceOperatorRegistry, abi.encodeWithSignature("isApprovedSpaceOperator(address)"), abi.encode(true));
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSignature("getPlatformCommission(address)"),
      abi.encode(0) // No platform commission
    );
    // Mock royalty engine to return no royalties
    address[] memory recipients = new address[](0);
    uint256[] memory amounts = new uint256[](0);
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSignature("getRoyalty(address,uint256,uint256)"),
      abi.encode(recipients, amounts)
    );

    // Grant roles
    erc20ApprovalManager.grantRole(erc20ApprovalManager.DEFAULT_ADMIN_ROLE(), admin);

    erc721ApprovalManager.grantRole(erc721ApprovalManager.DEFAULT_ADMIN_ROLE(), admin);

    vm.startPrank(admin);
    erc20ApprovalManager.grantRole(erc20ApprovalManager.OPERATOR_ROLE(), address(auctionHouse));
    erc721ApprovalManager.grantRole(erc721ApprovalManager.OPERATOR_ROLE(), address(auctionHouse));
    vm.stopPrank();

    // Mint NFT to creator
    tokenId = nft.mint(creator);

    // Deal ETH and ERC20
    vm.deal(creator, 10 ether);
    vm.deal(bidder, 10 ether);
    vm.deal(otherBidder, 10 ether);
    currency.mint(bidder, 1000 ether);
    currency.mint(otherBidder, 1000 ether);

    // Setup splits
    splitRecipients = new address payable[](1);
    splitRecipients[0] = payable(makeAddr("recipient"));
    splitRatios = new uint8[](1);
    splitRatios[0] = 100;

    // Deal ETH and ERC20
    vm.deal(creator, 10 ether);
    vm.deal(bidder, 10 ether);
    vm.deal(otherBidder, 10 ether);
    currency.mint(bidder, 100 ether);
    currency.mint(otherBidder, 100 ether);
  }

  function testInitialState() public {
    assertEq(auctionHouse.minimumBidIncreasePercentage(), MIN_BID_INCREMENT);
    assertEq(auctionHouse.maxAuctionLength(), MAX_AUCTION_LENGTH);
    assertEq(auctionHouse.auctionLengthExtension(), AUCTION_EXTENSION);
  }

  function testConfigureColdieAuction() public {
    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.configureAuction(
      COLDIE,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      0,
      splitRecipients,
      splitRatios
    );
    vm.stopPrank();

    (address creatorOut, , , , address currencyOut, uint256 minBid, bytes32 auctionType, , ) = auctionHouse
      .getAuctionDetails(address(nft), tokenId);

    assertEq(creatorOut, creator);
    assertEq(currencyOut, address(currency));
    assertEq(minBid, STARTING_BID);
    assertEq(auctionType, COLDIE);
    assertEq(nft.ownerOf(tokenId), creator, "NFT should remain with creator");
  }

  function testConfigureScheduledAuction() public {
    uint256 futureStart = block.timestamp + 1 hours;

    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.configureAuction(
      SCHEDULED,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      futureStart,
      splitRecipients,
      splitRatios
    );
    vm.stopPrank();

    assertEq(nft.ownerOf(tokenId), address(auctionHouse), "NFT should be held by contract");
  }

  function testReconfigureAuctionBeforeStart() public {
    uint256 futureStart = block.timestamp + 1 days;

    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);

    // Configure initial auction
    auctionHouse.configureAuction(
      SCHEDULED,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      futureStart,
      splitRecipients,
      splitRatios
    );

    // Reconfigure before start time
    auctionHouse.configureAuction(
      SCHEDULED,
      address(nft),
      tokenId,
      STARTING_BID + 1 ether,
      address(currency),
      AUCTION_DURATION,
      futureStart + 1 hours,
      splitRecipients,
      splitRatios
    );
    vm.stopPrank();

    (, , uint256 startTime, , , uint256 minBid, , , ) = auctionHouse.getAuctionDetails(address(nft), tokenId);
    assertEq(minBid, STARTING_BID + 1 ether);
    assertEq(startTime, futureStart + 1 hours);
  }

  function testCancelScheduledAuctionBeforeStart() public {
    uint256 startTime = block.timestamp + 1 days;

    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.configureAuction(
      SCHEDULED,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      startTime,
      splitRecipients,
      splitRatios
    );

    auctionHouse.cancelAuction(address(nft), tokenId);
    vm.stopPrank();

    assertEq(nft.ownerOf(tokenId), creator, "NFT should be returned to creator");
  }

  function testCancelColdieAuctionBeforeStart() public {
    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.configureAuction(
      COLDIE,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      0,
      splitRecipients,
      splitRatios
    );

    auctionHouse.cancelAuction(address(nft), tokenId);
    vm.stopPrank();

    assertEq(nft.ownerOf(tokenId), creator, "Token should remain with creator");
  }

  function testCannotCancelAuctionAfterStart() public {
    uint256 startTime = block.timestamp + 1 hours;

    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.configureAuction(
      SCHEDULED,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      startTime,
      splitRecipients,
      splitRatios
    );
    vm.stopPrank();

    vm.warp(startTime + 1);

    vm.prank(creator);
    vm.expectRevert("cancelAuction::Auction must not have started");
    auctionHouse.cancelAuction(address(nft), tokenId);
  }

  function testBidOnColdieAuction() public {
    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.configureAuction(
      COLDIE,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      0,
      splitRecipients,
      splitRatios
    );
    vm.stopPrank();

    vm.startPrank(bidder);
    currency.approve(address(erc20ApprovalManager), STARTING_BID * 2);
    auctionHouse.bid(address(nft), tokenId, address(currency), STARTING_BID);
    vm.stopPrank();

    assertEq(nft.ownerOf(tokenId), address(auctionHouse), "NFT should be held by contract after bid");
  }

  function testBidOnScheduledAuction() public {
    uint256 startTime = block.timestamp + 1 hours;

    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.configureAuction(
      SCHEDULED,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      startTime,
      splitRecipients,
      splitRatios
    );
    vm.stopPrank();

    vm.warp(startTime);

    vm.startPrank(bidder);
    currency.approve(address(erc20ApprovalManager), STARTING_BID * 2);
    auctionHouse.bid(address(nft), tokenId, address(currency), STARTING_BID);
    vm.stopPrank();

    assertEq(nft.ownerOf(tokenId), address(auctionHouse), "NFT should be held by contract");
  }

  function testCannotBidBeforeScheduledStart() public {
    uint256 startTime = block.timestamp + 1 hours;

    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.configureAuction(
      SCHEDULED,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      startTime,
      splitRecipients,
      splitRatios
    );
    vm.stopPrank();

    vm.startPrank(bidder);
    currency.approve(address(erc20ApprovalManager), STARTING_BID * 2);
    vm.expectRevert("bid::Auction not active");
    auctionHouse.bid(address(nft), tokenId, address(currency), STARTING_BID);
    vm.stopPrank();
  }

  function testSettleAuctionWithBid() public {
    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.configureAuction(
      COLDIE,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      0,
      splitRecipients,
      splitRatios
    );
    vm.stopPrank();

    vm.startPrank(bidder);
    currency.approve(address(erc20ApprovalManager), STARTING_BID * 2);
    auctionHouse.bid(address(nft), tokenId, address(currency), STARTING_BID);
    vm.stopPrank();

    vm.warp(block.timestamp + AUCTION_DURATION + 1);

    auctionHouse.settleAuction(address(nft), tokenId);

    assertEq(nft.ownerOf(tokenId), bidder, "NFT should be transferred to winning bidder");
  }

  function testCannotSettleBeforeEnd() public {
    vm.startPrank(creator);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.configureAuction(
      COLDIE,
      address(nft),
      tokenId,
      STARTING_BID,
      address(currency),
      AUCTION_DURATION,
      0,
      splitRecipients,
      splitRatios
    );
    vm.stopPrank();

    vm.startPrank(bidder);
    currency.approve(address(erc20ApprovalManager), STARTING_BID * 2);
    auctionHouse.bid(address(nft), tokenId, address(currency), STARTING_BID);
    vm.stopPrank();

    vm.expectRevert("settleAuction::Auction has not ended");
    auctionHouse.settleAuction(address(nft), tokenId);
  }
}
