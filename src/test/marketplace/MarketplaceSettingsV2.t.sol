// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import {MarketplaceSettingsV2} from "../../marketplace/MarketplaceSettingsV2.sol";
import {MarketplaceSettingsV1} from "../../marketplace/MarketplaceSettingsV1.sol";

contract MarketplaceSettingsV2Test is Test {
    MarketplaceSettingsV2 public marketplaceV2;
    MarketplaceSettingsV1 public marketplaceV1;

    function setUp() public {
        marketplaceV1 = new MarketplaceSettingsV1();
        marketplaceV2 = new MarketplaceSettingsV2(
            address(this),
            address(marketplaceV1)
        );

        marketplaceV1.grantMarketplaceAccess(address(marketplaceV2));
    }

    function test_default_fees_are_zero() public {
        assertEq(marketplaceV2.getMarketplaceFeePercentage(), 0);
        assertEq(marketplaceV2.getERC721ContractPrimarySaleFeePercentage(address(0x1234)), 0);
    }

    function testMarkTokenSold() public {
        address _contractAddress = address(0x1234);
        uint256 _tokenId = 1;
        bool _hasSold = true;

        marketplaceV2.markERC721Token(_contractAddress, _tokenId, _hasSold);
        assertTrue(
            marketplaceV2.hasERC721TokenSold(_contractAddress, _tokenId)
        );
    }

    function testMarkContractAsSold() public {
        address _contractAddress = address(0x1234);
        uint256 _tokenId = 1;

        assertTrue(marketplaceV2.markContractAsSold(_contractAddress));
        assertTrue(
            marketplaceV2.hasERC721TokenSold(_contractAddress, _tokenId)
        );
    }

    function test_RevertWhen_MarkTokenAsNotAdmin() public {
        address _contractAddress = address(0x1234);
        uint256 _tokenId = 1;
        bool _hasSold = true;

        vm.prank(address(0));
        vm.expectRevert();
        marketplaceV2.markERC721Token(_contractAddress, _tokenId, _hasSold);
    }
}
