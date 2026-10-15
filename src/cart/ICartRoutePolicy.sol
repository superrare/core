// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/// @title Cart Route Policy
/// @notice Default-deny validation for the Universal Router swap commands used by Cart.
interface ICartRoutePolicy {
    error CommandFlagsNotAllowed(uint256 commandIndex, bytes1 command);
    error CommandNotAllowed(uint256 commandIndex, bytes1 command);
    error CommandInputLengthMismatch(uint256 commands, uint256 inputs);
    error RouteTooManyCommands(uint256 count);
    error RouteTooManyInputs(uint256 count);
    error EmptyRoute();

    /// @notice Validates only the structure and command families of one signed Universal Router plan.
    /// @dev Universal Router remains responsible for decoding and executing every command input.
    function validate(bytes calldata commands, bytes[] calldata inputs) external view;
}
