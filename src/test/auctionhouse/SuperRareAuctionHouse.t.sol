// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";

import {ISuperRareAuctionHouse, SuperRareAuctionHouse} from "../../auctionhouse/SuperRareAuctionHouse.sol";

contract SuperRareAuctionHouseTest is Test {
    SuperRareAuctionHouse private superRareAuctionHouse;
    
    function setUp() public {
        superRareAuctionHouse = new SuperRareAuctionHouse();
    }

    function testCreateFirstBidRewardAuction() public {
        address payable[] memory splitAddresses;
        uint8[] memory splitRatios;

        address _contractAddress = address(0x1234);
        uint256 _tokenId = 1;

        // Create an auction
        superRareAuctionHouse.configureFirstBidRewardAuction(
            1,
            _contractAddress,
            _tokenId,
            1,
            address(0x1235),
            600,
            10,
            splitAddresses,
            splitRatios
        );
    }
}