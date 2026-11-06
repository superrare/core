// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ICartRoutePolicy} from "./ICartRoutePolicy.sol";

/// @notice Default-deny validation for the Universal Router command families used by Cart.
/// @dev Cart deliberately does not reimplement Universal Router planning. This policy restricts recipients and V4 settlement actions. Pool selection and
///      swap pricing remain the transaction builder's responsibility.
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

    /// @inheritdoc ICartRoutePolicy
    function validate(bytes calldata commands, bytes[] calldata inputs)
        external
        pure
        override
        returns (address[] memory assets)
    {
        if (commands.length != inputs.length) {
            revert CommandInputLengthMismatch(commands.length, inputs.length);
        }
        if (commands.length == 0) revert EmptyRoute();
        assets = new address[](commands.length * 2);
        uint256 count;
        for (uint256 i; i < commands.length; ++i) {
            uint8 command = uint8(commands[i]);
            if ((command & COMMAND_FLAGS_MASK) != 0) revert CommandFlagsNotAllowed(i, commands[i]);
            if (command == V2_SWAP_EXACT_IN || command == V2_SWAP_EXACT_OUT) {
                (address recipient,,, address[] memory path,) =
                    abi.decode(inputs[i], (address, uint256, uint256, address[], bool));
                _recipient(i, recipient, false);
                if (path.length < 2) revert InvalidRouteInput(i);
                assets[count++] = path[0];
                assets[count++] = path[path.length - 1];
            } else if (command == V3_SWAP_EXACT_IN || command == V3_SWAP_EXACT_OUT) {
                (address recipient,,, bytes memory path,) =
                    abi.decode(inputs[i], (address, uint256, uint256, bytes, bool));
                _recipient(i, recipient, false);
                if (path.length < 43 || (path.length - 20) % 23 != 0) revert InvalidRouteInput(i);
                address first;
                address last;
                assembly ("memory-safe") {
                    first := shr(96, mload(add(path, 32)))
                    last := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
                }
                assets[count++] = first;
                assets[count++] = last;
            } else if (command == PERMIT2_TRANSFER_FROM) {
                (address token, address recipient,) = abi.decode(inputs[i], (address, address, uint160));
                if (recipient != address(2)) revert InvalidRouteRecipient(i, recipient);
                assets[count++] = token;
            } else if (command == SWEEP) {
                (address token, address recipient,) = abi.decode(inputs[i], (address, address, uint256));
                _recipient(i, recipient, false);
                assets[count++] = token;
            } else if (command == WRAP_ETH || command == UNWRAP_WETH) {
                (address recipient,) = abi.decode(inputs[i], (address, uint256));
                _recipient(i, recipient, true);
            } else if (command == V4_SWAP) {
                (bytes memory actions, bytes[] memory params) = abi.decode(inputs[i], (bytes, bytes[]));
                // SETTLE_ALL pays only actual debt. TAKE_ALL delivers all output to the caller.
                // Excluding other actions prevents arbitrary recipients and partial withdrawals.
                if (
                    actions.length != 3 || params.length != 3 || uint8(actions[0]) < 6 || uint8(actions[0]) > 9
                        || actions[1] != 0x0c || actions[2] != 0x0f
                ) {
                    revert InvalidRouteInput(i);
                }
                (address input,) = abi.decode(params[1], (address, uint256));
                (address output,) = abi.decode(params[2], (address, uint256));
                assets[count++] = input;
                assets[count++] = output;
            } else {
                revert CommandNotAllowed(i, commands[i]);
            }
        }
        assembly ("memory-safe") { mstore(assets, count) }
    }

    /// @dev Universal Router's MSG_SENDER alias resolves to Cart, including through delegatecall.
    function _recipient(uint256 index, address recipient, bool allowRouter) private pure {
        if (recipient != address(1) && !(allowRouter && recipient == address(2))) {
            revert InvalidRouteRecipient(index, recipient);
        }
    }
}
