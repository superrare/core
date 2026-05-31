// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1155Upgradeable} from "openzeppelin-contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {
    ERC1155BurnableUpgradeable
} from "openzeppelin-contracts-upgradeable/token/ERC1155/extensions/ERC1155BurnableUpgradeable.sol";
import {
    ERC1155SupplyUpgradeable
} from "openzeppelin-contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {ERC2981Upgradeable} from "openzeppelin-contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {IERC165Upgradeable} from "openzeppelin-contracts-upgradeable/utils/introspection/IERC165Upgradeable.sol";

import {ITokenCreator} from "../extensions/ITokenCreator.sol";
import {IRareERC1155} from "./IRareERC1155.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155
/// @notice Basic RARE Protocol ERC1155 collection with creator and royalty support.
/// @dev Clone-safe upgradeable-style implementation used behind minimal proxies. Token ids start at 1.
contract RareERC1155 is
    IRareERC1155,
    OwnableUpgradeable,
    ERC1155Upgradeable,
    ERC1155BurnableUpgradeable,
    ERC1155SupplyUpgradeable,
    ERC2981Upgradeable
{
    string public override name;
    string public override symbol;
    bool public override disabled;

    /// @notice Last created token id.
    uint256 private tokenIdCounter;

    /// @inheritdoc IRareERC1155
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice Default ERC2981 royalty fee in whole percentage points.
    uint256 private constant DEFAULT_ROYALTY_PERCENTAGE = 10;

    /// @notice Maximum ERC2981 royalty fee in whole percentage points.
    uint256 private constant MAX_ROYALTY_PERCENTAGE = 100;

    /// @notice ERC2981 fee denominator uses basis points.
    uint256 private constant BASIS_POINTS_PER_PERCENT = 100;

    /// @notice Token configuration by token id.
    mapping(uint256 => TokenConfig) private tokenConfigs;

    /// @notice RARE creator address by token id.
    mapping(uint256 => address) private tokenCreators;

    /// @notice Approved minter status by account.
    mapping(address => bool) private minterAddresses;

    /// @notice Lifetime minted quantity by token id.
    mapping(uint256 => uint256) private tokenTotalMinted;

    /// @notice Fallback ERC2981 royalty receiver.
    address private defaultRoyaltyReceiver;

    /// @notice Fallback ERC2981 royalty percentage, expressed as whole percentage points.
    uint256 private defaultRoyaltyPercentage;

    /// @notice Token-specific ERC2981 royalty percentage, expressed as whole percentage points.
    mapping(uint256 => uint256) private tokenRoyaltyPercentages;

    /// @notice Ensures the collection has not been disabled.
    modifier ifNotDisabled() {
        // Atomic guard: disabled collections reject owner-managed writes before any state changes.
        if (disabled) revert ContractIsDisabled();
        _;
    }

    /// @notice Ensures a token id has been created.
    /// @param _tokenId Token id that must exist.
    modifier tokenExists(uint256 _tokenId) {
        // Atomic guard: missing token ids cannot be minted or updated.
        if (!tokenConfigs[_tokenId].exists) revert TokenDoesNotExist(_tokenId);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRareERC1155
    function init(
        string calldata _name,
        string calldata _symbol,
        string calldata _baseURI,
        address _creator,
        address _defaultMinter
    ) public initializer {
        // Atomic guard: a collection must always have a non-zero owner and royalty receiver.
        if (_creator == address(0)) revert ZeroAddressUnsupported();

        // State write: store public collection metadata before ownership is transferred.
        name = _name;
        symbol = _symbol;
        disabled = false;

        // Initializer call: set up inherited upgradeable storage for the clone.
        __Ownable_init();
        __ERC1155_init(_baseURI);
        __ERC1155Burnable_init();
        __ERC1155Supply_init();
        __ERC2981_init();

        // State write: expose EIP-2981 royalties as 10% to the collection creator.
        _setDefaultRoyaltyConfig(_creator, DEFAULT_ROYALTY_PERCENTAGE);

        if (_defaultMinter != address(0)) {
            // State write: grant optional marketplace or minter approval at initialization.
            minterAddresses[_defaultMinter] = true;
            emit MinterApprovalUpdated(_defaultMinter, true);
        }

        // Ownership transfer: hand the clone from the initializer caller to the intended creator.
        _transferOwnership(_creator);
    }

    /// @inheritdoc IRareERC1155
    function createToken(string calldata _tokenURI, uint256 _maxSupply, address _royaltyReceiver)
        external
        onlyOwner
        ifNotDisabled
        returns (uint256)
    {
        return _createToken(_tokenURI, _maxSupply, msg.sender, _royaltyReceiver);
    }

    /// @inheritdoc IRareERC1155
    function mintTo(address _receiver, uint256 _tokenId, uint256 _amount) external ifNotDisabled returns (uint256) {
        uint256[] memory tokenIds = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        tokenIds[0] = _tokenId;
        amounts[0] = _amount;

        _mintBatchTo(_receiver, tokenIds, amounts);
        return _tokenId;
    }

    /// @inheritdoc IRareERC1155
    function mintBatchTo(address _receiver, uint256[] calldata _tokenIds, uint256[] calldata _amounts)
        external
        ifNotDisabled
    {
        _mintBatchTo(_receiver, _tokenIds, _amounts);
    }

    /// @notice Mints existing token ids to a receiver after shared mint validation.
    /// @param _receiver Address that receives the minted tokens.
    /// @param _tokenIds Existing token ids to mint.
    /// @param _amounts Quantities to mint for each token id.
    function _mintBatchTo(address _receiver, uint256[] memory _tokenIds, uint256[] memory _amounts) internal {
        // Atomic guards: validate receiver, collection-wide minter authority, and batch shape before supply math.
        // Approved minters are deliberately not token-scoped so creators can approve a trusted marketplace once.
        if (_receiver == address(0)) revert ZeroAddressUnsupported();
        if (msg.sender != owner() && !minterAddresses[msg.sender]) revert CallerCannotMint(msg.sender);
        _validateMintBatch(_tokenIds, _amounts);

        for (uint256 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];
            if (!tokenConfigs[tokenId].exists) revert TokenDoesNotExist(tokenId);
            if (_amounts[i] == 0) revert AmountCannotBeZero();

            // Atomic lifetime supply check: burns must not reopen edition supply.
            uint256 requestedTotalMinted = tokenTotalMinted[tokenId] + _amounts[i];
            uint256 maxSupply = tokenConfigs[tokenId].maxSupply;
            if (requestedTotalMinted > maxSupply) revert ExceededMaxSupply(tokenId, requestedTotalMinted, maxSupply);

            // State write: record lifetime minted supply before the ERC1155 receiver hook can run.
            tokenTotalMinted[tokenId] = requestedTotalMinted;
        }

        // Token mint: OpenZeppelin ERC1155 updates balances, total supply, and emits TransferBatch.
        _mintBatch(_receiver, _tokenIds, _amounts, "");
    }

    /// @inheritdoc IRareERC1155
    function setMinterApproval(address _minter, bool _isMinter) external onlyOwner ifNotDisabled {
        // Atomic guard: zero address minter entries are never meaningful and cannot mint.
        if (_minter == address(0)) revert ZeroAddressUnsupported();

        // State write: update the collection-wide minter allowlist for future mint calls.
        minterAddresses[_minter] = _isMinter;
        emit MinterApprovalUpdated(_minter, _isMinter);
    }

    /// @inheritdoc IRareERC1155
    function setDefaultRoyaltyReceiver(address _receiver) external onlyOwner ifNotDisabled {
        _setDefaultRoyaltyConfig(_receiver, defaultRoyaltyPercentage);
    }

    /// @inheritdoc IRareERC1155
    function setDefaultRoyaltyPercentage(uint256 _percentage) external onlyOwner ifNotDisabled {
        _setDefaultRoyaltyConfig(defaultRoyaltyReceiver, _percentage);
    }

    /// @inheritdoc IRareERC1155
    function setRoyaltyReceiverForToken(uint256 _tokenId, address _receiver)
        external
        onlyOwner
        ifNotDisabled
        tokenExists(_tokenId)
    {
        _setTokenRoyaltyReceiver(_tokenId, _receiver);
    }

    /// @inheritdoc IRareERC1155
    function updateTokenURI(uint256 _tokenId, string calldata _tokenURI)
        external
        onlyOwner
        ifNotDisabled
        tokenExists(_tokenId)
    {
        // State write: replace the token-specific metadata URI.
        tokenConfigs[_tokenId].tokenURI = _tokenURI;

        // ERC1155 metadata signal: notify indexers of the new URI.
        emit URI(_tokenURI, _tokenId);
    }

    /// @inheritdoc IRareERC1155
    function disableContract() external onlyOwner {
        // State write: permanently stop owner-managed writes guarded by ifNotDisabled.
        disabled = true;
        emit ContractDisabled(msg.sender);
    }

    /// @inheritdoc ITokenCreator
    function tokenCreator(uint256 _tokenId) public view override(ITokenCreator) returns (address payable) {
        return payable(tokenCreators[_tokenId]);
    }

    /// @inheritdoc IRareERC1155
    function isApprovedMinter(address _address) external view returns (bool) {
        return minterAddresses[_address];
    }

    /// @inheritdoc IRareERC1155
    function maxSupplyForToken(uint256 _tokenId) external view returns (uint256) {
        return tokenConfigs[_tokenId].maxSupply;
    }

    /// @inheritdoc IRareERC1155
    function totalMintedForToken(uint256 _tokenId) external view returns (uint256) {
        return tokenTotalMinted[_tokenId];
    }

    /// @inheritdoc IRareERC1155
    function uri(uint256 _tokenId) public view override(ERC1155Upgradeable, IRareERC1155) returns (string memory) {
        string memory tokenURI = tokenConfigs[_tokenId].tokenURI;
        return bytes(tokenURI).length > 0 ? tokenURI : super.uri(_tokenId);
    }

    /// @inheritdoc IERC165Upgradeable
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        override(ERC1155Upgradeable, ERC2981Upgradeable, IERC165Upgradeable)
        returns (bool)
    {
        return _interfaceId == type(IRareERC1155).interfaceId || _interfaceId == type(ITokenCreator).interfaceId
            || super.supportsInterface(_interfaceId);
    }

    /// @notice Creates a token id and configures creator state.
    /// @param _tokenURI Token-specific metadata URI.
    /// @param _maxSupply Maximum supply for the token id.
    /// @param _creator RARE creator recorded for the token id.
    /// @param _royaltyReceiver ERC2981 royalty receiver for the token id.
    /// @return tokenId Newly created token id.
    function _createToken(string calldata _tokenURI, uint256 _maxSupply, address _creator, address _royaltyReceiver)
        internal
        returns (uint256)
    {
        // Atomic guard: token ids must be mintable.
        if (_maxSupply == 0) revert MaxSupplyCannotBeZero();
        if (_royaltyReceiver == address(0)) revert ZeroAddressUnsupported();

        // State write: advance the monotonically increasing token id counter.
        tokenIdCounter++;
        uint256 tokenId = tokenIdCounter;

        // State writes: register token constraints and creator lookup.
        tokenConfigs[tokenId] = TokenConfig(_maxSupply, _tokenURI, true);
        tokenCreators[tokenId] = _creator;
        tokenRoyaltyPercentages[tokenId] = defaultRoyaltyPercentage;
        _setTokenRoyalty(tokenId, _royaltyReceiver, uint96(defaultRoyaltyPercentage * BASIS_POINTS_PER_PERCENT));

        // Metadata and domain events: expose the new URI and token config to indexers.
        emit URI(_tokenURI, tokenId);
        emit TokenCreated(tokenId, _creator, _royaltyReceiver, _maxSupply, _tokenURI);

        return tokenId;
    }

    /// @notice Updates fallback ERC2981 royalty config.
    /// @param _receiver Royalty receiver address.
    /// @param _percentage Royalty percentage, expressed as whole percentage points.
    function _setDefaultRoyaltyConfig(address _receiver, uint256 _percentage) internal {
        if (_receiver == address(0)) revert ZeroAddressUnsupported();
        if (_percentage > MAX_ROYALTY_PERCENTAGE) {
            revert RoyaltyPercentageTooHigh(_percentage, MAX_ROYALTY_PERCENTAGE);
        }

        defaultRoyaltyReceiver = _receiver;
        defaultRoyaltyPercentage = _percentage;
        _setDefaultRoyalty(_receiver, uint96(_percentage * BASIS_POINTS_PER_PERCENT));
    }

    /// @notice Updates a token-specific ERC2981 royalty receiver.
    /// @param _tokenId Token id whose receiver should be updated.
    /// @param _receiver Royalty receiver address.
    function _setTokenRoyaltyReceiver(uint256 _tokenId, address _receiver) internal {
        if (_receiver == address(0)) revert ZeroAddressUnsupported();

        _setTokenRoyalty(_tokenId, _receiver, uint96(tokenRoyaltyPercentages[_tokenId] * BASIS_POINTS_PER_PERCENT));
    }

    /// @notice Validates batch mint input shape and token id ordering.
    /// @param _tokenIds Token ids requested by the caller.
    /// @param _amounts Amounts requested by the caller.
    function _validateMintBatch(uint256[] memory _tokenIds, uint256[] memory _amounts) internal pure {
        if (_tokenIds.length == 0) revert EmptyBatch();
        if (_tokenIds.length != _amounts.length) revert BatchLengthMismatch();
        if (_tokenIds.length > MAX_BATCH_SIZE) revert BatchSizeExceeded(_tokenIds.length, MAX_BATCH_SIZE);

        for (uint256 i = 1; i < _tokenIds.length; i++) {
            if (_tokenIds[i] <= _tokenIds[i - 1]) revert TokenIdsNotStrictlyAscending(_tokenIds[i]);
        }
    }

    /// @notice Hook called by OpenZeppelin before ERC1155 token transfers, mints, and burns.
    /// @dev Delegates to `ERC1155SupplyUpgradeable` so total supply accounting stays correct.
    /// @param _operator Operator executing the transfer.
    /// @param _from Source address. Zero address indicates mint.
    /// @param _to Destination address. Zero address indicates burn.
    /// @param _ids Token ids being transferred.
    /// @param _amounts Amounts being transferred for each token id.
    /// @param _data Additional transfer data.
    function _beforeTokenTransfer(
        address _operator,
        address _from,
        address _to,
        uint256[] memory _ids,
        uint256[] memory _amounts,
        bytes memory _data
    ) internal override(ERC1155Upgradeable, ERC1155SupplyUpgradeable) {
        // Hook delegation: inherited supply extension performs atomic total-supply updates.
        super._beforeTokenTransfer(_operator, _from, _to, _ids, _amounts, _data);
    }
}
