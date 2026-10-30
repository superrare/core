// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Script, console} from "forge-std/Script.sol";

import {CartLens} from "../../src/cart/CartLens.sol";
import {NetworkConfig} from "../NetworkConfig.s.sol";

/// @title CartLensDeploy
/// @notice Deploys the stateless Cart integration lens independently of the Cart settlement suite.
contract CartLensDeploy is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory network = NetworkConfig.chainName(block.chainid);

        vm.startBroadcast(privateKey);
        CartLens lens = new CartLens();
        vm.stopBroadcast();

        console.log("Network:", network);
        console.log("Chain ID:", block.chainid);
        console.log("Cart lens:", address(lens));
    }
}
