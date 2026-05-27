// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SchulzeVoting} from "../src/SchulzeVoting.sol";
import {IRankedChoiceVoting} from "../src/interfaces/IRankedChoiceVoting.sol";
import {MockVotesToken} from "./mocks/MockVotesToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract SchulzeVotingFuzz is Test {
    SchulzeVoting internal voting;
    MockVotesToken internal token;

    function setUp() public {
        voting = new SchulzeVoting();
        token = new MockVotesToken();
        vm.roll(block.number + 1);
    }

    function _config(uint8 numCandidates) internal view returns (IRankedChoiceVoting.ElectionConfig memory cfg) {
        bytes32[] memory cands = new bytes32[](numCandidates);
        for (uint8 i = 0; i < numCandidates; i++) {
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

    /// @dev Final ranking is always a permutation of [0..C-1].
    function testFuzz_rankingIsPermutation(uint8 cRaw, uint64 weightSeed) public {
        uint8 c = uint8(bound(cRaw, 2, 8));
        IRankedChoiceVoting.ElectionConfig memory cfg = _config(c);
        uint256 id = voting.createElection(cfg);

        // 5 voters, simple ballots, random weights
        // Ballot length is min(3, c) to respect RankingTooLong; uses distinct picks via rotating offset
        uint8 ballotLen = c < 3 ? c : 3;
        for (uint160 vi = 1; vi <= 5; vi++) {
            address v = address(vi);
            uint256 weight = uint256(keccak256(abi.encode(weightSeed, vi))) % 1000 + 1;
            token.setPastVotes(v, cfg.snapshotBlock, weight);
            uint8[] memory r = new uint8[](ballotLen);
            uint8 offset = uint8(vi % c);
            for (uint8 i = 0; i < ballotLen; i++) {
                r[i] = (offset + i) % c;
            }
            vm.prank(v);
            voting.castBallot(id, r);
        }

        vm.warp(cfg.endTime + 1);
        while (!voting.tallyBallots(id, 10)) {}
        voting.finalize(id);

        uint8[] memory ranking = voting.getRanking(id);
        assertEq(ranking.length, c);

        // Every index 0..c-1 appears exactly once
        bool[] memory seen = new bool[](c);
        for (uint256 i = 0; i < c; i++) {
            assertTrue(ranking[i] < c, "index out of range");
            assertFalse(seen[ranking[i]], "duplicate in ranking");
            seen[ranking[i]] = true;
        }
        for (uint256 i = 0; i < c; i++) {
            assertTrue(seen[i], "missing candidate");
        }
    }

    /// @dev Same inputs → same final ranking.
    function testFuzz_deterministic(uint8 cRaw) public {
        uint8 c = uint8(bound(cRaw, 2, 6));

        // First run
        IRankedChoiceVoting.ElectionConfig memory cfg1 = _config(c);
        uint256 id1 = voting.createElection(cfg1);
        _castFixedBallots(id1, cfg1.snapshotBlock, c);
        vm.warp(cfg1.endTime + 1);
        while (!voting.tallyBallots(id1, 10)) {}
        voting.finalize(id1);
        uint8[] memory r1 = voting.getRanking(id1);

        // Reset block + create second election with identical config and ballots
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        IRankedChoiceVoting.ElectionConfig memory cfg2 = _config(c);
        cfg2.startTime = uint64(block.timestamp);
        cfg2.endTime = uint64(block.timestamp + 1 days);
        uint256 id2 = voting.createElection(cfg2);
        _castFixedBallots(id2, cfg2.snapshotBlock, c);
        vm.warp(cfg2.endTime + 1);
        while (!voting.tallyBallots(id2, 10)) {}
        voting.finalize(id2);
        uint8[] memory r2 = voting.getRanking(id2);

        assertEq(r1.length, r2.length);
        for (uint256 i = 0; i < r1.length; i++) {
            assertEq(r1[i], r2[i]);
        }
    }

    function _castFixedBallots(uint256 id, uint256 snapshotBlock, uint8 c) internal {
        for (uint160 vi = 1; vi <= 4; vi++) {
            address v = address(vi);
            token.setPastVotes(v, snapshotBlock, vi * 10);
            uint8[] memory r = new uint8[](c);
            // Ballot: shift by vi
            for (uint8 i = 0; i < c; i++) {
                r[i] = uint8((i + vi) % c);
            }
            vm.prank(v);
            voting.castBallot(id, r);
        }
    }
}
