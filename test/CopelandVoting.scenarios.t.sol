// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CopelandVoting} from "../src/CopelandVoting.sol";
import {ICopelandVoting} from "../src/interfaces/ICopelandVoting.sol";
import {MockVotesToken} from "./mocks/MockVotesToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract CopelandVotingScenariosTest is Test {
    CopelandVoting internal voting;
    MockVotesToken internal token;

    function setUp() public {
        voting = new CopelandVoting();
        token = new MockVotesToken();
        vm.roll(block.number + 1);
    }

    function _cfg(uint8 c) internal view returns (ICopelandVoting.ElectionConfig memory cfg) {
        bytes32[] memory cands = new bytes32[](c);
        for (uint8 i = 0; i < c; i++) cands[i] = bytes32(uint256(i + 1));
        cfg = ICopelandVoting.ElectionConfig({
            candidates: cands,
            votingToken: IVotes(address(token)),
            snapshotBlock: block.number - 1,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            metadataURI: bytes32(0)
        });
    }

    /// @dev A Condorcet winner (beats every other candidate head-to-head) must rank first.
    function test_condorcetWinnerRanksFirst() public {
        ICopelandVoting.ElectionConfig memory cfg = _cfg(4);
        uint256 id = voting.createElection(cfg);

        // Make candidate 0 a Condorcet winner: every voter ranks 0 first.
        address[5] memory voters = [address(0x11), address(0x12), address(0x13), address(0x14), address(0x15)];
        uint8[5] memory secondChoice = [1, 2, 3, 1, 2];

        for (uint256 i = 0; i < 5; i++) {
            token.setPastVotes(voters[i], cfg.snapshotBlock, 100);
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

    /// @dev Condorcet cycle: A>B, B>C, C>A all with equal margins.
    /// Tiebreaker should produce a deterministic strict order.
    function test_condorcetCycleResolvedDeterministically() public {
        ICopelandVoting.ElectionConfig memory cfg = _cfg(3);
        uint256 id = voting.createElection(cfg);

        // Three voter groups
        address grpAB = address(0x21); // ranks A > B
        address grpBC = address(0x22); // ranks B > C
        address grpCA = address(0x23); // ranks C > A
        token.setPastVotes(grpAB, cfg.snapshotBlock, 100);
        token.setPastVotes(grpBC, cfg.snapshotBlock, 100);
        token.setPastVotes(grpCA, cfg.snapshotBlock, 100);

        uint8[] memory ab = new uint8[](2); ab[0] = 0; ab[1] = 1;
        uint8[] memory bc = new uint8[](2); bc[0] = 1; bc[1] = 2;
        uint8[] memory ca = new uint8[](2); ca[0] = 2; ca[1] = 0;
        vm.prank(grpAB); voting.castBallot(id, ab);
        vm.prank(grpBC); voting.castBallot(id, bc);
        vm.prank(grpCA); voting.castBallot(id, ca);

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 10)) {}
        voting.finalize(id);

        uint8[] memory r = voting.getRanking(id);
        assertEq(r.length, 3);
        // All three candidates tied on Copeland score (each 0: one win, one loss).
        // With Minimax tiebreak, each candidate's worst defeat is -100 (the pair they lost).
        // All tied on Minimax → falls back to candidate index ascending.
        assertEq(r[0], 0);
        assertEq(r[1], 1);
        assertEq(r[2], 2);
    }

    /// @dev ENS Service Provider-style: 12 candidates, 20 voters, varying partial ballots.
    function test_ensServiceProviderStyle() public {
        ICopelandVoting.ElectionConfig memory cfg = _cfg(12);
        uint256 id = voting.createElection(cfg);

        // 20 voters, varying weights
        for (uint160 vi = 1; vi <= 20; vi++) {
            address v = address(vi);
            uint256 weight = (uint256(vi) * 137) % 5000 + 1;
            token.setPastVotes(v, cfg.snapshotBlock, weight);
            // ballot length is 3-8, contents pseudo-random
            uint8 len = uint8(((vi * 7) % 6) + 3);
            uint8[] memory r = new uint8[](len);
            bool[] memory used = new bool[](12);
            uint8 placed = 0;
            uint256 seed = uint256(vi);
            while (placed < len) {
                seed = uint256(keccak256(abi.encode(seed)));
                uint8 idx = uint8(seed % 12);
                if (!used[idx]) {
                    used[idx] = true;
                    r[placed++] = idx;
                }
            }
            vm.prank(v);
            voting.castBallot(id, r);
        }

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 5)) {} // small batches to exercise pagination
        voting.finalize(id);

        uint8[] memory ranking = voting.getRanking(id);
        assertEq(ranking.length, 12);
        // Permutation invariant
        bool[] memory seen = new bool[](12);
        for (uint256 i = 0; i < 12; i++) seen[ranking[i]] = true;
        for (uint256 i = 0; i < 12; i++) assertTrue(seen[i]);
    }

    /// @dev Replaceable ballots: last vote stands.
    function test_replacementLastBallotWins() public {
        ICopelandVoting.ElectionConfig memory cfg = _cfg(3);
        uint256 id = voting.createElection(cfg);
        address voter = address(0x31);
        token.setPastVotes(voter, cfg.snapshotBlock, 50);

        uint8[] memory first = new uint8[](2); first[0] = 0; first[1] = 1;
        uint8[] memory second = new uint8[](2); second[0] = 2; second[1] = 1;
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
