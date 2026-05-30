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

import {ERC2981Upgradeable} from "../extensions/ERC2981Upgradeable.sol";
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

    /// @notice Token configuration by token id.
    mapping(uint256 => TokenConfig) private tokenConfigs;

    /// @notice RARE creator address by token id.
    mapping(uint256 => address) private tokenCreators;

    /// @notice Approved minter status by account.
    mapping(address => bool) private minterAddresses;

    /// @notice Lifetime minted quantity by token id.
    mapping(uint256 => uint256) private tokenTotalMinted;

    /// @notice Ensures the collection has not been disabled.
    modifier ifNotDisabled() {
        // Atomic guard: disabled collections reject owner-managed writes before any state changes.
        if (disabled) revert ContractIsDisabled();
        _;
    }

    /// @notice Ensures a token id has been created.
    /// @param _tokenId Token id that must exist.
    modifier tokenExists(uint256 _tokenId) {
        // Atomic guard: missing token ids cannot be minted, updated, or assigned royalties.
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
        __ERC2981__init();

        // State writes: configure collection-wide default royalty behavior.
        _setDefaultRoyaltyPercentage(10);
        _setDefaultRoyaltyReceiver(_creator);

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
    function createToken(string calldata _tokenURI, uint256 _maxSupply)
        external
        onlyOwner
        ifNotDisabled
        returns (uint256)
    {
        return _createToken(_tokenURI, _maxSupply, msg.sender, msg.sender);
    }

    /// @inheritdoc IRareERC1155
    function mintTo(address _receiver, uint256 _tokenId, uint256 _amount)
        external
        ifNotDisabled
        tokenExists(_tokenId)
        returns (uint256)
    {
        // Atomic guards: validate receiver, collection-wide minter authority, and non-zero mint amount before supply math.
        // Approved minters are deliberately not token-scoped so creators can approve a trusted marketplace once.
        if (_receiver == address(0)) revert ZeroAddressUnsupported();
        if (msg.sender != owner() && !minterAddresses[msg.sender]) revert CallerCannotMint(msg.sender);
        if (_amount == 0) revert AmountCannotBeZero();

        // Atomic lifetime supply check: burns must not reopen edition supply.
        uint256 requestedTotalMinted = tokenTotalMinted[_tokenId] + _amount;
        uint256 maxSupply = tokenConfigs[_tokenId].maxSupply;
        if (requestedTotalMinted > maxSupply) revert ExceededMaxSupply(_tokenId, requestedTotalMinted, maxSupply);

        // State write: record lifetime minted supply before the ERC1155 receiver hook can run.
        tokenTotalMinted[_tokenId] = requestedTotalMinted;

        // Token mint: OpenZeppelin ERC1155 updates balances, total supply, and emits TransferSingle.
        _mint(_receiver, _tokenId, _amount, "");

        return _tokenId;
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
        // Atomic guard: default royalties must pay a real recipient.
        if (_receiver == address(0)) revert ZeroAddressUnsupported();

        // State write: update inherited ERC2981 default royalty receiver.
        _setDefaultRoyaltyReceiver(_receiver);
    }

    /// @inheritdoc IRareERC1155
    function setRoyaltyReceiverForToken(address _receiver, uint256 _tokenId)
        external
        onlyOwner
        ifNotDisabled
        tokenExists(_tokenId)
    {
        // Atomic guard: token-specific royalties must pay a real recipient.
        if (_receiver == address(0)) revert ZeroAddressUnsupported();

        // State write: update inherited ERC2981 royalty receiver for a single token id.
        _setRoyaltyReceiver(_tokenId, _receiver);
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
        emit MetadataUpdate(_tokenId);
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

    /// @inheritdoc IRareERC1155
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        override(ERC1155Upgradeable, ERC2981Upgradeable, IRareERC1155)
        returns (bool)
    {
        return _interfaceId == 0x49064906 || _interfaceId == type(IRareERC1155).interfaceId
            || _interfaceId == type(ITokenCreator).interfaceId || super.supportsInterface(_interfaceId);
    }

    /// @notice Creates a token id and configures creator and royalty state.
    /// @param _tokenURI Token-specific metadata URI.
    /// @param _maxSupply Maximum supply for the token id.
    /// @param _creator RARE creator recorded for the token id.
    /// @param _royaltyReceiver ERC2981 receiver for the token id.
    /// @return tokenId Newly created token id.
    function _createToken(string calldata _tokenURI, uint256 _maxSupply, address _creator, address _royaltyReceiver)
        internal
        returns (uint256)
    {
        // Atomic guards: token ids must be mintable and royalties must have a recipient.
        if (_maxSupply == 0) revert MaxSupplyCannotBeZero();
        if (_royaltyReceiver == address(0)) revert ZeroAddressUnsupported();

        // State write: advance the monotonically increasing token id counter.
        tokenIdCounter++;
        uint256 tokenId = tokenIdCounter;

        // State writes: register token constraints, creator lookup, and ERC2981 royalty settings.
        tokenConfigs[tokenId] = TokenConfig(_maxSupply, _tokenURI, true);
        tokenCreators[tokenId] = _creator;
        _setRoyaltyReceiver(tokenId, _royaltyReceiver);
        _setRoyaltyPercentage(tokenId, getDefaultRoyaltyPercentage());

        // Metadata and domain events: expose the new URI and token config to indexers.
        emit URI(_tokenURI, tokenId);
        emit TokenCreated(tokenId, _creator, _maxSupply, _tokenURI, _royaltyReceiver);

        return tokenId;
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
