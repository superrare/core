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

    /// @notice Validates command inputs for the calling Cart and returns tracked endpoint assets.
    /// @dev Final destinations are the caller or MSG_SENDER. Swaps may use temporary router
    ///      custody. V4 accepts one swap, SETTLE or SETTLE_ALL, and TAKE or TAKE_ALL.
    /// @param commands Universal Router command bytes.
    /// @param inputs Command arguments, one element per command.
    /// @return assets Input and output assets whose custody must be checked, possibly with duplicates.
    function validate(bytes calldata commands, bytes[] calldata inputs) external view returns (address[] memory assets);

    /// @notice Previews a route for an explicitly identified Cart.
    /// @dev Advisory validation only. Execution uses validate so the Cart context is its caller.
    /// @param cart Target Cart proxy, including when the caller is a Lens.
    /// @param commands Universal Router command bytes.
    /// @param inputs Command arguments, one element per command.
    /// @return assets Input and output assets whose custody must be checked.
    function validateFor(
        address cart,
        bytes calldata commands,
        bytes[] calldata inputs
    ) external view returns (address[] memory assets);
}
