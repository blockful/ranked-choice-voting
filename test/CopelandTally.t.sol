// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CopelandTally} from "../src/libraries/CopelandTally.sol";

contract CopelandTallyTest is Test {
    function test_sortRanking_strictScoreOrder() public pure {
        int256[] memory scores = new int256[](3);
        int256[] memory margins = new int256[](3);
        scores[0] = 1;  margins[0] = 0;
        scores[1] = 2;  margins[1] = 0;
        scores[2] = 0;  margins[2] = 0;
        uint8[] memory r = CopelandTally.sortRanking(scores, margins);
        assertEq(r[0], 1);
        assertEq(r[1], 0);
        assertEq(r[2], 2);
    }

    function test_sortRanking_marginTiebreaker() public pure {
        int256[] memory scores = new int256[](3);
        int256[] memory margins = new int256[](3);
        scores[0] = 1;  margins[0] = 5;
        scores[1] = 1;  margins[1] = 10;
        scores[2] = 1;  margins[2] = 1;
        uint8[] memory r = CopelandTally.sortRanking(scores, margins);
        assertEq(r[0], 1);
        assertEq(r[1], 0);
        assertEq(r[2], 2);
    }

    function test_sortRanking_indexFallback() public pure {
        int256[] memory scores = new int256[](3);
        int256[] memory margins = new int256[](3);
        // all tied → ascending index order
        uint8[] memory r = CopelandTally.sortRanking(scores, margins);
        assertEq(r[0], 0);
        assertEq(r[1], 1);
        assertEq(r[2], 2);
    }

    function test_sortRanking_negativeScores() public pure {
        int256[] memory scores = new int256[](3);
        int256[] memory margins = new int256[](3);
        scores[0] = -2; margins[0] = -10;
        scores[1] = 0;  margins[1] = 0;
        scores[2] = 2;  margins[2] = 10;
        uint8[] memory r = CopelandTally.sortRanking(scores, margins);
        assertEq(r[0], 2);
        assertEq(r[1], 1);
        assertEq(r[2], 0);
    }
}
