// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";

/// @notice Shared safety checks for scripts that configure the ERC1155 marketplace settlement module.
abstract contract RareERC1155SettlementScriptGuard is Script {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    bytes32 private constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    error SettlementHasNoCode(address _settlement);
    error SettlementCannotBeUpgradeableProxy(address _settlement, bytes32 _slot, bytes32 _value);

    function _validateSettlementModuleForScript(address _settlement) internal view {
        if (_settlement.code.length == 0) revert SettlementHasNoCode(_settlement);
        _revertIfSlotSet(_settlement, ERC1967_IMPLEMENTATION_SLOT);
        _revertIfSlotSet(_settlement, ERC1967_BEACON_SLOT);
        _revertIfSlotSet(_settlement, ERC1967_ADMIN_SLOT);
    }

    function _revertIfSlotSet(address _settlement, bytes32 _slot) private view {
        bytes32 slotValue = vm.load(_settlement, _slot);
        if (slotValue != bytes32(0)) {
            revert SettlementCannotBeUpgradeableProxy(_settlement, _slot, slotValue);
        }
    }
}
