// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// solhint-disable no-console

import {console} from "forge-std/Script.sol";

import {NetworkConfig} from "../NetworkConfig.s.sol";
import {RareERC1155CheckoutExecutionModule} from "../../src/marketplace/RareERC1155CheckoutExecutionModule.sol";
import {RareERC1155Marketplace} from "../../src/marketplace/RareERC1155Marketplace.sol";
import {RareERC1155TradeExecutionModule} from "../../src/marketplace/RareERC1155TradeExecutionModule.sol";
import {RareERC1155ExecutionModuleScriptGuard} from "./RareERC1155ExecutionModuleScriptGuard.s.sol";

/// @title RareERC1155MarketplaceUpdate
/// @notice Deploys new ERC1155 marketplace logic/modules and points the configured marketplace proxy at them.
contract RareERC1155MarketplaceUpdate is RareERC1155ExecutionModuleScriptGuard {
    error NetworkAddressNotConfigured(string name, uint256 chainId);
    error MarketplaceUpdateVerificationFailed(bytes32 field, address expected, address actual);

    bytes32 private constant MARKETPLACE_IMPLEMENTATION_FIELD = "MARKETPLACE_IMPLEMENTATION";
    bytes32 private constant TRADE_EXECUTION_MODULE_FIELD = "TRADE_EXECUTION_MODULE";
    bytes32 private constant CHECKOUT_EXECUTION_MODULE_FIELD = "CHECKOUT_EXECUTION_MODULE";

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        NetworkConfig.Addresses memory config = NetworkConfig.getCurrent();
        address marketplaceProxy = _required(config.rareErc1155MarketplaceProxy, "rareErc1155MarketplaceProxy");

        vm.startBroadcast(privateKey);

        RareERC1155TradeExecutionModule tradeExecutionModule = new RareERC1155TradeExecutionModule();
        _validateExecutionModuleForScript(address(tradeExecutionModule));

        RareERC1155CheckoutExecutionModule checkoutExecutionModule = new RareERC1155CheckoutExecutionModule();
        _validateExecutionModuleForScript(address(checkoutExecutionModule));

        RareERC1155Marketplace marketplaceImplementation = new RareERC1155Marketplace();
        RareERC1155Marketplace marketplace = RareERC1155Marketplace(marketplaceProxy);

        marketplace.upgradeTo(address(marketplaceImplementation));
        marketplace.setTradeExecutionModule(address(tradeExecutionModule));
        marketplace.setCheckoutExecutionModule(address(checkoutExecutionModule));

        _verifyUpdated(
            marketplace,
            address(marketplaceImplementation),
            address(tradeExecutionModule),
            address(checkoutExecutionModule)
        );

        vm.stopBroadcast();

        console.log("Network:", NetworkConfig.chainName(block.chainid));
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("RareERC1155Marketplace proxy updated at:", marketplaceProxy);
        console.log("RareERC1155Marketplace implementation deployed at:", address(marketplaceImplementation));
        console.log("RareERC1155TradeExecutionModule deployed at:", address(tradeExecutionModule));
        console.log("RareERC1155CheckoutExecutionModule deployed at:", address(checkoutExecutionModule));
    }

    function _verifyUpdated(
        RareERC1155Marketplace _marketplace,
        address _marketplaceImplementation,
        address _tradeExecutionModule,
        address _checkoutExecutionModule
    ) private view {
        address actualMarketplaceImplementation = _implementation(address(_marketplace));
        if (actualMarketplaceImplementation != _marketplaceImplementation) {
            revert MarketplaceUpdateVerificationFailed(
                MARKETPLACE_IMPLEMENTATION_FIELD,
                _marketplaceImplementation,
                actualMarketplaceImplementation
            );
        }

        address actualTradeExecutionModule = _marketplace.getTradeExecutionModule();
        if (actualTradeExecutionModule != _tradeExecutionModule) {
            revert MarketplaceUpdateVerificationFailed(
                TRADE_EXECUTION_MODULE_FIELD,
                _tradeExecutionModule,
                actualTradeExecutionModule
            );
        }

        address actualCheckoutExecutionModule = _marketplace.getCheckoutExecutionModule();
        if (actualCheckoutExecutionModule != _checkoutExecutionModule) {
            revert MarketplaceUpdateVerificationFailed(
                CHECKOUT_EXECUTION_MODULE_FIELD,
                _checkoutExecutionModule,
                actualCheckoutExecutionModule
            );
        }
    }

    function _implementation(address _proxy) private view returns (address implementation) {
        bytes32 slotValue = vm.load(_proxy, ERC1967_IMPLEMENTATION_SLOT);
        implementation = address(uint160(uint256(slotValue)));
    }

    function _required(address _address, string memory _name) private view returns (address) {
        if (_address == address(0)) revert NetworkAddressNotConfigured(_name, block.chainid);
        return _address;
    }
}
