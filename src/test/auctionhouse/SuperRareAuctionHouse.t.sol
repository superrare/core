// SPDX-License-Identifier: MIT
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

contract SuperRareAuctionHouseTest is Test {
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

    address private immutable artist = vm.addr(0x321);

    uint256 private constant TARGET_AMOUNT = 249.6 ether;

    uint256 private constant _lengthOfAuction = 1;

    bytes32 private constant SCHEDULED_AUCTION = "SCHEDULED_AUCTION";
    bytes32 private constant COLDIE_AUCTION = "COLDIE_AUCTION";

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

        /*///////////////////////////////////////////////////
                            Mock Calls
        ///////////////////////////////////////////////////*/
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
        abi.encode(3)
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
        approvedTokenRegistry,
        abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(superRareToken)),
        abi.encode(true)
        );
        vm.mockCall(
        marketplaceSettings,
        abi.encodeWithSelector(IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, address(sfn)),
        abi.encode(15)
        );
        vm.mockCall(
        marketplaceSettings,
        abi.encodeWithSelector(IMarketplaceSettings.markERC721Token.selector, address(sfn)),
        abi.encode()
        );

        sfn.mint(artist, 1);
        vm.startPrank(artist);
        sfn.setApprovalForAll(address(superRareBazaar), true);
        vm.stopPrank();
        
    }

    function testCreateFirstBidRewardAuction() public {
        vm.startPrank(artist);

        address payable[] memory _splitAddresses = new address payable[](1);
        _splitAddresses[0] = payable(address(this));

        uint8[] memory _splitRatios = new uint8[](1);
        _splitRatios[0] = 99;

        // Create an auction
        superRareBazaar.configureFirstBidRewardAuction(
            1,
            address(sfn),
            1,
            TARGET_AMOUNT,
            address(0),
            _lengthOfAuction,
            block.timestamp + 1,
            _splitAddresses,
            _splitRatios
        );

        vm.stopPrank();
    }

    function testCreateFirstBidRewardAuctionBadSplits() public {
        vm.startPrank(artist);

        address payable[] memory _splitAddresses = new address payable[](1);
        _splitAddresses[0] = payable(address(this));

        uint8[] memory _splitRatios = new uint8[](1);
        _splitRatios[0] = 100;

        // Create an auction with bad split numbers (in combo with guarnator)
        vm.expectRevert();
        superRareBazaar.configureFirstBidRewardAuction(
            1,
            address(sfn),
            1,
            TARGET_AMOUNT,
            address(0),
            _lengthOfAuction,
            block.timestamp + 1,
            _splitAddresses,
            _splitRatios
        );

        vm.stopPrank();
    }

    function testUpdateAuction() public {
        vm.startPrank(artist);

        address payable[] memory _splitAddresses = new address payable[](1);
        _splitAddresses[0] = payable(address(this));

        uint8[] memory _splitRatios = new uint8[](1);
        _splitRatios[0] = 100;

        // Create an auction with bad split numbers (in combo with guarnator)
        superRareBazaar.configureAuction(
            COLDIE_AUCTION,
            address(sfn),
            1,
            TARGET_AMOUNT,
            address(0),
            _lengthOfAuction,
            block.timestamp + 1,
            _splitAddresses,
            _splitRatios
        );

        // Update the auction
        superRareBazaar.configureAuction(
            COLDIE_AUCTION,
            address(sfn),
            1,
            TARGET_AMOUNT - 10,
            address(0),
            _lengthOfAuction + 1,
            block.timestamp + 2,
            _splitAddresses,
            _splitRatios
        );

        vm.stopPrank();
    }
}