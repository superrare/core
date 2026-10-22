// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
// solhint-disable no-console

import "forge-std/Script.sol";

import "../../src/credits/CreditPackSale.sol";

/// @title CreditPackSaleDeploy
/// @notice Deployment script for the credit pack sale contract
contract CreditPackSaleDeploy is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    address currencyAddress = vm.envAddress("CREDIT_PACK_CURRENCY_ADDRESS");
    require(currencyAddress.code.length > 0, "CREDIT_PACK_CURRENCY_ADDRESS has no code");
    address feeRecipient = vm.envAddress("CREDIT_PACK_FEE_RECIPIENT");
    uint256 defaultFeeBpsInput = vm.envUint("CREDIT_PACK_DEFAULT_FEE_BPS");
    require(defaultFeeBpsInput <= type(uint16).max, "CREDIT_PACK_DEFAULT_FEE_BPS out of range");
    uint16 defaultFeeBps = uint16(defaultFeeBpsInput);

    address ownerAddress = vm.envAddress("CREDIT_PACK_OWNER");

    CreditPackSale sale = new CreditPackSale(currencyAddress, feeRecipient, defaultFeeBps);
    if (ownerAddress != deployer) {
      sale.transferOwnership(ownerAddress);
    }

    console.log("Deployer:", deployer);
    console.log("Owner:", sale.owner());
    console.log("PendingOwner:", sale.pendingOwner());
    console.log("Currency:", currencyAddress);
    console.log("FeeRecipient:", feeRecipient);
    console.log("DefaultFeeBps:", defaultFeeBps);
    console.log("CreditPackSale deployed at:", address(sale));

    vm.stopBroadcast();
  }
}
