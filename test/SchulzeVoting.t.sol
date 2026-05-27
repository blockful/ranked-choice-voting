// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SchulzeVoting} from "../src/SchulzeVoting.sol";
import {IRankedChoiceVoting} from "../src/interfaces/IRankedChoiceVoting.sol";
import {MockVotesToken} from "./mocks/MockVotesToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract SchulzeVotingTest is Test {
    SchulzeVoting internal voting;
    MockVotesToken internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA801);

    function setUp() public {
        voting = new SchulzeVoting();
        token = new MockVotesToken();
        // Advance one block so snapshotBlock = block.number - 1 is valid
        vm.roll(block.number + 1);
    }

    function _baseConfig() internal view returns (IRankedChoiceVoting.ElectionConfig memory cfg) {
        bytes32[] memory cands = new bytes32[](3);
        cands[0] = keccak256("Alice");
        cands[1] = keccak256("Bob");
        cands[2] = keccak256("Carol");
        cfg = IRankedChoiceVoting.ElectionConfig({
            candidates: cands,
            votingToken: IVotes(address(token)),
            snapshotBlock: block.number - 1,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            metadataURI: bytes32(0)
        });
    }

    function test_createElection_assignsId0AndIncrementsCounter() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        assertEq(id, 0);
        assertEq(voting.electionCount(), 1);

        uint256 id2 = voting.createElection(cfg);
        assertEq(id2, 1);
        assertEq(voting.electionCount(), 2);
    }

    function test_createElection_emitsEvent() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        vm.expectEmit(true, true, false, true);
        emit IRankedChoiceVoting.ElectionCreated(0, address(this), cfg);
        voting.createElection(cfg);
    }

    function test_createElection_storesConfig() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        IRankedChoiceVoting.ElectionView memory v = voting.getElection(id);
        assertEq(v.candidates.length, 3);
        assertEq(v.candidates[0], cfg.candidates[0]);
        assertEq(address(v.votingToken), address(token));
        assertEq(v.snapshotBlock, cfg.snapshotBlock);
        assertEq(v.startTime, cfg.startTime);
        assertEq(v.endTime, cfg.endTime);
        assertEq(v.metadataURI, cfg.metadataURI);
        assertEq(v.creator, address(this));
        assertEq(v.voterCount, 0);
        assertEq(uint8(v.phase), uint8(IRankedChoiceVoting.TallyPhase.NotStarted));
        assertEq(v.ballotsProcessed, 0);
    }

    function test_createElection_revertsOnEmptyCandidates() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.candidates = new bytes32[](0);
        vm.expectRevert(IRankedChoiceVoting.EmptyCandidates.selector);
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnTooManyCandidates() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.candidates = new bytes32[](65);
        for (uint256 i = 0; i < 65; i++) {
            cfg.candidates[i] = bytes32(i + 1);
        }
        vm.expectRevert(abi.encodeWithSelector(IRankedChoiceVoting.TooManyCandidates.selector, 65, 64));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnDuplicateCandidate() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.candidates[2] = cfg.candidates[0]; // duplicate
        vm.expectRevert(abi.encodeWithSelector(IRankedChoiceVoting.DuplicateCandidate.selector, cfg.candidates[0]));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnFutureSnapshotBlock() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.snapshotBlock = block.number; // not strictly past
        vm.expectRevert(
            abi.encodeWithSelector(IRankedChoiceVoting.InvalidSnapshotBlock.selector, block.number, block.number)
        );
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnInvalidTimeWindow() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.endTime = cfg.startTime; // not strictly greater
        vm.expectRevert(
            abi.encodeWithSelector(IRankedChoiceVoting.InvalidTimeWindow.selector, cfg.startTime, cfg.endTime)
        );
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnEndTimeInPast() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        vm.warp(cfg.endTime + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IRankedChoiceVoting.EndTimeInPast.selector, cfg.endTime, block.timestamp)
        );
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnZeroToken() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.votingToken = IVotes(address(0));
        vm.expectRevert(IRankedChoiceVoting.ZeroToken.selector);
        voting.createElection(cfg);
    }

    function test_castBallot_storesRankingAndAppendsVoter() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](3);
        r[0] = 2;
        r[1] = 0;
        r[2] = 1;

        vm.prank(ALICE);
        voting.castBallot(id, r);

        uint8[] memory stored = voting.getBallot(id, ALICE);
        assertEq(stored.length, 3);
        assertEq(stored[0], 2);
        assertEq(stored[1], 0);
        assertEq(stored[2], 1);

        address[] memory vs = voting.getVoters(id);
        assertEq(vs.length, 1);
        assertEq(vs[0], ALICE);
    }

    function test_castBallot_emitsEvent() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](2);
        r[0] = 0;
        r[1] = 1;

        vm.expectEmit(true, true, false, true);
        emit IRankedChoiceVoting.BallotCast(id, ALICE, r);
        vm.prank(ALICE);
        voting.castBallot(id, r);
    }

    function test_castBallot_emptyBallotAllowed() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](0);
        vm.prank(ALICE);
        voting.castBallot(id, r);
        assertEq(voting.getBallot(id, ALICE).length, 0);
        assertEq(voting.getVoters(id).length, 1);
    }

    function test_castBallot_multipleVotersAppendInOrder() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](1);
        r[0] = 0;
        vm.prank(ALICE);
        voting.castBallot(id, r);
        vm.prank(BOB);
        voting.castBallot(id, r);
        vm.prank(CAROL);
        voting.castBallot(id, r);
        address[] memory vs = voting.getVoters(id);
        assertEq(vs.length, 3);
        assertEq(vs[0], ALICE);
        assertEq(vs[1], BOB);
        assertEq(vs[2], CAROL);
    }

    function test_castBallot_recastOverwrites() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r1 = new uint8[](2);
        r1[0] = 0;
        r1[1] = 1;
        uint8[] memory r2 = new uint8[](3);
        r2[0] = 2;
        r2[1] = 1;
        r2[2] = 0;

        vm.startPrank(ALICE);
        voting.castBallot(id, r1);
        voting.castBallot(id, r2);
        vm.stopPrank();

        uint8[] memory stored = voting.getBallot(id, ALICE);
        assertEq(stored.length, 3);
        assertEq(stored[0], 2);
        assertEq(stored[1], 1);
        assertEq(stored[2], 0);

        address[] memory vs = voting.getVoters(id);
        assertEq(vs.length, 1);
        assertEq(vs[0], ALICE);
    }

    function test_castBallot_revertsOnUnknownElection() public {
        uint8[] memory r = new uint8[](1);
        vm.expectRevert(abi.encodeWithSelector(IRankedChoiceVoting.UnknownElection.selector, 42));
        voting.castBallot(42, r);
    }

    function test_castBallot_revertsBeforeStart() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.startTime = uint64(block.timestamp + 1 hours);
        cfg.endTime = uint64(block.timestamp + 2 hours);
        uint256 id = voting.createElection(cfg);
        uint8[] memory r = new uint8[](1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRankedChoiceVoting.VotingNotOpen.selector, cfg.startTime, cfg.endTime, block.timestamp
            )
        );
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsAfterEnd() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        uint8[] memory r = new uint8[](1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRankedChoiceVoting.VotingNotOpen.selector, cfg.startTime, cfg.endTime, block.timestamp
            )
        );
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsRankingTooLong() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](4); // candidates.length is 3
        vm.expectRevert(abi.encodeWithSelector(IRankedChoiceVoting.RankingTooLong.selector, 4, 3));
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsOutOfBoundsIndex() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](1);
        r[0] = 3; // candidate count is 3 → valid indices are 0,1,2
        vm.expectRevert(abi.encodeWithSelector(IRankedChoiceVoting.CandidateIndexOutOfBounds.selector, 3, 3));
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsDuplicateRanking() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](3);
        r[0] = 1; // duplicate of 1
        r[1] = 0;
        r[2] = 1;
        vm.expectRevert(abi.encodeWithSelector(IRankedChoiceVoting.DuplicateRanking.selector, 1));
        voting.castBallot(id, r);
    }

    function _giveWeight(address voter, uint256 snapshotBlock, uint256 weight) internal {
        token.setPastVotes(voter, snapshotBlock, weight);
    }

    function test_tallyBallots_singleCallBuildsMatrix() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 100);
        _giveWeight(BOB, cfg.snapshotBlock, 50);

        // Alice ranks 0>1>2
        uint8[] memory ra = new uint8[](3);
        ra[0] = 0;
        ra[1] = 1;
        ra[2] = 2;
        vm.prank(ALICE);
        voting.castBallot(id, ra);

        // Bob ranks 2>1 (partial, says nothing about 0)
        uint8[] memory rb = new uint8[](2);
        rb[0] = 2;
        rb[1] = 1;
        vm.prank(BOB);
        voting.castBallot(id, rb);

        vm.warp(cfg.endTime + 1);
        bool done = voting.tallyBallots(id, 10);
        assertTrue(done);

        int256[][] memory M = voting.getPairwiseMatrix(id);
        assertEq(M.length, 3);
        // From Alice: (0,1)+=100, (0,2)+=100, (1,2)+=100
        // From Bob:   (2,1)+=50
        assertEq(M[0][1], 100);
        assertEq(M[0][2], 100);
        assertEq(M[1][2], 100);
        assertEq(M[2][1], 50);
        // Diagonal and unstated entries stay 0
        assertEq(M[0][0], 0);
        assertEq(M[1][0], 0);
        assertEq(M[2][0], 0);
    }

    function test_tallyBallots_batchedAcrossCalls() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);

        // 5 voters, weight 1 each, all ranking 0>1>2
        address[5] memory voters = [address(0x1), address(0x2), address(0x3), address(0x4), address(0x5)];
        uint8[] memory r = new uint8[](3);
        r[0] = 0;
        r[1] = 1;
        r[2] = 2;
        for (uint256 i = 0; i < 5; i++) {
            _giveWeight(voters[i], cfg.snapshotBlock, 1);
            vm.prank(voters[i]);
            voting.castBallot(id, r);
        }

        vm.warp(cfg.endTime + 1);
        assertFalse(voting.tallyBallots(id, 2));
        assertFalse(voting.tallyBallots(id, 2));
        assertTrue(voting.tallyBallots(id, 2));
        // Once done, further calls return true and are idempotent
        assertTrue(voting.tallyBallots(id, 50));

        int256[][] memory M = voting.getPairwiseMatrix(id);
        assertEq(M[0][1], 5);
        assertEq(M[0][2], 5);
        assertEq(M[1][2], 5);
    }

    function test_tallyBallots_zeroMaxIsNoop() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 10);
        uint8[] memory r = new uint8[](1);
        r[0] = 0;
        vm.prank(ALICE);
        voting.castBallot(id, r);
        vm.warp(cfg.endTime + 1);
        assertFalse(voting.tallyBallots(id, 0));
        assertEq(voting.getElection(id).ballotsProcessed, 0);
    }

    function test_tallyBallots_zeroWeightVoterContributesNothing() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        // ALICE has weight 0 (default); BOB has weight 7
        _giveWeight(BOB, cfg.snapshotBlock, 7);
        uint8[] memory r = new uint8[](2);
        r[0] = 0;
        r[1] = 1;
        vm.prank(ALICE);
        voting.castBallot(id, r);
        vm.prank(BOB);
        voting.castBallot(id, r);

        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        int256[][] memory M = voting.getPairwiseMatrix(id);
        assertEq(M[0][1], 7);
        assertEq(M[1][0], 0);
    }

    function test_tallyBallots_revertsBeforeEndTime() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.expectRevert(
            abi.encodeWithSelector(IRankedChoiceVoting.VotingStillOpen.selector, cfg.endTime, block.timestamp)
        );
        voting.tallyBallots(id, 10);
    }

    function test_tallyBallots_revertsOnUnknownElection() public {
        vm.expectRevert(abi.encodeWithSelector(IRankedChoiceVoting.UnknownElection.selector, 99));
        voting.tallyBallots(99, 10);
    }

    function test_finalize_setsPhaseAndRanking() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 10);

        uint8[] memory r = new uint8[](3);
        r[0] = 1; // Alice: 1>0>2
        r[1] = 0;
        r[2] = 2;
        vm.prank(ALICE);
        voting.castBallot(id, r);

        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);

        vm.expectEmit(true, false, false, false);
        emit IRankedChoiceVoting.Finalized(id, new uint8[](0)); // payload not strictly checked
        voting.finalize(id);

        uint8[] memory ranking = voting.getRanking(id);
        assertEq(ranking.length, 3);
        assertEq(ranking[0], 1); // candidate 1 wins (beats 0 and 2)
        assertEq(ranking[1], 0); // candidate 0 second (beats 2)
        assertEq(ranking[2], 2); // candidate 2 last

        IRankedChoiceVoting.ElectionView memory v = voting.getElection(id);
        assertEq(uint8(v.phase), uint8(IRankedChoiceVoting.TallyPhase.Finalized));

        uint256[] memory schulzeScores = voting.getSchulzeScores(id);
        assertEq(schulzeScores[1], 2);
        assertEq(schulzeScores[0], 1);
        assertEq(schulzeScores[2], 0);
    }

    function test_finalize_revertsIfTallyNotComplete() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        // No voters at all → ballotsProcessed (0) == voters.length (0), so finalize should SUCCEED.
        // To test the revert: add a voter, partial tally, then try finalize.
        _giveWeight(ALICE, cfg.snapshotBlock, 1);
        uint8[] memory r = new uint8[](1);
        r[0] = 0;
        vm.prank(ALICE);
        voting.castBallot(id, r);
        // Add a second voter we won't process
        _giveWeight(BOB, cfg.snapshotBlock, 1);
        vm.prank(BOB);
        voting.castBallot(id, r);

        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 1); // process only 1 of 2
        vm.expectRevert(abi.encodeWithSelector(IRankedChoiceVoting.TallyNotComplete.selector, 1, 2));
        voting.finalize(id);
    }

    function test_finalize_revertsIfAlreadyFinalized() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        voting.finalize(id);
        vm.expectRevert(IRankedChoiceVoting.TallyAlreadyFinalized.selector);
        voting.finalize(id);
    }

    function test_finalize_noBallotsYieldsIdentityRanking() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        voting.finalize(id);
        uint8[] memory r = voting.getRanking(id);
        assertEq(r[0], 0);
        assertEq(r[1], 1);
        assertEq(r[2], 2);
    }

    function test_castBallot_revertsWhenFinalized() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        voting.finalize(id);

        // The election is finalized — VotingNotOpen reverts first (time-based check is earlier),
        // but we want to ensure no ballot can land. Either revert is acceptable.
        uint8[] memory r = new uint8[](1);
        vm.prank(ALICE);
        vm.expectRevert();
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsAfterEndDuringTallying() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 1);
        uint8[] memory r = new uint8[](1);
        r[0] = 0;
        vm.prank(ALICE);
        voting.castBallot(id, r);

        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10); // phase becomes Tallying

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRankedChoiceVoting.VotingNotOpen.selector, cfg.startTime, cfg.endTime, block.timestamp
            )
        );
        voting.castBallot(id, r);
    }

    function test_tallyBallots_revertsWhenWeightExceedsInt256Max() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        uint256 huge = uint256(type(int256).max) + 1;
        _giveWeight(ALICE, cfg.snapshotBlock, huge);
        uint8[] memory r = new uint8[](1);
        r[0] = 0;
        vm.prank(ALICE);
        voting.castBallot(id, r);

        vm.warp(cfg.endTime + 1);
        vm.expectRevert(abi.encodeWithSelector(IRankedChoiceVoting.WeightExceedsInt256Max.selector, ALICE, huge));
        voting.tallyBallots(id, 10);
    }

    function test_getCurrentResult_revertsOnUnknownElection() public {
        vm.expectRevert(abi.encodeWithSelector(IRankedChoiceVoting.UnknownElection.selector, 42));
        voting.getCurrentResult(42);
    }

    function test_getCurrentResult_identityWhenEmpty() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = voting.getCurrentResult(id);
        assertEq(r.length, 3);
        assertEq(r[0], 0);
        assertEq(r[1], 1);
        assertEq(r[2], 2);
    }

    function test_getCurrentResult_matchesFinalAfterFinalize() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 10);
        uint8[] memory r = new uint8[](3);
        r[0] = 1;
        r[1] = 0;
        r[2] = 2;
        vm.prank(ALICE);
        voting.castBallot(id, r);
        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        uint8[] memory preview = voting.getCurrentResult(id);
        voting.finalize(id);
        uint8[] memory finalR = voting.getRanking(id);
        assertEq(preview.length, finalR.length);
        for (uint256 i = 0; i < preview.length; i++) {
            assertEq(preview[i], finalR[i]);
        }
    }

    function test_getCurrentResult_partialTallyReflectsProcessedBallots() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 1);
        _giveWeight(BOB, cfg.snapshotBlock, 1);
        uint8[] memory rA = new uint8[](3);
        rA[0] = 0;
        rA[1] = 1;
        rA[2] = 2;
        uint8[] memory rB = new uint8[](3);
        rB[0] = 2;
        rB[1] = 1;
        rB[2] = 0;
        vm.prank(ALICE);
        voting.castBallot(id, rA);
        vm.prank(BOB);
        voting.castBallot(id, rB);
        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 1); // process Alice only
        uint8[] memory preview = voting.getCurrentResult(id);
        assertEq(preview[0], 0); // Alice's #1 leads
    }

    function test_getStrongestPaths_afterFinalize() public {
        IRankedChoiceVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        _giveWeight(ALICE, cfg.snapshotBlock, 10);
        uint8[] memory r = new uint8[](3);
        r[0] = 1;
        r[1] = 0;
        r[2] = 2;
        vm.prank(ALICE);
        voting.castBallot(id, r);
        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        voting.finalize(id);

        int256[][] memory P = voting.getStrongestPaths(id);
        assertEq(P.length, 3);
        assertEq(P[0][1], 0);
        assertEq(P[0][2], 10);
        assertEq(P[1][0], 10);
        assertEq(P[1][2], 10);
        assertEq(P[2][0], 0);
        assertEq(P[2][1], 0);
    }

    function test_getSchulzeScores_emptyBeforeFinalize() public {
        uint256 id = voting.createElection(_baseConfig());
        uint256[] memory scores = voting.getSchulzeScores(id);
        assertEq(scores.length, 0); // default uninitialized
    }
}
