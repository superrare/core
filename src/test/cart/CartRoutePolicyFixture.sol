// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";
import {CartRoutePolicy} from "../../cart/CartRoutePolicy.sol";

/// @notice Deploys the policy for independent command-policy test suites.
abstract contract CartRoutePolicyFixture is Test {
    CartRoutePolicy internal policy;

    function setUp() public {
        policy = new CartRoutePolicy();
    }

}
