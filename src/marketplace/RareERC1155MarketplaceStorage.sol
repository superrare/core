// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {ERC165Checker} from "openzeppelin-contracts/utils/introspection/ERC165Checker.sol";

import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";
import {IRareERC1155} from "../token/ERC1155/IRareERC1155.sol";
import {IERC1155ApprovalManager} from "../v2/approver/ERC1155/IERC1155ApprovalManager.sol";
import {IRareERC1155MarketplaceTypes} from "./IRareERC1155MarketplaceTypes.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155MarketplaceStorage
/// @notice ERC-7201 storage namespace and validation helpers for the ERC1155 marketplace.
/// @dev This is not a deployable marketplace. `RareERC1155Marketplace` owns this storage behind the proxy, and
/// `RareERC1155Settlement` uses the same namespace when executed through delegatecall from the marketplace.
abstract contract RareERC1155MarketplaceStorage is IRareERC1155MarketplaceTypes {
    uint256 public constant MAX_BATCH_SIZE = 100;

    bytes32 internal constant NETWORK_BENEFICIARY_FIELD = "NETWORK_BENEFICIARY";
    bytes32 internal constant MARKETPLACE_SETTINGS_FIELD = "MARKETPLACE_SETTINGS";
    bytes32 internal constant SPACE_OPERATOR_REGISTRY_FIELD = "SPACE_OPERATOR_REGISTRY";
    bytes32 internal constant ROYALTY_ENGINE_FIELD = "ROYALTY_ENGINE";
    bytes32 internal constant PAYMENTS_FIELD = "PAYMENTS";
    bytes32 internal constant APPROVED_TOKEN_REGISTRY_FIELD = "APPROVED_TOKEN_REGISTRY";
    bytes32 internal constant STAKING_SETTINGS_FIELD = "STAKING_SETTINGS";
    bytes32 internal constant STAKING_REGISTRY_FIELD = "STAKING_REGISTRY";
    bytes32 internal constant ERC20_APPROVAL_MANAGER_FIELD = "ERC20_APPROVAL_MANAGER";
    bytes32 internal constant ERC721_APPROVAL_MANAGER_FIELD = "ERC721_APPROVAL_MANAGER";
    bytes32 internal constant ERC1155_APPROVAL_MANAGER_FIELD = "ERC1155_APPROVAL_MANAGER";
    bytes32 internal constant SETTLEMENT_FIELD = "SETTLEMENT";

    /// @custom:storage-location erc7201:superrare.storage.RareERC1155Marketplace
    /// @dev Append new fields to the end. Marketplace and settlement implementations must share this exact layout because
    /// settlement runs against marketplace proxy storage through delegatecall.
    struct MarketplaceStorage {
        /// @notice Shared V2 marketplace dependency bundle.
        MarketConfigV2.Config marketConfig;
        /// @notice ERC1155 approval manager used for seller token transfers.
        IERC1155ApprovalManager erc1155ApprovalManager;
        /// @notice Delegatecall target used for settlement entrypoints.
        address settlement;
        /// @notice Primary mint sale configs keyed by collection and token id.
        mapping(address => mapping(uint256 => DirectSaleConfig)) directSaleConfigs;
        /// @notice Active mint allowlist configs keyed by collection and token id.
        mapping(address => mapping(uint256 => AllowListConfig)) tokenAllowlistRoots;
        /// @notice Per-address mint quantity limits keyed by collection and token id.
        mapping(address => mapping(uint256 => uint256)) tokenMintLimit;
        /// @notice Mint quantity consumed by account while a token's mint limit is enabled.
        mapping(address => mapping(uint256 => mapping(address => uint256))) tokenMintsPerAddress;
        /// @notice Per-address mint transaction limits keyed by collection and token id.
        mapping(address => mapping(uint256 => uint256)) tokenTxLimit;
        /// @notice Mint transactions consumed by account while a token's tx limit is enabled.
        mapping(address => mapping(uint256 => mapping(address => uint256))) tokenTxsPerAddress;
        /// @notice Secondary fixed-price listings keyed by collection, token id, and seller.
        mapping(address => mapping(uint256 => mapping(address => SalePrice))) salePrices;
        /// @notice Escrowed offers keyed by collection, token id, buyer, and currency.
        mapping(address => mapping(uint256 => mapping(address => mapping(address => Offer)))) offers;
        /// @notice Pauses marketplace writes and settlement entrypoints.
        bool paused;
    }

    /// @dev cast index-erc7201 superrare.storage.RareERC1155Marketplace
    bytes32 internal constant MARKETPLACE_STORAGE_LOCATION =
        0x5e94cc2b8b9fd616c1ffff3497627b534929331e1f3b26d7dc3360464546d500;

    function _marketplaceStorage() internal pure returns (MarketplaceStorage storage $) {
        assembly {
            $.slot := MARKETPLACE_STORAGE_LOCATION
        }
    }

    function _validateMarketConfigAddress(address _address, bytes32 _field) internal pure {
        if (_address == address(0)) revert MarketConfigAddressCannotBeZero(_field);
    }

    function _validateApprovalManager(address _approvalManager) internal pure {
        if (_approvalManager == address(0)) revert ApprovalManagerCannotBeZero();
    }

    function _validateSettlement(address _settlement) internal pure {
        if (_settlement == address(0)) revert SettlementCannotBeZero();
    }

    function _validateERC1155Contract(address _contractAddress) internal view {
        if (
            _contractAddress.code.length == 0
                || !ERC165Checker.supportsInterface(_contractAddress, type(IERC1155).interfaceId)
        ) {
            revert InvalidERC1155Contract(_contractAddress);
        }
    }

    function _revertIfTokenNotFound(address _contractAddress, uint256 _tokenId) internal view {
        if (IRareERC1155(_contractAddress).maxSupplyForToken(_tokenId) == 0) {
            revert TokenNotFound(_contractAddress, _tokenId);
        }
    }

    function _isContractOwner(address _contractAddress, address _account) internal view returns (bool) {
        (bool success, bytes memory data) = _contractAddress.staticcall(abi.encodeWithSignature("owner()"));
        if (!success || data.length < 32) revert ContractHasNoOwner(_contractAddress);
        return abi.decode(data, (address)) == _account;
    }

    function _validateTokenIds(uint256[] calldata _tokenIds) internal pure {
        _validateBatchSize(_tokenIds.length);
        for (uint256 i = 1; i < _tokenIds.length; i++) {
            if (_tokenIds[i] <= _tokenIds[i - 1]) {
                revert TokenIdsNotStrictlyAscending(i, _tokenIds[i - 1], _tokenIds[i]);
            }
        }
    }

    function _validateBatchSize(uint256 _length) internal pure {
        if (_length == 0) revert EmptyBatch();
        if (_length > MAX_BATCH_SIZE) revert BatchSizeExceeded(_length, MAX_BATCH_SIZE);
    }

    function _validateStrictAscending(uint256 _index, uint256 _previousTokenId, uint256 _tokenId) internal pure {
        if (_tokenId <= _previousTokenId) {
            revert TokenIdsNotStrictlyAscending(_index, _previousTokenId, _tokenId);
        }
    }

    function _verifyProof(bytes32 _leaf, bytes32 _root, bytes32[] calldata _proof) internal pure returns (bool) {
        bytes32 currentHash = _leaf;

        for (uint256 i = 0; i < _proof.length; i++) {
            currentHash = _parentHash(currentHash, _proof[i]);
        }

        return currentHash == _root;
    }

    function _parentHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
