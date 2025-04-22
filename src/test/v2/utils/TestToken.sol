// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

contract TestToken is ERC20 {
  constructor() ERC20("Test Token", "TT") {
    _mint(msg.sender, 1000000 * 10 ** decimals());
  }

  function mint(address to, uint256 amount) public {
    _mint(to, amount);
  }
}
