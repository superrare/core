// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IPermit2Cart} from "cart-src/IPermit2Cart.sol";

/// @dev Explicit signature assumption: every supplied digest is authorized.
contract CartProofSigner {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/// @dev Standard exact-transfer ERC20 model; no fees, rebases, hooks or hostile behavior.
contract CartProofToken is ERC20 {
    constructor() ERC20("Proof token", "PROOF") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CartProofWETH is CartProofToken {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success);
    }
}

/// @dev Stateful model of both Permit2's spender allowance and underlying ERC20 spending.
contract CartProofPermit2 is IPermit2Cart {
    struct Approval {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }
    mapping(address => mapping(address => mapping(address => Approval))) internal approvals;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        approvals[msg.sender][token][spender].amount = amount;
        approvals[msg.sender][token][spender].expiration = expiration;
    }

    function allowance(address owner, address token, address spender) external view returns (uint160, uint48, uint48) {
        Approval memory a = approvals[owner][token][spender];
        return (a.amount, a.expiration, a.nonce);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Approval storage a = approvals[from][token][msg.sender];
        require(a.expiration >= block.timestamp && a.amount >= amount);
        a.amount -= amount;
        require(IERC20(token).transferFrom(from, to, amount));
    }
}

/// @dev Fixed exact-output route model, not a proof of Universal Router semantics.
contract CartProofRouter {
    CartProofPermit2 internal permit2;
    IERC20 internal input;
    IERC20 internal output;
    uint160 internal spend;
    uint256 internal deliver;
    address public constant SINK = address(0x6001);
    uint256 public observedCartAllowance;
    uint160 public observedPermit2Allowance;

    function configure(CartProofPermit2 p, IERC20 i, IERC20 o, uint160 s, uint256 d) external {
        permit2 = p;
        input = i;
        output = o;
        spend = s;
        deliver = d;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256) external payable {
        require(commands.length == 1 && commands[0] == 0x09 && inputs.length == 1);
        (address recipient, uint256 amountOut, uint256 maxInput, address[] memory path, bool payerIsUser) =
            abi.decode(inputs[0], (address, uint256, uint256, address[], bool));
        require(recipient == address(1) && payerIsUser && amountOut == deliver && maxInput == spend);
        require(path.length == 2 && path[0] == address(input) && path[1] == address(output));
        observedCartAllowance = input.allowance(msg.sender, address(permit2));
        (observedPermit2Allowance,,) = permit2.allowance(msg.sender, address(input), address(this));
        permit2.transferFrom(msg.sender, SINK, spend, address(input));
        require(output.transfer(msg.sender, deliver));
    }
}
