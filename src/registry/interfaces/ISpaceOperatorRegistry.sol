// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @author koloz
/// @title ISpaceOperatorRegistry
/// @notice The interface for the SpaceOperatorRegistry
interface ISpaceOperatorRegistry {
    function getPlatformCommission(address _operator)
        external
        view
        returns (uint16);

    function setPlatformCommission(address _operator, uint16 _commission)
        external;

    function isApprovedSpaceOperator(address _operator)
        external
        view
        returns (bool);

    function setSpaceOperatorApproved(address _operator, bool _approved)
        external;
}
