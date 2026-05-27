// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SchulzeVoting} from "../src/SchulzeVoting.sol";
import {IRankedChoiceVoting} from "../src/interfaces/IRankedChoiceVoting.sol";
import {MockVotesToken} from "./mocks/MockVotesToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract SchulzeVotingScenariosTest is Test {
    SchulzeVoting internal voting;
    MockVotesToken internal token;

    function setUp() public {
        voting = new SchulzeVoting();
        token = new MockVotesToken();
        vm.roll(block.number + 1);
    }

    function _cfg(uint8 c) internal view returns (IRankedChoiceVoting.ElectionConfig memory cfg) {
        bytes32[] memory cands = new bytes32[](c);
        for (uint8 i = 0; i < c; i++) {
            cands[i] = bytes32(uint256(i + 1));
        }
        cfg = IRankedChoiceVoting.ElectionConfig({
            candidates: cands,
            votingToken: IVotes(address(token)),
            snapshotBlock: block.number - 1,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            metadataURI: bytes32(0)
        });
    }

    function _setWeight(address voter, uint256 snapshotBlock, uint256 weight) internal {
        token.setPastVotes(voter, snapshotBlock, weight);
    }

    /// @dev Canonical Schulze example from Wikipedia: 45 voters in 8 groups, 5 candidates.
    ///      Expected ranking: E > A > C > B > D.
    ///      Each voter group is represented by one address whose voting weight equals
    ///      the group size — pairwise totals are identical to per-individual ballots.
    ///      Source: https://en.wikipedia.org/wiki/Schulze_method
    function test_wikipediaExample() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _cfg(5);
        uint256 id = voting.createElection(cfg);

        address[8] memory voters = [
            address(0x1001),
            address(0x1002),
            address(0x1003),
            address(0x1004),
            address(0x1005),
            address(0x1006),
            address(0x1007),
            address(0x1008)
        ];
        uint256[8] memory weights = [uint256(5), 5, 8, 3, 7, 2, 7, 8];
        uint8[5][8] memory rankings = [
            [uint8(0), 2, 1, 4, 3], // 5 voters: A C B E D
            [uint8(0), 3, 4, 2, 1], // 5 voters: A D E C B
            [uint8(1), 4, 3, 0, 2], // 8 voters: B E D A C
            [uint8(2), 0, 1, 4, 3], // 3 voters: C A B E D
            [uint8(2), 0, 4, 1, 3], // 7 voters: C A E B D
            [uint8(2), 1, 0, 3, 4], // 2 voters: C B A D E
            [uint8(3), 2, 4, 1, 0], // 7 voters: D C E B A
            [uint8(4), 1, 0, 3, 2] //  8 voters: E B A D C
        ];

        for (uint256 g = 0; g < 8; g++) {
            _setWeight(voters[g], cfg.snapshotBlock, weights[g]);
            uint8[] memory r = new uint8[](5);
            for (uint256 j = 0; j < 5; j++) {
                r[j] = rankings[g][j];
            }
            vm.prank(voters[g]);
            voting.castBallot(id, r);
        }

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 10)) {}
        voting.finalize(id);

        uint8[] memory ranking = voting.getRanking(id);
        assertEq(ranking.length, 5);
        assertEq(ranking[0], 4, "1st: E");
        assertEq(ranking[1], 0, "2nd: A");
        assertEq(ranking[2], 2, "3rd: C");
        assertEq(ranking[3], 1, "4th: B");
        assertEq(ranking[4], 3, "5th: D");
    }

    /// @dev A Condorcet winner (beats every other candidate head-to-head) must rank first.
    function test_condorcetWinnerRanksFirst() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _cfg(4);
        uint256 id = voting.createElection(cfg);

        address[5] memory voters = [address(0x11), address(0x12), address(0x13), address(0x14), address(0x15)];
        uint8[5] memory secondChoice = [1, 2, 3, 1, 2];

        for (uint256 i = 0; i < 5; i++) {
            _setWeight(voters[i], cfg.snapshotBlock, 100);
            uint8[] memory r = new uint8[](2);
            r[0] = 0;
            r[1] = secondChoice[i];
            vm.prank(voters[i]);
            voting.castBallot(id, r);
        }

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 10)) {}
        voting.finalize(id);

        uint8[] memory ranking = voting.getRanking(id);
        assertEq(ranking[0], 0, "Condorcet winner should rank first");
    }

    /// @dev Symmetric Condorcet cycle: A>B, B>C, C>A all with EQUAL margins.
    ///      Schulze's path-strength algorithm produces identical path strengths for all
    ///      three candidates (100 in each direction), so every candidate ties on Schulze
    ///      score (0). The ranking then falls back to ascending candidate index. Schulze
    ///      cannot invent asymmetry where none exists — see the asymmetric variant below
    ///      for a case where Schulze does resolve a cycle decisively.
    function test_condorcetCycleSymmetricStillTiesToIndex() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _cfg(3);
        uint256 id = voting.createElection(cfg);

        address grpAB = address(0x21);
        address grpBC = address(0x22);
        address grpCA = address(0x23);
        _setWeight(grpAB, cfg.snapshotBlock, 100);
        _setWeight(grpBC, cfg.snapshotBlock, 100);
        _setWeight(grpCA, cfg.snapshotBlock, 100);

        uint8[] memory ab = new uint8[](2);
        ab[0] = 0;
        ab[1] = 1;
        uint8[] memory bc = new uint8[](2);
        bc[0] = 1;
        bc[1] = 2;
        uint8[] memory ca = new uint8[](2);
        ca[0] = 2;
        ca[1] = 0;
        vm.prank(grpAB);
        voting.castBallot(id, ab);
        vm.prank(grpBC);
        voting.castBallot(id, bc);
        vm.prank(grpCA);
        voting.castBallot(id, ca);

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 10)) {}
        voting.finalize(id);

        uint8[] memory r = voting.getRanking(id);
        assertEq(r.length, 3);
        // Pairwise: d[0][1]=100, d[1][2]=100, d[2][0]=100, reverse all 0.
        // After Floyd-Warshall every off-diagonal p[i][j] = 100 → scores tie at 0.
        // Ranking falls back to ascending candidate index.
        assertEq(r[0], 0);
        assertEq(r[1], 1);
        assertEq(r[2], 2);
    }

    /// @dev Asymmetric cycle: Schulze resolves to a decisive winner.
    ///      Pairwise weights:
    ///        d[A][B]=30, d[B][A]=0
    ///        d[B][C]=25, d[C][B]=0
    ///        d[C][A]=20, d[A][C]=5
    ///      Floyd-Warshall yields strongest paths:
    ///        p[A][B]=30, p[B][A]=20
    ///        p[A][C]=25, p[C][A]=20
    ///        p[B][C]=25, p[C][B]=20
    ///      Schulze scores: A=2, B=1, C=0 → ranking [A, B, C].
    ///      A wins decisively despite being part of the original cycle (C beats A pairwise).
    function test_condorcetCycleAsymmetricResolves() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _cfg(3);
        uint256 id = voting.createElection(cfg);

        address ab30 = address(0x2001);
        _setWeight(ab30, cfg.snapshotBlock, 30);
        address bc25 = address(0x2002);
        _setWeight(bc25, cfg.snapshotBlock, 25);
        address ca20 = address(0x2003);
        _setWeight(ca20, cfg.snapshotBlock, 20);
        address ac5 = address(0x2004);
        _setWeight(ac5, cfg.snapshotBlock, 5);

        uint8[] memory ab = new uint8[](2);
        ab[0] = 0;
        ab[1] = 1;
        uint8[] memory bc = new uint8[](2);
        bc[0] = 1;
        bc[1] = 2;
        uint8[] memory ca = new uint8[](2);
        ca[0] = 2;
        ca[1] = 0;
        uint8[] memory ac = new uint8[](2);
        ac[0] = 0;
        ac[1] = 2;
        vm.prank(ab30);
        voting.castBallot(id, ab);
        vm.prank(bc25);
        voting.castBallot(id, bc);
        vm.prank(ca20);
        voting.castBallot(id, ca);
        vm.prank(ac5);
        voting.castBallot(id, ac);

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 10)) {}
        voting.finalize(id);

        uint8[] memory r = voting.getRanking(id);
        assertEq(r.length, 3);
        assertEq(r[0], 0, "A wins decisively despite cycle");
        assertEq(r[1], 1);
        assertEq(r[2], 2);
    }

    /// @dev Replaceable ballots: last vote stands.
    function test_replacementLastBallotWins() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _cfg(3);
        uint256 id = voting.createElection(cfg);
        address voter = address(0x31);
        _setWeight(voter, cfg.snapshotBlock, 50);

        uint8[] memory first = new uint8[](2);
        first[0] = 0;
        first[1] = 1;
        uint8[] memory second = new uint8[](2);
        second[0] = 2;
        second[1] = 1;
        vm.startPrank(voter);
        voting.castBallot(id, first);
        voting.castBallot(id, second);
        vm.stopPrank();

        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        voting.finalize(id);

        int256[][] memory M = voting.getPairwiseMatrix(id);
        // Only the second ballot contributes: 2>1 with weight 50
        assertEq(M[2][1], 50);
        assertEq(M[0][1], 0); // first ballot fully discarded
    }
}
