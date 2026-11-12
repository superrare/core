// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {PaymentSplitter} from "@openzeppelin/contracts/finance/PaymentSplitter.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @notice Immutable split terms and the collection's whole-percent royalty rate.
/// @dev The beneficiary slot is replaced when a collection resolves an individual beneficiary.
struct RoyaltySplitConfig {
    address[] recipients;
    uint256[] shares;
    uint256 beneficiaryIndex;
    uint256 royaltyPercentage;
}

/// @notice Permissionless deployment and reuse of immutable OpenZeppelin payment splitters.
/// @dev Only the ordered recipients and shares determine split identity, not a collection's royalty rate.
contract RoyaltySplitterFactory {
    /// @notice The hash of a splitter's constructor terms, or zero for an unknown address.
    mapping(address => bytes32) public configurationHash;

    event RoyaltySplitterCreated(address indexed splitter, bytes32 indexed configurationHash);

    /// @notice Return the existing splitter for these terms, or deploy it atomically.
    /// @dev PaymentSplitter's constructor validates recipients and shares. Failed deployment records nothing.
    function getOrCreateSplitter(address[] calldata recipients, uint256[] calldata shares)
        external
        returns (address splitter)
    {
        (bytes32 configHash, bytes memory initCode) = _creationData(recipients, shares);
        splitter = Create2.computeAddress(configHash, keccak256(initCode));
        if (configurationHash[splitter] == bytes32(0)) {
            splitter = Create2.deploy(0, configHash, initCode);
            configurationHash[splitter] = configHash;
            emit RoyaltySplitterCreated(splitter, configHash);
        }
    }

    /// @notice Predict the splitter without deploying it or validating its constructor terms.
    function predictSplitter(address[] calldata recipients, uint256[] calldata shares) public view returns (address) {
        (bytes32 configHash, bytes memory initCode) = _creationData(recipients, shares);
        return Create2.computeAddress(configHash, keccak256(initCode));
    }

    function _creationData(address[] calldata recipients, uint256[] calldata shares)
        private
        pure
        returns (bytes32 configHash, bytes memory initCode)
    {
        bytes memory constructorArguments = abi.encode(recipients, shares);
        configHash = keccak256(constructorArguments);
        initCode = bytes.concat(type(PaymentSplitter).creationCode, constructorArguments);
    }
}
