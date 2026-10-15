// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ICartRoutePolicy} from "./ICartRoutePolicy.sol";

/// @notice Shallow default-deny validation for the Universal Router command families used by Cart.
/// @dev Cart deliberately does not reimplement Universal Router planning. The router decodes and
///      validates command inputs; this policy only bounds the opaque program and excludes commands
///      that can move funds outside the supported settlement workflow.
contract CartRoutePolicy is ICartRoutePolicy {
    uint8 private constant V3_SWAP_EXACT_IN = 0x00;
    uint8 private constant V3_SWAP_EXACT_OUT = 0x01;
    uint8 private constant PERMIT2_TRANSFER_FROM = 0x02;
    uint8 private constant SWEEP = 0x04;
    uint8 private constant V2_SWAP_EXACT_IN = 0x08;
    uint8 private constant V2_SWAP_EXACT_OUT = 0x09;
    uint8 private constant WRAP_ETH = 0x0b;
    uint8 private constant UNWRAP_WETH = 0x0c;
    uint8 private constant V4_SWAP = 0x10;

    uint8 private constant COMMAND_FLAGS_MASK = 0xc0;
    uint256 public constant MAX_ROUTE_COMMANDS = 32;

    function validate(bytes calldata commands, bytes[] calldata inputs) external pure override {
        if (commands.length > MAX_ROUTE_COMMANDS) revert RouteTooManyCommands(commands.length);
        if (inputs.length > MAX_ROUTE_COMMANDS) revert RouteTooManyInputs(inputs.length);
        if (commands.length != inputs.length) {
            revert CommandInputLengthMismatch(commands.length, inputs.length);
        }
        if (commands.length == 0) revert EmptyRoute();

        for (uint256 i = 0; i < commands.length; ++i) {
            uint8 raw = uint8(commands[i]);
            if ((raw & COMMAND_FLAGS_MASK) != 0) {
                revert CommandFlagsNotAllowed(i, commands[i]);
            }

            if (
                raw != V3_SWAP_EXACT_IN && raw != V3_SWAP_EXACT_OUT && raw != PERMIT2_TRANSFER_FROM && raw != SWEEP
                    && raw != V2_SWAP_EXACT_IN && raw != V2_SWAP_EXACT_OUT && raw != WRAP_ETH && raw != UNWRAP_WETH
                    && raw != V4_SWAP
            ) {
                revert CommandNotAllowed(i, commands[i]);
            }
        }
    }
}
