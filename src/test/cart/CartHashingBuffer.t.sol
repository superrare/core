// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import {ICart} from "../../cart/ICart.sol";
import {CartHashing} from "../../cart/CartHashing.sol";

/// @dev Reference retains the original ABI encoding rather than the optimized memory layout.
contract CartOrderLineHashReference {
    function hashOrderLines(ICart.OrderLine[] calldata lines) external pure returns (bytes32) {
        bytes32 typeHash = keccak256(
            "OrderLine(bytes32 sku,bytes32 listingDigest,uint8 fulfillmentKind,uint256 quantity,address settlementCurrency,uint256 amount,address paymentRecipient)"
        );
        bytes32[] memory hashes = new bytes32[](lines.length);
        for (uint256 i; i < lines.length; ++i) {
            ICart.OrderLine calldata line = lines[i];
            hashes[i] = keccak256(abi.encode(
                typeHash, line.sku, line.listingDigest, line.fulfillmentKind,
                line.quantity, line.settlementCurrency, line.amount, line.paymentRecipient
            ));
        }
        return keccak256(abi.encodePacked(hashes));
    }
}

contract CartOrderLineHashCandidate {
    function hashOrderLines(ICart.OrderLine[] calldata lines) external pure returns (bytes32) {
        return CartHashing.hashOrderLines(lines);
    }
}

contract CartHashingBufferTest is Test {
    CartOrderLineHashReference private referenceHash;
    CartOrderLineHashCandidate private candidate;

    function setUp() public {
        referenceHash = new CartOrderLineHashReference();
        candidate = new CartOrderLineHashCandidate();
    }

    function testFuzzOrderLineHashesMatch(bytes32 seed, uint8 rawCount) public {
        ICart.OrderLine[] memory lines = makeLines(seed, uint256(rawCount) % 129);
        assertEq(candidate.hashOrderLines(lines), referenceHash.hashOrderLines(lines));
    }

    function testEmptyOrderLinesHash() public {
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](0);
        assertEq(candidate.hashOrderLines(lines), keccak256(""));
    }

    function testOrderLineHashBoundariesAndOrder() public {
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = ICart.OrderLine(bytes32(0), bytes32(0), ICart.FulfillmentKind.NONE, 0, address(0), 0, address(0));
        lines[1] = ICart.OrderLine(bytes32(type(uint256).max), bytes32(type(uint256).max), ICart.FulfillmentKind.CURRENCY_SWAP,
            type(uint256).max, address(type(uint160).max), type(uint256).max, address(type(uint160).max));
        bytes32 original = candidate.hashOrderLines(lines);
        assertEq(original, referenceHash.hashOrderLines(lines));
        ICart.OrderLine memory first = lines[0];
        lines[0] = lines[1];
        lines[1] = first;
        assertEq(candidate.hashOrderLines(lines), referenceHash.hashOrderLines(lines));
        assertTrue(candidate.hashOrderLines(lines) != original);
    }

    function testMalformedOrderLineFieldsMatch() public {
        // Array starts after selector, offset, and length. Offsets below select enum and addresses.
        uint256[3] memory offsets = [uint256(132), uint256(196), uint256(260)];
        for (uint256 i; i < offsets.length; ++i) {
            bytes memory payload = abi.encodeWithSelector(referenceHash.hashOrderLines.selector, makeLines(bytes32(uint256(17)), 1));
            uint256 offset = offsets[i];
            uint256 value = i == 0 ? 255 : (uint256(1) << 200) | 17;
            assembly ("memory-safe") {
                mstore(add(add(payload, 32), offset), value)
            }
            (bool referenceSuccess, bytes memory expected) = address(referenceHash).staticcall(payload);
            (bool actualSuccess, bytes memory actual) = address(candidate).staticcall(payload);
            assertEq(actualSuccess, referenceSuccess);
            assertEq(actual, expected);
        }
    }

    function makeLines(bytes32 seed, uint256 count) private pure returns (ICart.OrderLine[] memory lines) {
        lines = new ICart.OrderLine[](count);
        for (uint256 i; i < count; ++i) {
            bytes32 h = keccak256(abi.encode(seed, i));
            lines[i] = ICart.OrderLine(h, keccak256(abi.encode(h)), ICart.FulfillmentKind(uint256(h) % 7),
                uint256(h), address(uint160(uint256(h))), uint256(h), address(uint160(uint256(keccak256(abi.encode(h))))));
        }
    }
}
