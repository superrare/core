// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @author SuperRare Labs Inc.
/// @title IRareERC1155ContractFactory
/// @notice Interface for the RARE Protocol ERC1155 clone factory.
interface IRareERC1155ContractFactory {
    /// @notice Reverted when an implementation address is the zero address.
    error ZeroAddressUnsupported();

    /// @notice Emitted when the factory creates and initializes a collection clone.
    /// @param contractAddress Address of the newly created ERC1155 clone.
    /// @param owner Initial owner of the clone.
    event RareERC1155ContractCreated(address indexed contractAddress, address indexed owner);

    /// @notice Emitted when the owner changes the implementation cloned by the factory.
    /// @param rareERC1155 New ERC1155 implementation address.
    event RareERC1155Updated(address indexed rareERC1155);

    /// @notice Emitted when the owner changes the default minter for new clones.
    /// @param defaultMinter New default minter address. Zero address disables default minter approval.
    event DefaultMinterUpdated(address indexed defaultMinter);

    /// @notice Returns the ERC1155 implementation address cloned by the factory.
    /// @return ERC1155 implementation address.
    function rareERC1155() external view returns (address);

    /// @notice Returns the optional minter approved on each newly created collection.
    /// @return Default minter address. Zero address means no default minter.
    function defaultMinter() external view returns (address);

    /// @notice Updates the ERC1155 implementation address cloned by future factory calls.
    /// @param _rareERC1155 Address of the replacement implementation.
    function setRareERC1155(address _rareERC1155) external;

    /// @notice Updates the optional minter approved during clone initialization.
    /// @param _defaultMinter Address approved to mint on newly created clones, or zero address for none.
    function setDefaultMinter(address _defaultMinter) external;

    /// @notice Creates a new initialized ERC1155 collection clone.
    /// @param _name Human-readable collection name.
    /// @param _symbol Human-readable collection symbol.
    /// @param _baseURI Base URI used by the collection when a token id has no token-specific URI.
    /// @return clone Address of the newly created ERC1155 clone.
    function createRareERC1155Contract(string calldata _name, string calldata _symbol, string calldata _baseURI)
        external
        returns (address clone);
}
