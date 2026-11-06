// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/// @title Cart Route Policy
/// @notice Default-deny validation for the Universal Router swap commands used by Cart.
interface ICartRoutePolicy {
    error CommandFlagsNotAllowed(uint256 commandIndex, bytes1 command);
    error CommandNotAllowed(uint256 commandIndex, bytes1 command);
    error CommandInputLengthMismatch(uint256 commands, uint256 inputs);
    error EmptyRoute();
    /// @notice Execution left additional funds in the shared router.
    error RouterBalanceIncreased(address asset, uint256 beforeBalance, uint256 afterBalance);

    /// @notice A command uses an unsupported recipient.
    error InvalidRouteRecipient(uint256 commandIndex, address recipient);
    /// @notice A path or V4 action sequence does not match a supported route form.
    error InvalidRouteInput(uint256 commandIndex);

    /// @notice Validates command inputs and restricts output and refund destinations to Cart.
    /// @dev Uses the router's MSG_SENDER alias for Cart. V4 accepts swap/SETTLE_ALL/TAKE_ALL only.
    /// @return assets Input and output assets whose custody must be checked, possibly with duplicates.
    function validate(bytes calldata commands, bytes[] calldata inputs) external view returns (address[] memory assets);
}
