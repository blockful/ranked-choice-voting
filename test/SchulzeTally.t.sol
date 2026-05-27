// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {SchulzeTally} from "../src/libraries/SchulzeTally.sol";

contract SchulzeTallyTest is Test {
    // Helper to build a flat matrix from row-major args.
    function _m(uint256 c, int256[] memory flat) internal pure returns (int256[] memory) {
        require(flat.length == c * c, "len");
        return flat;
    }

    function test_strongestPaths_simpleTwoCandidates() public pure {
        // 2 candidates: A beats B with weight 100. d[0][1]=100, d[1][0]=0.
        int256[] memory d = new int256[](4);
        d[0 * 2 + 1] = 100;
        int256[] memory p = SchulzeTally.computeStrongestPaths(d, 2);
        assertEq(p[0 * 2 + 1], 100);
        assertEq(p[1 * 2 + 0], 0);
    }

    function test_strongestPaths_wikipediaExample() public pure {
        // From https://en.wikipedia.org/wiki/Schulze_method (the canonical 5-candidate, 45-voter example).
        // Candidates A=0, B=1, C=2, D=3, E=4. Pairwise matrix d:
        //         A    B    C    D    E
        //   A  [  0,  20,  26,  30,  22]
        //   B  [ 25,   0,  16,  33,  18]
        //   C  [ 19,  29,   0,  17,  24]
        //   D  [ 15,  12,  28,   0,  14]
        //   E  [ 23,  27,  21,  31,   0]
        // Expected strongest paths from Wikipedia:
        //         A    B    C    D    E
        //   A  [  0,  28,  28,  30,  24]
        //   B  [ 25,   0,  28,  33,  24]
        //   C  [ 25,  29,   0,  29,  24]
        //   D  [ 25,  28,  28,   0,  24]
        //   E  [ 25,  28,  28,  31,   0]
        uint256 c = 5;
        int256[] memory d = new int256[](25);
        int256[5][5] memory dArr = [
            [int256(0), 20, 26, 30, 22],
            [int256(25), 0, 16, 33, 18],
            [int256(19), 29, 0, 17, 24],
            [int256(15), 12, 28, 0, 14],
            [int256(23), 27, 21, 31, 0]
        ];
        for (uint256 i = 0; i < 5; i++) for (uint256 j = 0; j < 5; j++) d[i * c + j] = dArr[i][j];

        int256[] memory p = SchulzeTally.computeStrongestPaths(d, c);

        int256[5][5] memory expected = [
            [int256(0), 28, 28, 30, 24],
            [int256(25), 0, 28, 33, 24],
            [int256(25), 29, 0, 29, 24],
            [int256(25), 28, 28, 0, 24],
            [int256(25), 28, 28, 31, 0]
        ];
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = 0; j < 5; j++) {
                assertEq(p[i * c + j], expected[i][j], string.concat("p[", vm.toString(i), "][", vm.toString(j), "]"));
            }
        }

        uint256[] memory scores = SchulzeTally.computeScores(p, c);
        // Wikipedia's expected order: E > A > C > B > D. Counts: E beats 4, A beats 3, C beats 2, B beats 1, D beats 0.
        assertEq(scores[4], 4);
        assertEq(scores[0], 3);
        assertEq(scores[2], 2);
        assertEq(scores[1], 1);
        assertEq(scores[3], 0);

        uint8[] memory ranking = SchulzeTally.sortRanking(scores);
        assertEq(ranking[0], 4); // E
        assertEq(ranking[1], 0); // A
        assertEq(ranking[2], 2); // C
        assertEq(ranking[3], 1); // B
        assertEq(ranking[4], 3); // D
    }

    function test_strongestPaths_emptyMatrix() public pure {
        int256[] memory d = new int256[](9);
        int256[] memory p = SchulzeTally.computeStrongestPaths(d, 3);
        for (uint256 i = 0; i < 9; i++) assertEq(p[i], 0);
        uint256[] memory scores = SchulzeTally.computeScores(p, 3);
        for (uint256 i = 0; i < 3; i++) assertEq(scores[i], 0);
    }

    function test_scores_condorcetWinner() public pure {
        // 3 candidates; A beats B and C; B beats C. A is a Condorcet winner.
        uint256 c = 3;
        int256[] memory d = new int256[](9);
        d[0 * c + 1] = 60;
        d[1 * c + 0] = 40;
        d[0 * c + 2] = 70;
        d[2 * c + 0] = 30;
        d[1 * c + 2] = 55;
        d[2 * c + 1] = 45;
        int256[] memory p = SchulzeTally.computeStrongestPaths(d, c);
        uint256[] memory scores = SchulzeTally.computeScores(p, c);
        assertEq(scores[0], 2);
        assertEq(scores[1], 1);
        assertEq(scores[2], 0);
    }

    function test_sortRanking_indexFallbackOnTie() public pure {
        uint256[] memory scores = new uint256[](3);
        uint8[] memory r = SchulzeTally.sortRanking(scores);
        assertEq(r[0], 0);
        assertEq(r[1], 1);
        assertEq(r[2], 2);
    }

    function test_sortRanking_strictScoreOrder() public pure {
        uint256[] memory scores = new uint256[](3);
        scores[0] = 1;
        scores[1] = 3;
        scores[2] = 2;
        uint8[] memory r = SchulzeTally.sortRanking(scores);
        assertEq(r[0], 1);
        assertEq(r[1], 2);
        assertEq(r[2], 0);
    }

    function test_sortRanking_singleCandidate() public pure {
        uint256[] memory scores = new uint256[](1);
        uint8[] memory r = SchulzeTally.sortRanking(scores);
        assertEq(r.length, 1);
        assertEq(r[0], 0);
    }
}
