// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IPayments} from "rareprotocol/aux/payments/IPayments.sol";
import {Payments} from "rareprotocol/aux/payments/Payments.sol";
import {IMarketplaceSettings} from "rareprotocol/aux/marketplace/IMarketplaceSettings.sol";
import {IStakingSettings} from "rareprotocol/aux/marketplace/IStakingSettings.sol";
import {ISpaceOperatorRegistry} from "rareprotocol/aux/registry/interfaces/ISpaceOperatorRegistry.sol";
import {IApprovedTokenRegistry} from "rareprotocol/aux/registry/interfaces/IApprovedTokenRegistry.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

import {MarketUtilsV2} from "../../../v2/utils/MarketUtilsV2.sol";
import {MarketConfigV2} from "../../../v2/utils/MarketConfigV2.sol";
import {IRareStakingRegistry} from "../../../staking/registry/IRareStakingRegistry.sol";
import {ERC20ApprovalManager} from "../../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../../v2/approver/ERC721/ERC721ApprovalManager.sol";
import {TestNFT} from "../utils/TestNft.sol";

contract TestContract {
  using MarketUtilsV2 for MarketConfigV2.Config;

  MarketConfigV2.Config config;

  constructor(
    address _marketplaceSettings,
    address _stakingSettings,
    address _royaltyEngine,
    address _spaceOperatorRegistry,
    address _approvedTokenRegistry,
    address _payments,
    address _stakingRegistry,
    address _networkBeneficiary,
    address _erc20ApprovalManager,
    address _erc721ApprovalManager
  ) {
    require(_marketplaceSettings != address(0));
    require(_stakingSettings != address(0));
    require(_royaltyEngine != address(0));
    require(_spaceOperatorRegistry != address(0));
    require(_approvedTokenRegistry != address(0));
    require(_payments != address(0));
    require(_networkBeneficiary != address(0));
    require(_erc20ApprovalManager != address(0));
    require(_erc721ApprovalManager != address(0));
    config = MarketConfigV2.generateMarketConfig(
      _networkBeneficiary,
      _marketplaceSettings,
      _spaceOperatorRegistry,
      _royaltyEngine,
      _payments,
      _approvedTokenRegistry,
      _stakingSettings,
      _stakingRegistry,
      _erc20ApprovalManager,
      _erc721ApprovalManager
    );
  }

  function checkIfCurrencyIsApproved(address _currencyAddress) public view {
    config.checkIfCurrencyIsApproved(_currencyAddress);
  }

  function senderMustBeTokenOwner(address _originContract, uint256 _tokenId) public view {
    MarketUtilsV2.senderMustBeTokenOwner(_originContract, _tokenId);
  }

  function addressMustHaveMarketplaceApprovedForNFT(
    address _addr,
    address _originContract,
    uint256 _tokenId
  ) public view {
    config.addressMustHaveMarketplaceApprovedForNFT(_addr, _originContract, _tokenId);
  }

  function checkSplits(address payable[] calldata _splitAddrs, uint8[] calldata _splitRatios) public pure {
    MarketUtilsV2.checkSplits(_splitAddrs, _splitRatios);
  }

  function senderMustHaveMarketplaceApproved(address _currency, uint256 _amount) public view {
    config.senderMustHaveMarketplaceApproved(_currency, _amount);
  }

  function checkAmountAndTransfer(address _currencyAddress, uint256 _amount) public payable {
    config.checkAmountAndTransfer(_currencyAddress, _amount);
  }

  function refund(address _currencyAddress, uint256 _amount, uint256 _marketplaceFee, address _recipient) public {
    config.refund(_currencyAddress, _amount, _marketplaceFee, _recipient);
  }

  function payout(
    address _originContract,
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _amount,
    address _seller,
    address payable[] memory _splitAddrs,
    uint8[] memory _splitRatios
  ) public payable {
    config.payout(_originContract, _tokenId, _currencyAddress, _amount, _seller, _splitAddrs, _splitRatios);
  }

  function transferERC721(address _originContract, address _from, address _to, uint256 _tokenId) public {
    config.transferERC721(_originContract, _from, _to, _tokenId);
  }
}

contract TestRare is ERC20 {
  constructor() ERC20("Rare", "RARE") {
    _mint(msg.sender, 1_000_000_000 ether);
  }

  function burn(uint256 amount) public {
    _burn(msg.sender, amount);
  }
}

contract MarketUtilsV2Test is Test {
  TestContract tc;
  Payments payments;
  TestRare public rare;
  TestNFT public nft;
  ERC20ApprovalManager public erc20ApprovalManager;
  ERC721ApprovalManager public erc721ApprovalManager;
  uint256 constant initialRare = 1000 * 1e18;

  address deployer = address(0xabadabab);
  address alice = address(0xbeef);
  address bob = address(0xcafe);
  address charlie = address(0xdead);
  address stakingSettings = address(0xabadaba0);
  address marketplaceSettings = address(0xabadaba1);
  address royaltyRegistry = address(0xabadaba2);
  address royaltyEngine = address(0xabadaba3);
  address spaceOperatorRegistry = address(0xabadaba6);
  address approvedTokenRegistry = address(0xabadaba7);
  address stakingRegistry = address(0xabadaba9);
  address networkBeneficiary = address(0xabadabaa);
  address rewardPool = address(0xcccc);

  function contractDeploy() internal {
    vm.startPrank(deployer);

    // Deploy TestRare
    rare = new TestRare();

    // Deploy TestNFT
    nft = new TestNFT();

    // Deploy Payments
    payments = new Payments();

    // Deploy actual approval managers
    erc20ApprovalManager = new ERC20ApprovalManager();
    erc721ApprovalManager = new ERC721ApprovalManager();

    tc = new TestContract(
      marketplaceSettings,
      stakingSettings,
      royaltyEngine,
      spaceOperatorRegistry,
      approvedTokenRegistry,
      address(payments),
      stakingRegistry,
      networkBeneficiary,
      address(erc20ApprovalManager),
      address(erc721ApprovalManager)
    );

    // Setup operator role after test contract is created
    erc20ApprovalManager.grantRole(erc20ApprovalManager.OPERATOR_ROLE(), address(tc));
    erc721ApprovalManager.grantRole(erc721ApprovalManager.OPERATOR_ROLE(), address(tc));

    // etch code into these so we can stub out methods
    vm.etch(marketplaceSettings, address(rare).code);
    vm.etch(stakingSettings, address(rare).code);
    vm.etch(stakingRegistry, address(rare).code);
    vm.etch(royaltyRegistry, address(rare).code);
    vm.etch(royaltyEngine, address(rare).code);
    vm.etch(spaceOperatorRegistry, address(rare).code);
    vm.etch(approvedTokenRegistry, address(rare).code);

    vm.stopPrank();
  }

  function setUp() public {
    deal(deployer, 100 ether);
    deal(alice, 100 ether);
    deal(bob, 100 ether);
    deal(charlie, 100 ether);
    contractDeploy();
    vm.startPrank(deployer);
    rare.transfer(alice, initialRare);
    rare.transfer(bob, initialRare);
    vm.stopPrank();
  }

  function test_checkIfCurrencyIsApproved_ETH() public {
    // ETH (address(0)) should always be approved
    tc.checkIfCurrencyIsApproved(address(0));
  }

  function test_checkIfCurrencyIsApproved_ApprovedERC20() public {
    // Mock approved token check
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(rare)),
      abi.encode(true)
    );

    tc.checkIfCurrencyIsApproved(address(rare));
  }

  function test_checkIfCurrencyIsApproved_UnapprovedERC20() public {
    // Mock unapproved token check
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(rare)),
      abi.encode(false)
    );

    vm.expectRevert("Not approved currency");
    tc.checkIfCurrencyIsApproved(address(rare));
  }

  function test_senderMustBeTokenOwner_Success() public {
    address nftContract = address(0x1234);
    uint256 tokenId = 1;

    // Mock NFT ownership
    vm.mockCall(nftContract, abi.encodeWithSelector(IERC721.ownerOf.selector, tokenId), abi.encode(address(this)));

    vm.prank(address(this));
    tc.senderMustBeTokenOwner(nftContract, tokenId);
  }

  function test_senderMustBeTokenOwner_Failure() public {
    address nftContract = address(0x1234);
    uint256 tokenId = 1;

    // Mock NFT ownership to different address
    vm.mockCall(nftContract, abi.encodeWithSelector(IERC721.ownerOf.selector, tokenId), abi.encode(address(0x5678)));

    vm.expectRevert("sender must be the token owner");
    tc.senderMustBeTokenOwner(nftContract, tokenId);
  }

  function test_addressMustHaveMarketplaceApprovedForNFT_Success() public {
    // Mint NFT to alice
    vm.prank(deployer);
    uint256 tokenId = nft.mint(alice);

    // Have alice approve the marketplace
    vm.prank(alice);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);

    tc.addressMustHaveMarketplaceApprovedForNFT(alice, address(nft), tokenId);
  }

  function test_addressMustHaveMarketplaceApprovedForNFT_SpecificTokenSuccess() public {
    // Mint NFT to alice
    vm.prank(deployer);
    uint256 tokenId = nft.mint(alice);

    // Have alice approve the marketplace
    vm.prank(alice);
    nft.setApprovalForAll(address(erc721ApprovalManager), true);

    tc.addressMustHaveMarketplaceApprovedForNFT(alice, address(nft), tokenId);
  }

  function test_addressMustHaveMarketplaceApprovedForNFT_Failure() public {
    // Mint NFT to alice
    vm.prank(deployer);
    uint256 tokenId = nft.mint(alice);

    // Don't approve the marketplace - this should fail
    vm.expectRevert("owner must have approved token");
    tc.addressMustHaveMarketplaceApprovedForNFT(alice, address(nft), tokenId);
  }

  function test_checkSplits_Success() public {
    address payable[] memory splitAddrs = new address payable[](2);
    uint8[] memory splitRatios = new uint8[](2);

    splitAddrs[0] = payable(alice);
    splitAddrs[1] = payable(bob);
    splitRatios[0] = 60;
    splitRatios[1] = 40;

    tc.checkSplits(splitAddrs, splitRatios);
  }

  function test_checkSplits_EmptyArrays() public {
    address payable[] memory splitAddrs = new address payable[](0);
    uint8[] memory splitRatios = new uint8[](0);

    vm.expectRevert("checkSplits::Must have at least 1 split");
    tc.checkSplits(splitAddrs, splitRatios);
  }

  function test_checkSplits_TooManySplits() public {
    address payable[] memory splitAddrs = new address payable[](6);
    uint8[] memory splitRatios = new uint8[](6);

    vm.expectRevert("checkSplits::Split exceeded max size");
    tc.checkSplits(splitAddrs, splitRatios);
  }

  function test_checkSplits_UnequalArrays() public {
    address payable[] memory splitAddrs = new address payable[](2);
    uint8[] memory splitRatios = new uint8[](3);

    vm.expectRevert("checkSplits::Splits and ratios must be equal");
    tc.checkSplits(splitAddrs, splitRatios);
  }

  function test_checkSplits_InvalidTotal() public {
    address payable[] memory splitAddrs = new address payable[](2);
    uint8[] memory splitRatios = new uint8[](2);

    splitAddrs[0] = payable(alice);
    splitAddrs[1] = payable(bob);
    splitRatios[0] = 60;
    splitRatios[1] = 30;

    vm.expectRevert("checkSplits::Total must be equal to 100");
    tc.checkSplits(splitAddrs, splitRatios);
  }

  function test_senderMustHaveMarketplaceApproved_ETH() public {
    // ETH doesn't need approval
    tc.senderMustHaveMarketplaceApproved(address(0), 1 ether);
  }

  function test_senderMustHaveMarketplaceApproved_ERC20Success() public {
    uint256 amount = 1 ether;

    // Transfer RARE tokens to this contract
    vm.prank(deployer);
    rare.transfer(address(this), amount);

    // Approve the ERC20ApprovalManager to spend tokens
    rare.approve(address(erc20ApprovalManager), amount);

    tc.senderMustHaveMarketplaceApproved(address(rare), amount);
  }

  function test_senderMustHaveMarketplaceApproved_ERC20Failure() public {
    uint256 amount = 1 ether;

    // Transfer RARE tokens to this contract
    vm.prank(deployer);
    rare.transfer(address(this), amount);

    // Approve less than the required amount
    rare.approve(address(erc20ApprovalManager), amount - 1);

    vm.expectRevert("sender needs to approve ERC20ApprovalManager for currency");
    tc.senderMustHaveMarketplaceApproved(address(rare), amount);
  }

  function test_checkAmountAndTransfer_ETHSuccess() public {
    uint256 amount = 1 ether;

    vm.deal(address(this), amount);
    tc.checkAmountAndTransfer{value: amount}(address(0), amount);
  }

  function test_checkAmountAndTransfer_ETHFailure() public {
    uint256 amount = 1 ether;

    vm.deal(address(this), amount - 0.1 ether);
    vm.expectRevert("not enough eth sent");
    tc.checkAmountAndTransfer{value: amount - 0.1 ether}(address(0), amount);
  }

  function test_checkAmountAndTransfer_ERC20Success() public {
    uint256 amount = 1 ether;

    // Transfer RARE tokens to the test contract
    vm.startPrank(deployer);
    rare.transfer(address(this), amount);
    vm.stopPrank();

    // Approve the ERC20ApprovalManager to spend tokens
    vm.prank(address(this));
    rare.approve(address(erc20ApprovalManager), amount);

    tc.checkAmountAndTransfer(address(rare), amount);
  }

  function test_refund_ETH() public {
    uint256 amount = 1 ether;
    uint256 marketplaceFee = 3;
    uint256 totalAmount = amount + ((amount * marketplaceFee) / 100);

    // Fund the test contract first
    vm.deal(address(tc), totalAmount);

    tc.refund(address(0), amount, marketplaceFee, alice);
  }

  function test_refund_ERC20() public {
    uint256 amount = 1 ether;
    uint256 marketplaceFee = 3;
    uint256 totalAmount = amount + ((amount * marketplaceFee) / 100);

    vm.mockCall(address(rare), abi.encodeWithSelector(IERC20.transfer.selector, alice, totalAmount), abi.encode(true));

    deal(address(rare), address(tc), totalAmount);
    tc.refund(address(rare), amount, marketplaceFee, alice);
  }

  function test_payout_primary() public {
    address originContract = address(0xaaaa);
    uint256 tokenId = 1;
    address currencyAddress = address(0);
    uint256 amount = 1 ether;
    address payable[] memory splitAddrs = new address payable[](1);
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;
    splitAddrs[0] = payable(charlie);

    // setup getRewardAccumulatorAddressForUser call
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, charlie),
      abi.encode(address(0))
    );

    // setup calculateMarketplacePayoutFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup calculateStakingFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, amount),
      abi.encode(0)
    );

    // setup calculateMarketplaceFee call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup getMarketplaceFeePercentage call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(3)
    );

    // setup hasERC721TokenSold
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, originContract, 1),
      abi.encode(false)
    );

    // setup isApprovedSpaceOperator
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, charlie),
      abi.encode(false)
    );

    // setup getERC721ContractPrimarySaleFeePercentage
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, originContract),
      abi.encode(15)
    );

    // Mock royalty engine to return empty arrays for primary sale
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, originContract, tokenId, amount),
      abi.encode(new address payable[](0), new uint256[](0))
    );

    uint256 balanceBefore = charlie.balance;
    vm.prank(deployer);
    tc.payout{value: amount + ((amount * 3) / 100)}(
      originContract,
      tokenId,
      currencyAddress,
      amount,
      charlie,
      splitAddrs,
      splitRatios
    );
    uint256 balanceAfter = charlie.balance;
    uint256 expectedBalance = balanceBefore + ((amount * 85) / 100);
    assertEq(balanceAfter, expectedBalance, "incorrect balance after payout");
  }

  function test_payout_secondary() public {
    address originContract = address(0xaaaa);
    uint256 tokenId = 1;
    address currencyAddress = address(0);
    uint256 amount = 1 ether;
    address payable[] memory splitAddrs = new address payable[](1);
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;
    splitAddrs[0] = payable(charlie);
    address payable[] memory royaltyReceiverAddrs = new address payable[](1);
    uint256[] memory royaltyAmounts = new uint256[](1);
    royaltyReceiverAddrs[0] = payable(alice);
    royaltyAmounts[0] = (amount * 10) / 100;

    // setup getRewardAccumulatorAddressForUser call
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, charlie),
      abi.encode(address(0))
    );

    // setup calculateMarketplacePayoutFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup calculateStakingFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, amount),
      abi.encode(0)
    );

    // setup calculateMarketplaceFee call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup getMarketplaceFeePercentage call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(3)
    );

    // setup hasERC721TokenSold -- true for secondary sale
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, originContract, 1),
      abi.encode(true)
    );

    // setup getRoyalty
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, originContract, tokenId, amount),
      abi.encode(royaltyReceiverAddrs, royaltyAmounts)
    );

    uint256 balanceBefore = charlie.balance;
    uint256 aliceBalanceBefore = alice.balance;
    vm.prank(deployer);
    tc.payout{value: amount + ((amount * 3) / 100)}(
      originContract,
      tokenId,
      currencyAddress,
      amount,
      charlie,
      splitAddrs,
      splitRatios
    );
    uint256 balanceAfter = charlie.balance;
    uint256 aliceBalanceAfter = alice.balance;

    // Seller should receive 90% (100% - 10% royalty)
    uint256 expectedBalance = balanceBefore + ((amount * 90) / 100);
    // Royalty receiver should receive 10%
    uint256 aliceExpectedBalance = aliceBalanceBefore + ((amount * 10) / 100);

    assertEq(balanceAfter, expectedBalance, "incorrect seller balance after payout");
    assertEq(aliceBalanceAfter, aliceExpectedBalance, "incorrect royalty receiver balance after payout");
  }

  function test_payout_primary_spaceOperator() public {
    address originContract = address(0xaaaa);
    uint256 tokenId = 1;
    address currencyAddress = address(0);
    uint256 amount = 1 ether;
    address payable[] memory splitAddrs = new address payable[](1);
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;
    splitAddrs[0] = payable(charlie);

    // setup getRewardAccumulatorAddressForUser call
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, charlie),
      abi.encode(address(0))
    );

    // setup calculateMarketplacePayoutFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup calculateStakingFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, amount),
      abi.encode(0)
    );

    // setup calculateMarketplaceFee call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup getMarketplaceFeePercentage call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(3)
    );

    // setup hasERC721TokenSold
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, originContract, 1),
      abi.encode(false)
    );

    // setup isApprovedSpaceOperator -- true
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, charlie),
      abi.encode(true)
    );

    // setup getPlatformCommission -- 5%
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.getPlatformCommission.selector, charlie),
      abi.encode(5)
    );

    // Mock royalty engine to return empty arrays for primary sale with space operator
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, originContract, tokenId, amount),
      abi.encode(new address payable[](0), new uint256[](0))
    );

    uint256 balanceBefore = charlie.balance;
    vm.prank(deployer);
    tc.payout{value: amount + ((amount * 3) / 100)}(
      originContract,
      tokenId,
      currencyAddress,
      amount,
      charlie,
      splitAddrs,
      splitRatios
    );
    uint256 balanceAfter = charlie.balance;

    // Space operator should receive 95% (100% - 5% platform commission)
    uint256 expectedBalance = balanceBefore + ((amount * 95) / 100);
    assertEq(balanceAfter, expectedBalance, "incorrect balance after payout for space operator");
  }

  function test_payout_multipleRoyaltyReceivers() public {
    address originContract = address(0xaaaa);
    uint256 tokenId = 1;
    address currencyAddress = address(0);
    uint256 amount = 1 ether;
    address payable[] memory splitAddrs = new address payable[](1);
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;
    splitAddrs[0] = payable(charlie);

    // Setup multiple royalty receivers
    address payable[] memory royaltyReceiverAddrs = new address payable[](2);
    uint256[] memory royaltyAmounts = new uint256[](2);
    royaltyReceiverAddrs[0] = payable(alice);
    royaltyReceiverAddrs[1] = payable(bob);
    royaltyAmounts[0] = (amount * 5) / 100; // 5%
    royaltyAmounts[1] = (amount * 5) / 100; // 5%

    // setup getRewardAccumulatorAddressForUser call
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, charlie),
      abi.encode(address(0))
    );

    // setup calculateMarketplacePayoutFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup calculateStakingFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, amount),
      abi.encode(0)
    );

    // setup calculateMarketplaceFee call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup getMarketplaceFeePercentage call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(3)
    );

    // setup hasERC721TokenSold -- true for secondary sale
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, originContract, 1),
      abi.encode(true)
    );

    // setup getRoyalty with multiple receivers
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, originContract, tokenId, amount),
      abi.encode(royaltyReceiverAddrs, royaltyAmounts)
    );

    uint256 balanceBefore = charlie.balance;
    uint256 aliceBalanceBefore = alice.balance;
    uint256 bobBalanceBefore = bob.balance;

    vm.prank(deployer);
    tc.payout{value: amount + ((amount * 3) / 100)}(
      originContract,
      tokenId,
      currencyAddress,
      amount,
      charlie,
      splitAddrs,
      splitRatios
    );

    uint256 balanceAfter = charlie.balance;
    uint256 aliceBalanceAfter = alice.balance;
    uint256 bobBalanceAfter = bob.balance;

    // Seller should receive 90% (100% - 10% total royalties)
    uint256 expectedBalance = balanceBefore + ((amount * 90) / 100);
    // Each royalty receiver should receive 5%
    uint256 aliceExpectedBalance = aliceBalanceBefore + ((amount * 5) / 100);
    uint256 bobExpectedBalance = bobBalanceBefore + ((amount * 5) / 100);

    assertEq(balanceAfter, expectedBalance, "incorrect seller balance after payout");
    assertEq(aliceBalanceAfter, aliceExpectedBalance, "incorrect first royalty receiver balance after payout");
    assertEq(bobBalanceAfter, bobExpectedBalance, "incorrect second royalty receiver balance after payout");
  }

  function test_payout_multipleSplits() public {
    address originContract = address(0xaaaa);
    uint256 tokenId = 1;
    address currencyAddress = address(0);
    uint256 amount = 1 ether;

    // Setup multiple splits
    address payable[] memory splitAddrs = new address payable[](2);
    uint8[] memory splitRatios = new uint8[](2);
    splitAddrs[0] = payable(charlie);
    splitAddrs[1] = payable(bob);
    splitRatios[0] = 60; // 60%
    splitRatios[1] = 40; // 40%

    // setup getRewardAccumulatorAddressForUser call
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, charlie),
      abi.encode(address(0))
    );

    // setup calculateMarketplacePayoutFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup calculateStakingFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, amount),
      abi.encode(0)
    );

    // setup calculateMarketplaceFee call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup getMarketplaceFeePercentage call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(3)
    );

    // setup hasERC721TokenSold
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, originContract, 1),
      abi.encode(false)
    );

    // setup isApprovedSpaceOperator
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, charlie),
      abi.encode(false)
    );

    // setup getERC721ContractPrimarySaleFeePercentage
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, originContract),
      abi.encode(15)
    );

    // Mock royalty engine to return empty arrays for primary sale with splits
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, originContract, tokenId, amount),
      abi.encode(new address payable[](0), new uint256[](0))
    );

    uint256 charlieBalanceBefore = charlie.balance;
    uint256 bobBalanceBefore = bob.balance;

    vm.prank(deployer);
    tc.payout{value: amount + ((amount * 3) / 100)}(
      originContract,
      tokenId,
      currencyAddress,
      amount,
      charlie,
      splitAddrs,
      splitRatios
    );

    uint256 charlieBalanceAfter = charlie.balance;
    uint256 bobBalanceAfter = bob.balance;

    // Calculate expected balances after 15% platform fee and split ratios
    uint256 remainingAmount = (amount * 85) / 100; // After 15% platform fee
    uint256 charlieExpectedBalance = charlieBalanceBefore + ((remainingAmount * 60) / 100);
    uint256 bobExpectedBalance = bobBalanceBefore + ((remainingAmount * 40) / 100);

    assertEq(charlieBalanceAfter, charlieExpectedBalance, "incorrect first split receiver balance after payout");
    assertEq(bobBalanceAfter, bobExpectedBalance, "incorrect second split receiver balance after payout");
  }

  function test_payout_tooManyRoyaltyRecipients() public {
    address originContract = address(0xaaaa);
    uint256 tokenId = 1;
    address currencyAddress = address(0);
    uint256 amount = 1 ether;
    address payable[] memory splitAddrs = new address payable[](1);
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;
    splitAddrs[0] = payable(charlie);

    // Setup TOO MANY royalty receivers (6, when max is 5)
    address payable[] memory royaltyReceiverAddrs = new address payable[](6);
    uint256[] memory royaltyAmounts = new uint256[](6);

    // Fill with different addresses
    royaltyReceiverAddrs[0] = payable(alice);
    royaltyReceiverAddrs[1] = payable(bob);
    royaltyReceiverAddrs[2] = payable(charlie);
    royaltyReceiverAddrs[3] = payable(address(0x1111));
    royaltyReceiverAddrs[4] = payable(address(0x2222));
    royaltyReceiverAddrs[5] = payable(address(0x3333));

    // Each gets 1% royalty
    for (uint256 i = 0; i < 6; i++) {
      royaltyAmounts[i] = (amount * 1) / 100;
    }

    // setup getRewardAccumulatorAddressForUser call
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, charlie),
      abi.encode(address(0))
    );

    // setup calculateMarketplacePayoutFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup calculateStakingFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, amount),
      abi.encode(0)
    );

    // setup calculateMarketplaceFee call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup getMarketplaceFeePercentage call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(3)
    );

    // setup hasERC721TokenSold -- true for secondary sale
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, originContract, 1),
      abi.encode(true)
    );

    // setup getRoyalty with TOO MANY receivers (6)
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, originContract, tokenId, amount),
      abi.encode(royaltyReceiverAddrs, royaltyAmounts)
    );

    // Should revert with TooManyRoyaltyRecipients error
    vm.prank(deployer);
    vm.expectRevert(MarketUtilsV2.TooManyRoyaltyRecipients.selector);
    tc.payout{value: amount + ((amount * 3) / 100)}(
      originContract,
      tokenId,
      currencyAddress,
      amount,
      charlie,
      splitAddrs,
      splitRatios
    );
  }

  function test_payout_exactlyMaxRoyaltyRecipients() public {
    address originContract = address(0xaaaa);
    uint256 tokenId = 1;
    address currencyAddress = address(0);
    uint256 amount = 1 ether;
    address payable[] memory splitAddrs = new address payable[](1);
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;
    splitAddrs[0] = payable(charlie);

    // Setup EXACTLY the maximum royalty receivers (5)
    address payable[] memory royaltyReceiverAddrs = new address payable[](5);
    uint256[] memory royaltyAmounts = new uint256[](5);

    // Fill with different addresses
    royaltyReceiverAddrs[0] = payable(alice);
    royaltyReceiverAddrs[1] = payable(bob);
    royaltyReceiverAddrs[2] = payable(address(0x1111));
    royaltyReceiverAddrs[3] = payable(address(0x2222));
    royaltyReceiverAddrs[4] = payable(address(0x3333));

    // Each gets 2% royalty (10% total)
    for (uint256 i = 0; i < 5; i++) {
      royaltyAmounts[i] = (amount * 2) / 100;
    }

    // setup getRewardAccumulatorAddressForUser call
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, charlie),
      abi.encode(address(0))
    );

    // setup calculateMarketplacePayoutFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup calculateStakingFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, amount),
      abi.encode(0)
    );

    // setup calculateMarketplaceFee call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup getMarketplaceFeePercentage call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(3)
    );

    // setup hasERC721TokenSold -- true for secondary sale
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, originContract, 1),
      abi.encode(true)
    );

    // setup getRoyalty with exactly max receivers (5)
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, originContract, tokenId, amount),
      abi.encode(royaltyReceiverAddrs, royaltyAmounts)
    );

    uint256 charlieBalanceBefore = charlie.balance;
    uint256 aliceBalanceBefore = alice.balance;
    uint256 bobBalanceBefore = bob.balance;

    // Should NOT revert with exactly 5 recipients
    vm.prank(deployer);
    tc.payout{value: amount + ((amount * 3) / 100)}(
      originContract,
      tokenId,
      currencyAddress,
      amount,
      charlie,
      splitAddrs,
      splitRatios
    );

    uint256 charlieBalanceAfter = charlie.balance;
    uint256 aliceBalanceAfter = alice.balance;
    uint256 bobBalanceAfter = bob.balance;

    // Seller should receive 90% (100% - 10% total royalties)
    uint256 expectedBalance = charlieBalanceBefore + ((amount * 90) / 100);
    // First two royalty receivers should each receive 2%
    uint256 aliceExpectedBalance = aliceBalanceBefore + ((amount * 2) / 100);
    uint256 bobExpectedBalance = bobBalanceBefore + ((amount * 2) / 100);

    assertEq(charlieBalanceAfter, expectedBalance, "incorrect seller balance after payout");
    assertEq(aliceBalanceAfter, aliceExpectedBalance, "incorrect first royalty receiver balance after payout");
    assertEq(bobBalanceAfter, bobExpectedBalance, "incorrect second royalty receiver balance after payout");
  }

  function test_transferERC721_Success() public {
    // Mint NFT to alice
    vm.prank(deployer);
    uint256 tokenId = nft.mint(alice);

    // Have alice approve the marketplace
    vm.prank(alice);
    nft.approve(address(erc721ApprovalManager), tokenId);

    // Transfer NFT from alice to bob
    tc.transferERC721(address(nft), alice, bob, tokenId);

    // Verify the transfer happened
    assertEq(nft.ownerOf(tokenId), bob, "NFT was not transferred to bob");
  }

  function test_payout_primary_noRoyalties() public {
    address originContract = address(0xaaaa);
    uint256 tokenId = 1;
    address currencyAddress = address(0);
    uint256 amount = 1 ether;
    address payable[] memory splitAddrs = new address payable[](1);
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;
    splitAddrs[0] = payable(charlie);

    // setup getRewardAccumulatorAddressForUser call
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, charlie),
      abi.encode(address(0))
    );

    // setup calculateMarketplacePayoutFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup calculateStakingFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, amount),
      abi.encode(0)
    );

    // setup calculateMarketplaceFee call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup getMarketplaceFeePercentage call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(3)
    );

    // setup hasERC721TokenSold -- false for primary sale
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, originContract, 1),
      abi.encode(false)
    );

    // setup isApprovedSpaceOperator
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, charlie),
      abi.encode(false)
    );

    // setup getERC721ContractPrimarySaleFeePercentage
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, originContract),
      abi.encode(15)
    );

    // Mock royalty engine to return non-empty arrays to verify they are ignored
    address payable[] memory royaltyReceiverAddrs = new address payable[](1);
    uint256[] memory royaltyAmounts = new uint256[](1);
    royaltyReceiverAddrs[0] = payable(alice);
    royaltyAmounts[0] = (amount * 10) / 100;

    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, originContract, tokenId, amount),
      abi.encode(royaltyReceiverAddrs, royaltyAmounts)
    );

    uint256 charlieBalanceBefore = charlie.balance;
    uint256 aliceBalanceBefore = alice.balance;

    vm.prank(deployer);
    tc.payout{value: amount + ((amount * 3) / 100)}(
      originContract,
      tokenId,
      currencyAddress,
      amount,
      charlie,
      splitAddrs,
      splitRatios
    );

    uint256 charlieBalanceAfter = charlie.balance;
    uint256 aliceBalanceAfter = alice.balance;

    // Seller should receive 85% (100% - 15% primary fee)
    uint256 expectedBalance = charlieBalanceBefore + ((amount * 85) / 100);
    // Royalty receiver should receive nothing
    uint256 aliceExpectedBalance = aliceBalanceBefore;

    assertEq(charlieBalanceAfter, expectedBalance, "incorrect seller balance after primary sale");
    assertEq(aliceBalanceAfter, aliceExpectedBalance, "royalty receiver should not receive anything in primary sale");
  }

  function test_payout_secondary_noPrimaryFees() public {
    address originContract = address(0xaaaa);
    uint256 tokenId = 1;
    address currencyAddress = address(0);
    uint256 amount = 1 ether;
    address payable[] memory splitAddrs = new address payable[](1);
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;
    splitAddrs[0] = payable(charlie);

    // setup getRewardAccumulatorAddressForUser call
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, charlie),
      abi.encode(address(0))
    );

    // setup calculateMarketplacePayoutFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup calculateStakingFee call
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, amount),
      abi.encode(0)
    );

    // setup calculateMarketplaceFee call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, amount),
      abi.encode((amount * 3) / 100)
    );

    // setup getMarketplaceFeePercentage call
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(3)
    );

    // setup hasERC721TokenSold -- true for secondary sale
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, originContract, 1),
      abi.encode(true)
    );

    // setup isApprovedSpaceOperator
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, charlie),
      abi.encode(false)
    );

    // setup getERC721ContractPrimarySaleFeePercentage - should be ignored
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, originContract),
      abi.encode(15)
    );

    // Mock royalty engine to return empty arrays to verify primary fees aren't paid
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, originContract, tokenId, amount),
      abi.encode(new address payable[](0), new uint256[](0))
    );

    uint256 charlieBalanceBefore = charlie.balance;

    vm.prank(deployer);
    tc.payout{value: amount + ((amount * 3) / 100)}(
      originContract,
      tokenId,
      currencyAddress,
      amount,
      charlie,
      splitAddrs,
      splitRatios
    );

    uint256 charlieBalanceAfter = charlie.balance;

    // Seller should receive 100% (no primary fees in secondary sale)
    uint256 expectedBalance = charlieBalanceBefore + amount;

    assertEq(
      charlieBalanceAfter,
      expectedBalance,
      "incorrect seller balance after secondary sale - primary fees should not be taken"
    );
  }
}
