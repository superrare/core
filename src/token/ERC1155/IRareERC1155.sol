// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC2981Upgradeable} from "openzeppelin-contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";

import {ITokenCreator} from "../extensions/ITokenCreator.sol";

/// @author SuperRare Labs Inc.
/// @title IRareERC1155
/// @notice Interface for the RARE Protocol ERC1155 token.
/// @dev Extends the RARE `ITokenCreator` interface so marketplace and royalty infrastructure can resolve creators per token id.
interface IRareERC1155 is ITokenCreator, IERC2981Upgradeable {
    /// @notice Per-token configuration for an ERC1155 edition.
    struct TokenConfig {
        /// @notice Maximum supply that may ever be minted for the token id.
        uint256 maxSupply;
        /// @notice Token-specific metadata URI. Falls back to the collection base URI when empty.
        string tokenURI;
        /// @notice Whether the token id has been created.
        bool exists;
    }

    /// @notice Emitted when the collection is disabled.
    /// @param user Owner that disabled the collection.
    event ContractDisabled(address indexed user);

    /// @notice Emitted when the owner creates a token type.
    /// @param tokenId Newly created token id.
    /// @param creator RARE creator recorded for the token id.
    /// @param maxSupply Maximum supply configured for the token id.
    /// @param tokenURI Token-specific metadata URI.
    event TokenCreated(uint256 indexed tokenId, address indexed creator, uint256 maxSupply, string tokenURI);

    /// @notice Emitted when owner changes minter approval.
    /// @param minter Address whose approval changed.
    /// @param isMinter True when the address is approved to mint.
    event MinterApprovalUpdated(address indexed minter, bool isMinter);

    /// @notice Reverted when a write operation is attempted after the collection has been disabled.
    error ContractIsDisabled();

    /// @notice Reverted when a token id has not been created.
    /// @param _tokenId The missing token id.
    error TokenDoesNotExist(uint256 _tokenId);

    /// @notice Reverted when an address parameter is the zero address.
    error ZeroAddressUnsupported();

    /// @notice Reverted when a caller is neither the collection owner nor an approved minter.
    /// @param _caller The account that attempted to mint.
    error CallerCannotMint(address _caller);

    /// @notice Reverted when a mint amount is zero.
    error AmountCannotBeZero();

    /// @notice Reverted when a token type is created with a zero max supply.
    error MaxSupplyCannotBeZero();

    /// @notice Reverted when minting would put a token id above its configured lifetime max supply.
    /// @param _tokenId The token id being minted.
    /// @param _requestedTotalMinted The post-mint lifetime minted supply that was requested.
    /// @param _maxSupply The configured max supply for the token id.
    error ExceededMaxSupply(uint256 _tokenId, uint256 _requestedTotalMinted, uint256 _maxSupply);

    /// @notice Reverted when a batch operation receives no items.
    error EmptyBatch();

    /// @notice Reverted when parallel batch arrays have different lengths.
    error BatchLengthMismatch();

    /// @notice Reverted when a batch exceeds the supported item count.
    /// @param supplied Number of items supplied.
    /// @param max Maximum supported item count.
    error BatchSizeExceeded(uint256 supplied, uint256 max);

    /// @notice Reverted when token ids are not strictly ascending.
    /// @param tokenId Token id that is not greater than the previous token id.
    error TokenIdsNotStrictlyAscending(uint256 tokenId);

    /// @notice Reverted when the default royalty percentage is above 100%.
    /// @param supplied Percentage supplied by the caller.
    /// @param max Maximum supported percentage.
    error RoyaltyPercentageTooHigh(uint256 supplied, uint256 max);

    /// @notice Maximum number of token ids accepted by public batch mint operations.
    /// @return Maximum supported batch item count.
    function MAX_BATCH_SIZE() external pure returns (uint256);

    /// @notice Returns the human-readable collection name.
    /// @return Collection name.
    function name() external view returns (string memory);

    /// @notice Returns the human-readable collection symbol.
    /// @return Collection symbol.
    function symbol() external view returns (string memory);

    /// @notice Returns whether owner-managed collection writes have been permanently disabled.
    /// @return True when disabled.
    function disabled() external view returns (bool);

    /// @notice Initializes a cloned ERC1155 collection.
    /// @dev Intended to be called exactly once by the factory or deployer because the implementation uses OpenZeppelin initializers.
    /// @param _name Human-readable collection name.
    /// @param _symbol Human-readable collection symbol.
    /// @param _baseURI Base ERC1155 URI used when a token id has no token-specific URI.
    /// @param _creator Initial collection owner and ERC2981 royalty receiver.
    /// @param _defaultMinter Optional minter approved during initialization. Use zero address for no default minter.
    function init(
        string calldata _name,
        string calldata _symbol,
        string calldata _baseURI,
        address _creator,
        address _defaultMinter
    ) external;

    /// @notice Creates a new token type.
    /// @param _tokenURI Metadata URI returned for the new token id.
    /// @param _maxSupply Maximum supply that may ever be minted for the new token id.
    /// @return The newly created token id.
    function createToken(string calldata _tokenURI, uint256 _maxSupply) external returns (uint256);

    /// @notice Mints one existing token id to a receiver.
    /// @dev Callable by the owner or an approved minter only. This is a one-item wrapper over batch minting.
    /// @param _receiver Address that receives the minted tokens.
    /// @param _tokenId Existing token id to mint.
    /// @param _amount Quantity to mint.
    /// @return Minted token id.
    function mintTo(address _receiver, uint256 _tokenId, uint256 _amount) external returns (uint256);

    /// @notice Mints existing token ids to a receiver.
    /// @dev Callable by the owner or an approved minter only. Token ids must be strictly ascending.
    /// Approved minters intentionally have collection-wide mint authority for any existing token id,
    /// up to that token's max supply, so creators can approve a trusted marketplace contract once
    /// instead of approving per token. Owners should only approve minters they trust to mint remaining
    /// collection supply.
    /// @param _receiver Address that receives the minted tokens.
    /// @param _tokenIds Existing token ids to mint.
    /// @param _amounts Quantities to mint for each token id.
    function mintBatchTo(address _receiver, uint256[] calldata _tokenIds, uint256[] calldata _amounts) external;

    /// @notice Grants or revokes collection-wide minter approval for an address.
    /// @dev Approval is deliberately collection-wide rather than token-scoped to keep the creator UX
    /// to a single marketplace approval. An approved minter can mint any existing token id to any
    /// receiver until the token's max supply is reached.
    /// @param _minter Address whose minter approval is being changed.
    /// @param _isMinter Whether the address should be allowed to mint.
    function setMinterApproval(address _minter, bool _isMinter) external;

    /// @notice Updates the collection-wide ERC2981 royalty receiver.
    /// @param _receiver New default royalty receiver.
    function setDefaultRoyaltyReceiver(address _receiver) external;

    /// @notice Updates the collection-wide ERC2981 royalty percentage.
    /// @param _percentage New royalty percentage, expressed as whole percentage points.
    function setDefaultRoyaltyPercentage(uint256 _percentage) external;

    /// @notice Updates the token-specific metadata URI for an existing token id.
    /// @param _tokenId Token id whose URI is updated.
    /// @param _tokenURI New token-specific metadata URI.
    function updateTokenURI(uint256 _tokenId, string calldata _tokenURI) external;

    /// @notice Permanently disables owner-managed write operations on the collection.
    function disableContract() external;

    /// @notice Returns whether an address is approved to mint.
    /// @param _address Address to inspect.
    /// @return True when `_address` is an approved minter.
    function isApprovedMinter(address _address) external view returns (bool);

    /// @notice Returns the configured max supply for a token id.
    /// @param _tokenId Token id to inspect.
    /// @return Maximum mintable supply. Returns zero for token ids that have not been created.
    function maxSupplyForToken(uint256 _tokenId) external view returns (uint256);

    /// @notice Returns the lifetime quantity minted for a token id.
    /// @dev Burns do not reduce this value.
    /// @param _tokenId Token id to inspect.
    /// @return Total quantity ever minted for the token id.
    function totalMintedForToken(uint256 _tokenId) external view returns (uint256);

    /// @notice Returns the metadata URI for a token id.
    /// @dev Returns a token-specific URI when set; otherwise returns the inherited ERC1155 base URI.
    /// @param _tokenId Token id to inspect.
    /// @return Metadata URI for the token id.
    function uri(uint256 _tokenId) external view returns (string memory);
}
