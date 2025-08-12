// contracts/token/ERC721/sovereign/SovereignNFT.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "openzeppelin-contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "openzeppelin-contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/utils/CountersUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";

import "../../../../token/extensions/ITokenCreator.sol";
import "../../../../token/extensions/ERC2981Upgradeable.sol";

contract SovereignBatchMint is
  OwnableUpgradeable,
  ERC165Upgradeable,
  ERC721Upgradeable,
  ITokenCreator,
  ERC721BurnableUpgradeable,
  ERC2981Upgradeable
{
  using SafeMathUpgradeable for uint256;
  using StringsUpgradeable for uint256;
  using CountersUpgradeable for CountersUpgradeable.Counter;

  struct MintBatch {
    uint256 startTokenId;
    uint256 endTokenId;
    string baseURI;
  }

  bool public disabled;

  // Global lock for all token URIs
  bool public tokenURIsLocked;

  uint256 public maxTokens;

  // Maximum number of batches allowed to prevent DoS via unbounded loops
  uint256 public constant MAX_BATCHES = 100;

  address private _defaultTokenCreator;

  // Mapping from tokenId to if it was burned or not (for batch minting)
  mapping(uint256 => bool) private tokensBurned;

  // Mapping from token ID to approved address
  mapping(uint256 => address) private _tokenApprovals;

  // Counter to keep track of the current token id.
  CountersUpgradeable.Counter private tokenIdCounter;

  MintBatch[] private mintBatches;

  // Optional mapping for token URIs
  mapping(uint256 => string) private _tokenURIs;

  // Mapping for overridden batch token URIs
  mapping(uint256 => string) private _overriddenBatchURIs;

  event ContractDisabled(address indexed user);
  event TokenURIUpdated(uint256 indexed tokenId, string newURI);
  event BatchBaseURIUpdated(uint256 indexed batchIndex, string newBaseURI);
  event TokenURIsLocked();
  event CreatorSet(address indexed creator);

  event ConsecutiveTransfer(
    uint256 indexed fromTokenId,
    uint256 toTokenId,
    address indexed fromAddress,
    address indexed toAddress
  );

  function init(
    string calldata _name,
    string calldata _symbol,
    address _creator,
    uint256 _maxTokens
  ) public initializer {
    require(_creator != address(0), "creator cannot be null address");
    _setDefaultRoyaltyPercentage(10);
    disabled = false;
    tokenURIsLocked = false;
    maxTokens = _maxTokens;

    __Ownable_init();
    __ERC721_init(_name, _symbol);
    __ERC165_init();
    __ERC2981__init();

    _setDefaultRoyaltyReceiver(_creator);
    _defaultTokenCreator = _creator;

    super.transferOwnership(_creator);
  }

  modifier onlyTokenOwner(uint256 _tokenId) {
    require(ownerOf(_tokenId) == msg.sender, "Must be owner of token.");
    _;
  }

  modifier ifNotDisabled() {
    require(!disabled, "Contract must not be disabled.");
    _;
  }

  function batchMint(string calldata _baseURI, uint256 _numberOfTokens) public onlyOwner ifNotDisabled {
    require(mintBatches.length < MAX_BATCHES, "batchMint::exceeded max batches");

    uint256 startTokenId = tokenIdCounter.current() + 1;
    uint256 endTokenId = startTokenId + _numberOfTokens - 1;

    tokenIdCounter._value = endTokenId;

    require(tokenIdCounter.current() <= maxTokens, "batchMint::exceeded maxTokens");

    mintBatches.push(MintBatch(startTokenId, endTokenId, _baseURI));

    emit ConsecutiveTransfer(startTokenId, endTokenId, address(0), owner());
  }

  function addNewToken(string memory _uri) public onlyOwner ifNotDisabled {
    _createToken(_uri, msg.sender, getDefaultRoyaltyPercentage(), msg.sender);
  }

  function mintTo(string calldata _uri, address _receiver, address _royaltyReceiver) external onlyOwner ifNotDisabled {
    _createToken(_uri, _receiver, getDefaultRoyaltyPercentage(), _royaltyReceiver);
  }

  function burn(uint256 _tokenId) public virtual override onlyTokenOwner(_tokenId) {
    (bool wasBatchMinted, , ) = _batchMintInfo(_tokenId);

    tokensBurned[_tokenId] = true;
    // Clear any existing approval to prevent stale approvals if token IDs are reused
    _tokenApprovals[_tokenId] = address(0);

    if (wasBatchMinted && !ERC721Upgradeable._exists(_tokenId)) {
      // For batch-minted tokens that were never transferred, we need to manually emit
      // the Transfer event to maintain ERC-721 compliance for indexers
      emit Transfer(owner(), address(0), _tokenId);
      return;
    }

    ERC721BurnableUpgradeable.burn(_tokenId);
  }

  function tokenCreator(uint256) public view override returns (address payable) {
    return payable(_defaultTokenCreator);
  }

  function disableContract() public onlyOwner {
    disabled = true;
    emit ContractDisabled(msg.sender);
  }

  function setDefaultRoyaltyReceiver(address _receiver) external onlyOwner {
    _setDefaultRoyaltyReceiver(_receiver);
  }

  function setDefaultRoyaltyPercentage(uint256 _percentage) external onlyOwner {
    _setDefaultRoyaltyPercentage(_percentage);
  }

  function setRoyaltyReceiverForToken(address _receiver, uint256 _tokenId) external onlyOwner {
    royaltyReceivers[_tokenId] = _receiver;
  }

  function setCreator(address _creator) external onlyOwner {
    _defaultTokenCreator = _creator;
    emit CreatorSet(_creator);
  }

  function _createToken(
    string memory _uri,
    address _to,
    uint256 _royaltyPercentage,
    address _royaltyReceiver
  ) internal returns (uint256) {
    tokenIdCounter.increment();
    uint256 tokenId = tokenIdCounter.current();
    require(tokenId <= maxTokens, "_createToken::exceeded maxTokens");
    _safeMint(_to, tokenId);
    _tokenURIs[tokenId] = _uri;
    _setRoyaltyPercentage(tokenId, _royaltyPercentage);
    _setRoyaltyReceiver(tokenId, _royaltyReceiver);
    return tokenId;
  }

  ///////////////////////////////////////////////
  // Overriding Methods to support batch mints
  ///////////////////////////////////////////////
  function tokenURI(uint256 _tokenId) public view virtual override returns (string memory) {
    // Check for overridden batch URI first
    if (bytes(_overriddenBatchURIs[_tokenId]).length > 0) {
      return _overriddenBatchURIs[_tokenId];
    }

    (bool wasBatchMinted, , string memory baseTokenUri) = _batchMintInfo(_tokenId);

    if (!wasBatchMinted) {
      return _tokenURIs[_tokenId];
    } else {
      return string(abi.encodePacked(baseTokenUri, "/", _tokenId.toString(), ".json"));
    }
  }

  function ownerOf(uint256 _tokenId) public view virtual override returns (address) {
    (bool wasBatchMinted, , ) = _batchMintInfo(_tokenId);

    if (!wasBatchMinted) {
      return ERC721Upgradeable.ownerOf(_tokenId);
    } else if (tokensBurned[_tokenId]) {
      return ERC721Upgradeable.ownerOf(_tokenId);
    } else {
      if (!ERC721Upgradeable._exists(_tokenId)) {
        return owner();
      } else {
        return ERC721Upgradeable.ownerOf(_tokenId);
      }
    }
  }

  function approve(address to, uint256 tokenId) public virtual override {
    address owner = ownerOf(tokenId);
    require(to != owner, "ERC721: approval to current owner");

    require(
      _msgSender() == owner || isApprovedForAll(owner, _msgSender()),
      "ERC721: approve caller is not owner nor approved for all"
    );

    _approve(to, tokenId);
  }

  function _isApprovedOrOwner(address _spender, uint256 _tokenId) internal view virtual override returns (bool) {
    address owner = ownerOf(_tokenId);
    return (_spender == owner || getApproved(_tokenId) == _spender || isApprovedForAll(owner, _spender));
  }

  /**
   * @dev Approve `to` to operate on `tokenId`
   *
   * Emits an {Approval} event.
   */
  function _approve(address to, uint256 tokenId) internal override {
    _tokenApprovals[tokenId] = to;
    emit Approval(ownerOf(tokenId), to, tokenId);
  }

  /**
   * @dev See {IERC721-getApproved}.
   */
  function getApproved(uint256 _tokenId) public view virtual override returns (address) {
    address receiver = royaltyReceivers[_tokenId];
    (bool wasBatchMinted, , ) = _batchMintInfo(_tokenId);
    bool exists = (wasBatchMinted || receiver != address(0)) && !tokensBurned[_tokenId];

    require(exists, "ERC721: approved query for nonexistent token");

    return _tokenApprovals[_tokenId];
  }

  function _transfer(address _from, address _to, uint256 _tokenId) internal virtual override {
    require(_tokenId != 0);

    (bool wasBatchMinted, , ) = _batchMintInfo(_tokenId);

    if (wasBatchMinted && !ERC721Upgradeable._exists(_tokenId) && !tokensBurned[_tokenId]) {
      _mint(_from, _tokenId);
    }

    // Clear custom approval mapping to prevent stale approvals
    _tokenApprovals[_tokenId] = address(0);

    ERC721Upgradeable._transfer(_from, _to, _tokenId);
  }

  function totalSupply() public view virtual returns (uint256) {
    return tokenIdCounter.current();
  }

  function _batchMintInfo(
    uint256 _tokenId
  ) internal view returns (bool _wasBatchMinted, uint256 _batchIndex, string memory _baseTokenUri) {
    for (uint256 i = 0; i < mintBatches.length; i++) {
      if (_tokenId >= mintBatches[i].startTokenId && _tokenId <= mintBatches[i].endTokenId) {
        return (true, i, mintBatches[i].baseURI);
      }
    }

    return (false, 0, "");
  }

  /**
   * @dev Returns the start and end token IDs and base URI for a specific batch.
   */
  function getBatchInfo(
    uint256 _batchIndex
  ) external view returns (uint256 startTokenId, uint256 endTokenId, string memory baseURI) {
    require(_batchIndex < mintBatches.length, "Batch index out of bounds");

    MintBatch memory batch = mintBatches[_batchIndex];
    return (batch.startTokenId, batch.endTokenId, batch.baseURI);
  }

  /**
   * @dev Returns the total number of batches.
   */
  function getBatchCount() external view returns (uint256) {
    return mintBatches.length;
  }

  /**
   * @dev See {IERC165-supportsInterface}.
   */
  function supportsInterface(
    bytes4 interfaceId
  ) public view virtual override(ERC165Upgradeable, ERC2981Upgradeable, ERC721Upgradeable) returns (bool) {
    return
      interfaceId == type(ITokenCreator).interfaceId ||
      ERC165Upgradeable.supportsInterface(interfaceId) ||
      ERC2981Upgradeable.supportsInterface(interfaceId) ||
      ERC721Upgradeable.supportsInterface(interfaceId);
  }

  function updateTokenURI(uint256 _tokenId, string calldata _newURI) external ifNotDisabled {
    require(msg.sender == tokenCreator(_tokenId), "Only token creator can update URI");
    require(!tokenURIsLocked, "Token URIs are locked");
    require(_exists(_tokenId) || _isBatchMintedToken(_tokenId), "Token does not exist");

    (bool wasBatchMinted, , ) = _batchMintInfo(_tokenId);

    if (wasBatchMinted) {
      _overriddenBatchURIs[_tokenId] = _newURI;
    } else {
      _tokenURIs[_tokenId] = _newURI;
    }

    emit TokenURIUpdated(_tokenId, _newURI);
  }

  function updateBatchBaseURI(uint256 _batchIndex, string calldata _newBaseURI) external onlyOwner ifNotDisabled {
    require(!tokenURIsLocked, "Token URIs are locked");
    require(_batchIndex < mintBatches.length, "Batch index out of bounds");

    mintBatches[_batchIndex].baseURI = _newBaseURI;

    emit BatchBaseURIUpdated(_batchIndex, _newBaseURI);
  }

  function lockTokenURIs() external onlyOwner {
    require(!tokenURIsLocked, "Token URIs are already locked");

    tokenURIsLocked = true;

    emit TokenURIsLocked();
  }

  function areTokenURIsLocked() external view returns (bool) {
    return tokenURIsLocked;
  }

  function _isBatchMintedToken(uint256 _tokenId) internal view returns (bool) {
    (bool wasBatchMinted, , ) = _batchMintInfo(_tokenId);
    return wasBatchMinted && !tokensBurned[_tokenId];
  }
}
