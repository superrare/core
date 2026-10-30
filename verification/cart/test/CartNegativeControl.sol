// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartSettlementProof} from "./CartSettlementProof.t.sol";

/// @dev Select explicitly; this method is intentionally false and excluded from normal test discovery.
contract CartNegativeControl is CartSettlementProof {
    function checkWrongPayout() public {
        testNativeGroupedPayout(11, 7, 3, 5, 13);
        assert(PAYEE.balance == 19);
    }
}
