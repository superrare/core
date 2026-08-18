// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ICartRoutePolicy} from "./ICartRoutePolicy.sol";

/// @notice Default-deny validation for the Universal Router swap commands used by Cart.
/// @dev Deployed as its own contract so Cart calls it externally: the call boundary both keeps the
///      policy out of Cart's EIP-170 budget and gives Cart a natural `try`/`catch` seam for tagging
///      a policy failure with the Order Line that produced it. Cart owns all input funds and receives
///      every route output, so the policy deliberately does not admit Permit2, transfer, sweep,
///      sub-plan, or NFT-marketplace commands. V4 is limited to swap/settle-all/take-all plans.
contract CartRoutePolicy is ICartRoutePolicy {
    uint8 private constant V3_SWAP_EXACT_IN = 0x00;
    uint8 private constant V3_SWAP_EXACT_OUT = 0x01;
    uint8 private constant V2_SWAP_EXACT_IN = 0x08;
    uint8 private constant V2_SWAP_EXACT_OUT = 0x09;
    uint8 private constant V4_SWAP = 0x10;

    uint8 private constant V4_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 private constant V4_SWAP_EXACT_IN = 0x07;
    uint8 private constant V4_SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 private constant V4_SWAP_EXACT_OUT = 0x09;
    uint8 private constant V4_SETTLE_ALL = 0x0c;
    uint8 private constant V4_TAKE_ALL = 0x0f;

    uint8 private constant COMMAND_TYPE_MASK = 0x3f;
    uint8 private constant COMMAND_FLAGS_MASK = 0xc0;

    address private constant MSG_SENDER = address(0x1);

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct ExactInputParams {
        address currencyIn;
        PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    struct ExactOutputParams {
        address currencyOut;
        PathKey[] path;
        uint128 amountOut;
        uint128 amountInMaximum;
    }

    function validate(
        bytes calldata commands,
        bytes[] calldata inputs,
        address expectedInput,
        address[] calldata expectedOutputs
    ) external pure override returns (Summary memory summary) {
        address[] memory outputs = new address[](expectedOutputs.length);
        for (uint256 i = 0; i < expectedOutputs.length; ++i) {
            outputs[i] = expectedOutputs[i];
        }
        return _validate(commands, inputs, expectedInput, outputs);
    }

    function _validate(
        bytes calldata commands,
        bytes[] calldata inputs,
        address expectedInput,
        address[] memory expectedOutputs
    ) private pure returns (Summary memory summary) {
        // Require one encoded input for every command and reject an empty route.
        if (commands.length == 0 || commands.length != inputs.length) {
            revert CommandInputLengthMismatch(commands.length, inputs.length);
        }

        bool modeSet;
        for (uint256 i = 0; i < commands.length; ++i) {
            // Read the command byte so its flags and command type can be checked separately.
            uint8 raw = uint8(commands[i]);
            // Cart does not allow optional Universal Router command flags.
            if ((raw & COMMAND_FLAGS_MASK) != 0) {
                revert CommandFlagsNotAllowed(i, commands[i]);
            }

            uint8 command = raw & COMMAND_TYPE_MASK;
            // Allow only decoded V2, V3, and V4 swap commands.
            if (
                command != V3_SWAP_EXACT_IN && command != V3_SWAP_EXACT_OUT && command != V2_SWAP_EXACT_IN
                    && command != V2_SWAP_EXACT_OUT && command != V4_SWAP
            ) {
                revert CommandNotAllowed(i, commands[i]);
            }

            if (command == V4_SWAP) {
                (bool v4ExactInput, address v4Input, address v4Output, uint256 v4InputAmount, uint256 v4OutputAmount) =
                    _validateV4(inputs[i], i);
                if (modeSet && v4ExactInput != summary.exactInput) revert InvalidRouteMode(i);
                if (!modeSet) {
                    summary.exactInput = v4ExactInput;
                    modeSet = true;
                }
                if (v4Input != expectedInput) revert RouteEndpointMismatch(i, v4Input, expectedInput);
                if (!_contains(expectedOutputs, v4Output)) {
                    address expected = expectedOutputs.length == 1 ? expectedOutputs[0] : address(0);
                    revert RouteEndpointMismatch(i, v4Output, expected);
                }
                summary.inputAmount += v4InputAmount;
                summary.outputAmount += v4OutputAmount;
                continue;
            }

            bool exactInput = command == V3_SWAP_EXACT_IN || command == V2_SWAP_EXACT_IN;
            // All commands in one route must use the same exact-input or exact-output mode.
            if (modeSet && exactInput != summary.exactInput) revert InvalidRouteMode(i);
            if (!modeSet) {
                // Use the first command to set the route mode.
                summary.exactInput = exactInput;
                modeSet = true;
            }

            address recipient;
            address pathInput;
            address pathOutput;
            uint256 amount;
            bool payerIsUser;

            if (command == V3_SWAP_EXACT_IN) {
                // Decode a V3 exact-input command and read the first and last path tokens.
                bytes memory path;
                (recipient, amount,, path, payerIsUser) =
                    abi.decode(inputs[i], (address, uint256, uint256, bytes, bool));
                (pathInput, pathOutput) = _v3Endpoints(path, i);
            } else if (command == V3_SWAP_EXACT_OUT) {
                // Decode a V3 exact-output command and read its reversed path endpoints.
                bytes memory path;
                uint256 amountOut;
                (recipient, amountOut, amount, path, payerIsUser) =
                    abi.decode(inputs[i], (address, uint256, uint256, bytes, bool));
                (pathInput, pathOutput) = _v3Endpoints(path, i);
                // Universal Router's V3 exact-output path is encoded in reverse order.
                (pathInput, pathOutput) = (pathOutput, pathInput);
                // Add the exact output requested by this command.
                summary.outputAmount += amountOut;
            } else if (command == V2_SWAP_EXACT_IN) {
                // Decode a V2 exact-input command and read the first and last path tokens.
                address[] memory path;
                (recipient, amount,, path, payerIsUser) =
                    abi.decode(inputs[i], (address, uint256, uint256, address[], bool));
                (pathInput, pathOutput) = _v2Endpoints(path, i);
            } else {
                // Decode a V2 exact-output command and read the first and last path tokens.
                address[] memory path;
                uint256 amountOut;
                (recipient, amountOut, amount, path, payerIsUser) =
                    abi.decode(inputs[i], (address, uint256, uint256, address[], bool));
                (pathInput, pathOutput) = _v2Endpoints(path, i);
                // Add the exact output requested by this command.
                summary.outputAmount += amountOut;
            }

            // Force every swap to send output to Universal Router's MSG_SENDER placeholder.
            if (recipient != MSG_SENDER) revert InvalidRouteRecipient(i, recipient);
            // Force the router to take input from Cart through the user-payer flag.
            if (!payerIsUser) revert InvalidPayer(i);
            // Do not accept a command that requests or permits zero input.
            if (amount == 0) revert InvalidCommandInput(i);
            // The complete route must start with the payment token.
            if (pathInput != expectedInput) revert RouteEndpointMismatch(i, pathInput, expectedInput);
            // The complete order-wide plan may end in any signed settlement token.
            if (!_contains(expectedOutputs, pathOutput)) {
                address expected = expectedOutputs.length == 1 ? expectedOutputs[0] : address(0);
                revert RouteEndpointMismatch(i, pathOutput, expected);
            }

            // Add this command's input amount to the route total.
            summary.inputAmount += amount;
        }
    }

    function _validateV4(bytes calldata input, uint256 commandIndex)
        private
        pure
        returns (bool exactInput, address pathInput, address pathOutput, uint256 inputAmount, uint256 outputAmount)
    {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        if (actions.length != 3 || params.length != 3) revert InvalidPath(commandIndex);

        bool swapSeen;
        bool settleSeen;
        bool takeSeen;
        for (uint256 j = 0; j < actions.length; ++j) {
            uint8 action = uint8(actions[j]);
            if (action == V4_SWAP_EXACT_IN_SINGLE) {
                if (swapSeen) revert InvalidPath(commandIndex);
                ExactInputSingleParams memory swap = abi.decode(params[j], (ExactInputSingleParams));
                (pathInput, pathOutput) = swap.zeroForOne
                    ? (swap.poolKey.currency0, swap.poolKey.currency1)
                    : (swap.poolKey.currency1, swap.poolKey.currency0);
                inputAmount = swap.amountIn;
                exactInput = true;
                swapSeen = true;
            } else if (action == V4_SWAP_EXACT_IN) {
                if (swapSeen) revert InvalidPath(commandIndex);
                ExactInputParams memory swap = abi.decode(params[j], (ExactInputParams));
                if (swap.path.length == 0) revert InvalidPath(commandIndex);
                pathInput = swap.currencyIn;
                pathOutput = swap.path[swap.path.length - 1].intermediateCurrency;
                inputAmount = swap.amountIn;
                exactInput = true;
                swapSeen = true;
            } else if (action == V4_SWAP_EXACT_OUT_SINGLE) {
                if (swapSeen) revert InvalidPath(commandIndex);
                ExactOutputSingleParams memory swap = abi.decode(params[j], (ExactOutputSingleParams));
                (pathInput, pathOutput) = swap.zeroForOne
                    ? (swap.poolKey.currency0, swap.poolKey.currency1)
                    : (swap.poolKey.currency1, swap.poolKey.currency0);
                inputAmount = swap.amountInMaximum;
                outputAmount = swap.amountOut;
                swapSeen = true;
            } else if (action == V4_SWAP_EXACT_OUT) {
                if (swapSeen) revert InvalidPath(commandIndex);
                ExactOutputParams memory swap = abi.decode(params[j], (ExactOutputParams));
                if (swap.path.length == 0) revert InvalidPath(commandIndex);
                pathOutput = swap.currencyOut;
                pathInput = swap.path[swap.path.length - 1].intermediateCurrency;
                inputAmount = swap.amountInMaximum;
                outputAmount = swap.amountOut;
                swapSeen = true;
            } else if (action == V4_SETTLE_ALL) {
                if (settleSeen) revert InvalidPath(commandIndex);
                (address currency, uint256 maximum) = abi.decode(params[j], (address, uint256));
                if (swapSeen && (currency != pathInput || maximum != inputAmount)) {
                    revert RouteEndpointMismatch(commandIndex, currency, pathInput);
                }
                settleSeen = true;
            } else if (action == V4_TAKE_ALL) {
                if (takeSeen) revert InvalidPath(commandIndex);
                (address currency,) = abi.decode(params[j], (address, uint256));
                if (swapSeen && currency != pathOutput) {
                    revert RouteEndpointMismatch(commandIndex, currency, pathOutput);
                }
                takeSeen = true;
            } else {
                revert CommandNotAllowed(commandIndex, bytes1(action));
            }
        }
        if (!swapSeen || !settleSeen || !takeSeen || inputAmount == 0) revert InvalidCommandInput(commandIndex);

        // Settlement actions may precede the swap, so validate their currencies after decoding all actions.
        for (uint256 j = 0; j < actions.length; ++j) {
            uint8 action = uint8(actions[j]);
            if (action == V4_SETTLE_ALL) {
                (address currency, uint256 maximum) = abi.decode(params[j], (address, uint256));
                if (currency != pathInput) revert RouteEndpointMismatch(commandIndex, currency, pathInput);
                if (maximum != inputAmount) revert InvalidCommandInput(commandIndex);
            } else if (action == V4_TAKE_ALL) {
                (address currency,) = abi.decode(params[j], (address, uint256));
                if (currency != pathOutput) revert RouteEndpointMismatch(commandIndex, currency, pathOutput);
            }
        }
    }

    function _contains(address[] memory values, address target) private pure returns (bool) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == target) return true;
        }
        return false;
    }

    function _v3Endpoints(bytes memory path, uint256 index) private pure returns (address input, address output) {
        // A V3 path has one 20-byte token plus one 23-byte fee-and-token segment per hop.
        if (path.length < 43 || (path.length - 20) % 23 != 0) revert InvalidPath(index);
        assembly {
            // Read the first token and the final token from the packed path.
            input := shr(96, mload(add(path, 32)))
            output := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
        }
    }

    function _v2Endpoints(address[] memory path, uint256 index) private pure returns (address input, address output) {
        // A V2 path needs at least an input token and an output token.
        if (path.length < 2) revert InvalidPath(index);
        // The first and last addresses define the route endpoints.
        input = path[0];
        output = path[path.length - 1];
    }
}
