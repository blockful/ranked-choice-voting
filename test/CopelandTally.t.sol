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

    function test_computeScoresAndMargins_simpleWin() public pure {
        // 2 candidates, A beats B with weight 100 vs 0
        int256[] memory matrix = new int256[](4); // C=2 → 2*2
        matrix[0 * 2 + 1] = 100; // A > B = 100
        matrix[1 * 2 + 0] = 0;   // B > A = 0
        (int256[] memory scores, int256[] memory margins) = CopelandTally.computeScoresAndMargins(matrix, 2);
        assertEq(scores[0], 1);
        assertEq(scores[1], -1);
        assertEq(margins[0], 100);
        assertEq(margins[1], -100);
    }

    function test_computeScoresAndMargins_threeWayTie() public pure {
        // 3 candidates, each pair tied 50-50
        int256[] memory matrix = new int256[](9); // C=3 → 3*3
        matrix[0 * 3 + 1] = 50; matrix[1 * 3 + 0] = 50;
        matrix[0 * 3 + 2] = 50; matrix[2 * 3 + 0] = 50;
        matrix[1 * 3 + 2] = 50; matrix[2 * 3 + 1] = 50;
        (int256[] memory scores, int256[] memory margins) = CopelandTally.computeScoresAndMargins(matrix, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(scores[i], 0);
            assertEq(margins[i], 0);
        }
    }

    function test_computeScoresAndMargins_condorcetWinner() public pure {
        // 3 candidates, A beats both B and C; B beats C
        int256[] memory matrix = new int256[](9);
        matrix[0 * 3 + 1] = 60; matrix[1 * 3 + 0] = 40; // A>B 60-40
        matrix[0 * 3 + 2] = 70; matrix[2 * 3 + 0] = 30; // A>C 70-30
        matrix[1 * 3 + 2] = 55; matrix[2 * 3 + 1] = 45; // B>C 55-45
        (int256[] memory scores, int256[] memory margins) = CopelandTally.computeScoresAndMargins(matrix, 3);
        assertEq(scores[0], 2);  // A wins both
        assertEq(scores[1], 0);  // B wins one, loses one
        assertEq(scores[2], -2); // C loses both
        assertEq(margins[0], (60 - 40) + (70 - 30));   // +50
        assertEq(margins[1], (40 - 60) + (55 - 45));   // -10
        assertEq(margins[2], (30 - 70) + (45 - 55));   // -50
    }

    function test_computeScoresAndMargins_emptyMatrix() public pure {
        int256[] memory matrix = new int256[](9);
        (int256[] memory scores, int256[] memory margins) = CopelandTally.computeScoresAndMargins(matrix, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(scores[i], 0);
            assertEq(margins[i], 0);
        }
    }
}
