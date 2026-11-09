// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

/// @notice Creator-token discovery interface used by Limit Break and OpenSea.
/// @dev Matches creator-token-standards v5.0.0 (980a63b33591d568b6e04b45f37deba05a55f787).
interface ICreatorToken {
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    function getTransferValidator() external view returns (address validator);

    function setTransferValidator(address validator) external;

    function getTransferValidationFunction() external view returns (bytes4 functionSignature, bool isViewFunction);
}
