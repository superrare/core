// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "openzeppelin-contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

import {Cart} from "../../cart/Cart.sol";
import {IPermit2Cart} from "../../cart/IPermit2Cart.sol";

contract CartTestWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface ICartTestMintableToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract CartTestRouter {
    ICartTestMintableToken internal outputToken;
    uint256 internal outputAmount;
    uint256 internal retainedAmount;
    bool internal useExistingBalance;
    address internal settlementPermit2;
    address internal settlementSink;
    address internal settlementInputToken;
    bool internal settlementMode;
    uint256 internal settlementInputAmount;
    uint256 public executeCalls;
    address[] internal multiOutputTokens;
    uint256[] internal multiOutputAmounts;
    address[] internal multiOutputRecipients;
    bool internal multiMode;
    address public observedPermit2;
    address public observedToken;
    uint256 public observedCartAllowance;
    uint160 public observedPermit2Allowance;
    uint256 public lastRouterValue;
    bytes public lastCommands;
    uint256 public lastInputCount;
    bool internal revertExecution;

    function configure(address token, uint256 output, uint256 retained, bool useExisting) external {
        outputToken = ICartTestMintableToken(token);
        outputAmount = output;
        retainedAmount = retained;
        useExistingBalance = useExisting;
        multiMode = false;
        settlementMode = false;
    }

    function configureSettlement(
        address permit2_,
        address sink_,
        address inputToken_,
        address outputToken_,
        uint256 inputAmount_,
        uint256 outputAmount_
    ) external {
        settlementPermit2 = permit2_;
        settlementSink = sink_;
        settlementInputToken = inputToken_;
        settlementInputAmount = inputAmount_;
        outputToken = ICartTestMintableToken(outputToken_);
        outputAmount = outputAmount_;
        settlementMode = true;
        multiMode = false;
    }

    function configureMulti(address[] calldata tokens, uint256[] calldata amounts) external {
        require(tokens.length == amounts.length, "length mismatch");
        delete multiOutputTokens;
        delete multiOutputAmounts;
        delete multiOutputRecipients;
        for (uint256 i = 0; i < tokens.length; ++i) {
            multiOutputTokens.push(tokens[i]);
            multiOutputAmounts.push(amounts[i]);
        }
        multiMode = true;
        settlementMode = false;
    }

    function configureMultiTo(address[] calldata tokens, uint256[] calldata amounts, address[] calldata recipients)
        external
    {
        require(tokens.length == amounts.length && tokens.length == recipients.length, "length mismatch");
        delete multiOutputTokens;
        delete multiOutputAmounts;
        delete multiOutputRecipients;
        for (uint256 i = 0; i < tokens.length; ++i) {
            multiOutputTokens.push(tokens[i]);
            multiOutputAmounts.push(amounts[i]);
            multiOutputRecipients.push(recipients[i]);
        }
        multiMode = true;
        settlementMode = false;
    }

    function configureApprovalObservation(address permit2_, address token_) external {
        observedPermit2 = permit2_;
        observedToken = token_;
    }

    function configureRevert(bool value) external {
        revertExecution = value;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256) external payable {
        executeCalls++;
        lastRouterValue = msg.value;
        lastCommands = commands;
        lastInputCount = inputs.length;
        if (observedPermit2 != address(0)) {
            observedCartAllowance = IERC20(observedToken).allowance(msg.sender, observedPermit2);
            (observedPermit2Allowance,,) =
                IPermit2Cart(observedPermit2).allowance(msg.sender, observedToken, address(this));
        }
        if (revertExecution) revert("router reverted");
        if (multiMode) {
            require(commands.length == inputs.length && commands.length != 0, "unexpected route");
            for (uint256 i = 0; i < multiOutputTokens.length; ++i) {
                address recipient = multiOutputRecipients.length == 0 ? msg.sender : multiOutputRecipients[i];
                if (multiOutputTokens[i] == address(0)) {
                    (bool success,) = recipient.call{value: multiOutputAmounts[i]}("");
                    require(success, "native output failed");
                } else {
                    ICartTestMintableToken(multiOutputTokens[i]).mint(recipient, multiOutputAmounts[i]);
                }
            }
            return;
        }
        if (settlementMode) {
            require(commands.length != 0 && commands.length == inputs.length, "unexpected route");
            uint256 totalOutput;
            for (uint256 i = 0; i < inputs.length; ++i) {
                require(commands[i] == bytes1(0x09), "unexpected command");
                (address recipient, uint256 amountOut,, address[] memory path, bool payerIsUser) =
                    abi.decode(inputs[i], (address, uint256, uint256, address[], bool));
                require(recipient == address(1) && payerIsUser, "invalid route input");
                require(
                    path.length == 2 && path[0] == settlementInputToken && path[1] == address(outputToken),
                    "invalid path"
                );
                totalOutput += amountOut;
            }

            CartTestPermit2(settlementPermit2)
                .transferFrom(msg.sender, settlementSink, uint160(settlementInputAmount), settlementInputToken);
            require(totalOutput == outputAmount, "unexpected output");
            require(outputToken.transfer(msg.sender, totalOutput), "router transfer failed");
            return;
        }

        if (useExistingBalance) {
            require(outputToken.transfer(msg.sender, outputAmount), "router transfer failed");
        } else {
            outputToken.mint(msg.sender, outputAmount);
        }
        if (retainedAmount != 0) outputToken.mint(address(this), retainedAmount);
    }

    receive() external payable {}
}

contract CartTestToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CartTestRevertingTransferToken is ERC20 {
    address internal rejectingRecipient;

    constructor() ERC20("Reverting Transfer Token", "RTT") {}

    function setRejectingRecipient(address recipient) external {
        rejectingRecipient = recipient;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != rejectingRecipient, "rejected recipient");
        return super.transfer(to, amount);
    }
}

contract CartTestFeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = amount == 0 ? 0 : 1;
        if (fee != 0) _burn(from, fee);
        super._transfer(from, to, amount - fee);
    }
}

contract CartTestPermit2 is IPermit2Cart {
    struct Approval {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    mapping(address => mapping(address => mapping(address => Approval))) internal approvals;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external override {
        Approval storage approval = approvals[msg.sender][token][spender];
        approval.amount = amount;
        approval.expiration = expiration;
    }

    /// @dev Minimal stateful transfer path used by CartTestRouter to model Permit2's
    ///      router-spender allowance and the underlying ERC-20 allowance from Cart.
    function transferFrom(address from, address to, uint160 amount, address token) external {
        Approval storage approval = approvals[from][token][msg.sender];
        require(approval.expiration >= block.timestamp && approval.amount >= amount, "permit2 allowance");
        approval.amount -= amount;
        require(IERC20(token).transferFrom(from, to, amount), "token transfer failed");
    }

    function allowance(address owner, address token, address spender)
        external
        view
        override
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        Approval memory approval = approvals[owner][token][spender];
        return (approval.amount, approval.expiration, approval.nonce);
    }
}

contract CartTestERC721 is ERC721 {
    constructor() ERC721("Cart NFT", "CNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract ReentrantERC721 is ERC721 {
    Cart internal immutable cart;

    bytes internal reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(Cart cart_) ERC721("Reentrant Cart NFT", "RCNFT") {
        cart = cart_;
    }

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function setReentryData(bytes calldata data) external {
        reentryData = data;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public override {
        _attemptReentry();
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721: caller is not owner nor approved");
        _safeTransfer(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public override {
        _attemptReentry();
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721: caller is not owner nor approved");
        _safeTransfer(from, to, tokenId, data);
    }

    function _attemptReentry() private {
        if (reentryData.length == 0) return;
        reentryAttempted = true;
        (reentrySucceeded,) = address(cart).call(reentryData);
    }
}

contract CartTestMintableERC721 is ERC721, Ownable {
    mapping(address => bool) internal minters;
    uint256 internal nextTokenId = 1;

    constructor() ERC721("Cart Mintable NFT", "CMNFT") {}

    function setMinter(address account, bool value) external onlyOwner {
        minters[account] = value;
    }

    function mintTo(address to) external returns (uint256 tokenId) {
        require(msg.sender == owner() || minters[msg.sender], "not minter");
        tokenId = nextTokenId++;
        _mint(to, tokenId);
    }
}

contract CartTestERC1155 is ERC1155, Ownable {
    mapping(address => bool) internal minters;

    constructor() ERC1155("") {}

    function setMinter(address account, bool value) external onlyOwner {
        minters[account] = value;
    }

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }

    function mintTo(address to, uint256 tokenId, uint256 amount) external {
        require(msg.sender == owner() || minters[msg.sender], "not minter");
        _mint(to, tokenId, amount, "");
    }
}

contract ReentrantERC1155 is ERC1155 {
    Cart internal immutable cart;

    bytes internal reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(Cart cart_) ERC1155("") {
        cart = cart_;
    }

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }

    function setReentryData(bytes calldata data) external {
        reentryData = data;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data) public override {
        _attemptReentry();
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not token owner or approved"
        );
        _safeTransferFrom(from, to, id, amount, data);
    }

    function _attemptReentry() private {
        if (reentryData.length == 0) return;
        reentryAttempted = true;
        (reentrySucceeded,) = address(cart).call(reentryData);
    }
}

contract RevertingPayoutRecipient {
    receive() external payable {
        revert("payout rejected");
    }
}

contract ReentrantSellerReceiver {
    Cart internal immutable cart;
    bytes32 internal rootDigest;

    bool public cancelRootCallSucceeded;
    bool public nonceCallSucceeded;

    constructor(Cart cart_, bytes32 rootDigest_) {
        cart = cart_;
        rootDigest = rootDigest_;
    }

    function approveCart(IERC721 token, address spender) external {
        token.setApprovalForAll(spender, true);
    }

    function setRootDigest(bytes32 rootDigest_) external {
        rootDigest = rootDigest_;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (cancelRootCallSucceeded,) = address(cart).call(abi.encodeCall(Cart.cancelListingRoot, (rootDigest)));
        (nonceCallSucceeded,) = address(cart).call(abi.encodeCall(Cart.invalidateListingNonce, ()));
        return this.onERC721Received.selector;
    }
}

contract ReentrantFulfillmentReceiver {
    Cart internal immutable cart;

    bytes internal reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(Cart cart_) {
        cart = cart_;
    }

    function setReentryData(bytes calldata data) external {
        reentryData = data;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _attemptReentry();
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        _attemptReentry();
        return this.onERC1155Received.selector;
    }

    function _attemptReentry() private {
        if (reentryData.length == 0) return;
        reentryAttempted = true;
        (reentrySucceeded,) = address(cart).call(reentryData);
    }
}
