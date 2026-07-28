// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {RareAppRegistry} from "../../registry/RareAppRegistry.sol";
import {IRareAppRegistry} from "../../registry/IRareAppRegistry.sol";

contract RareAppRegistryTest is Test {
  RareAppRegistry public registry;

  address public owner;
  address public app1;
  address public feeRecipient1;

  function setUp() public {
    owner = address(0x1);
    app1 = address(0x2);
    feeRecipient1 = address(0x3);

    vm.prank(owner);
    registry = new RareAppRegistry(owner);
  }

  function test_registerApp() public {
    vm.prank(app1);
    registry.registerApp(250, feeRecipient1); // 2.5%

    (bool registered, uint16 feeBp, address feeRecipient) = registry.apps(app1);
    assertTrue(registered);
    assertEq(feeBp, 250);
    assertEq(feeRecipient, feeRecipient1);
  }

  function test_registerApp_revertAlreadyRegistered() public {
    vm.prank(app1);
    registry.registerApp(250, feeRecipient1);

    vm.prank(app1);
    vm.expectRevert("already registered");
    registry.registerApp(500, feeRecipient1);
  }

  function test_registerApp_revertZeroAddress() public {
    vm.prank(app1);
    vm.expectRevert("zero address");
    registry.registerApp(250, address(0));
  }

  function test_updateApp() public {
    vm.prank(app1);
    registry.registerApp(250, feeRecipient1);

    address newRecipient = address(0x4);
    vm.prank(app1);
    registry.updateApp(500, newRecipient);

    (bool registered, uint16 feeBp, address feeRecipient) = registry.apps(app1);
    assertTrue(registered);
    assertEq(feeBp, 500);
    assertEq(feeRecipient, newRecipient);
  }

  function test_updateApp_revertNotRegistered() public {
    vm.prank(app1);
    vm.expectRevert("not registered");
    registry.updateApp(500, feeRecipient1);
  }

  function test_deregisterApp() public {
    vm.prank(app1);
    registry.registerApp(250, feeRecipient1);

    vm.prank(app1);
    registry.deregisterApp();

    (bool registered,,) = registry.apps(app1);
    assertFalse(registered);
  }

  function test_deregisterApp_revertNotRegistered() public {
    vm.prank(app1);
    vm.expectRevert("not registered");
    registry.deregisterApp();
  }

  function test_calculateFeeSplit_zeroApp() public {
    (uint256 appShare, uint256 protocolShare, uint256 totalFee) =
      registry.calculateFeeSplit(address(0), 1000 ether);

    assertEq(appShare, 0);
    assertEq(protocolShare, 0);
    assertEq(totalFee, 0);
  }

  function test_calculateFeeSplit_unregisteredApp() public {
    (uint256 appShare, uint256 protocolShare, uint256 totalFee) =
      registry.calculateFeeSplit(app1, 1000 ether);

    assertEq(appShare, 0);
    assertEq(protocolShare, 0);
    assertEq(totalFee, 0);
  }

  function test_calculateFeeSplit_registeredApp() public {
    vm.prank(app1);
    registry.registerApp(250, feeRecipient1); // 2.5%

    uint256 amount = 1000 ether;
    (uint256 appShare, uint256 protocolShare, uint256 totalFee) =
      registry.calculateFeeSplit(app1, amount);

    uint256 expectedTotalFee = (amount * 250) / 10000; // 25 ether
    assertEq(totalFee, expectedTotalFee);

    uint256 expectedProtocolShare = (expectedTotalFee * 2000) / 10000; // 20% of fee = 5 ether
    assertEq(protocolShare, expectedProtocolShare);

    assertEq(appShare, expectedTotalFee - expectedProtocolShare); // 20 ether
  }

  function test_setProtocolShareBp() public {
    vm.prank(owner);
    registry.setProtocolShareBp(3000);

    assertEq(registry.protocolShareBp(), 3000);
  }

  function test_setProtocolShareBp_revertExceedsMax() public {
    vm.prank(owner);
    vm.expectRevert("exceeds max");
    registry.setProtocolShareBp(10001);
  }

  function test_setProtocolShareBp_revertNotOwner() public {
    vm.prank(app1);
    vm.expectRevert();
    registry.setProtocolShareBp(3000);
  }
}
