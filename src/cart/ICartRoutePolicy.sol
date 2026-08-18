// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/// @title Cart Route Policy
/// @notice Default-deny validation for the Universal Router swap commands used by Cart.
interface ICartRoutePolicy {
    struct Summary {
        /// @dev True when every command fixes its input amount.
        bool exactInput;
        /// @dev Total token amount that the route asks the router to spend.
        uint256 inputAmount;
        /// @dev Total token amount fixed by exact-output commands.
        uint256 outputAmount;
    }

    error CommandFlagsNotAllowed(uint256 commandIndex, bytes1 command);
    error CommandNotAllowed(uint256 commandIndex, bytes1 command);
    error CommandInputLengthMismatch(uint256 commands, uint256 inputs);
    error InvalidCommandInput(uint256 commandIndex);
    error InvalidRouteRecipient(uint256 commandIndex, address recipient);
    error InvalidPayer(uint256 commandIndex);
    error InvalidPath(uint256 commandIndex);
    error InvalidRouteMode(uint256 commandIndex);
    error RouteEndpointMismatch(uint256 commandIndex, address actual, address expected);

    /// @notice Validates one order-wide plan whose commands may end in any allowed output token.
    /// @dev The caller supplies the complete signed settlement-token basket; the policy does not
    ///      infer output ownership from individual lines.
    function validate(
        bytes calldata commands,
        bytes[] calldata inputs,
        address expectedInput,
        address[] calldata expectedOutputs
    ) external view returns (Summary memory summary);
}
