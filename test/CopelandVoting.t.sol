// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CopelandVoting} from "../src/CopelandVoting.sol";
import {ICopelandVoting} from "../src/interfaces/ICopelandVoting.sol";
import {MockVotesToken} from "./mocks/MockVotesToken.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract CopelandVotingTest is Test {
    CopelandVoting internal voting;
    MockVotesToken internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA801);

    function setUp() public {
        voting = new CopelandVoting();
        token = new MockVotesToken();
        // Advance one block so snapshotBlock = block.number - 1 is valid
        vm.roll(block.number + 1);
    }

    function _baseConfig() internal view returns (ICopelandVoting.ElectionConfig memory cfg) {
        bytes32[] memory cands = new bytes32[](3);
        cands[0] = keccak256("Alice");
        cands[1] = keccak256("Bob");
        cands[2] = keccak256("Carol");
        cfg = ICopelandVoting.ElectionConfig({
            candidates: cands,
            votingToken: IVotes(address(token)),
            snapshotBlock: block.number - 1,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            metadataURI: bytes32(0)
        });
    }

    function test_createElection_assignsId0AndIncrementsCounter() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        assertEq(id, 0);
        assertEq(voting.electionCount(), 1);

        uint256 id2 = voting.createElection(cfg);
        assertEq(id2, 1);
        assertEq(voting.electionCount(), 2);
    }

    function test_createElection_emitsEvent() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        vm.expectEmit(true, true, false, true);
        emit ICopelandVoting.ElectionCreated(0, address(this), cfg);
        voting.createElection(cfg);
    }

    function test_createElection_storesConfig() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        ICopelandVoting.ElectionView memory v = voting.getElection(id);
        assertEq(v.candidates.length, 3);
        assertEq(v.candidates[0], cfg.candidates[0]);
        assertEq(address(v.votingToken), address(token));
        assertEq(v.snapshotBlock, cfg.snapshotBlock);
        assertEq(v.startTime, cfg.startTime);
        assertEq(v.endTime, cfg.endTime);
        assertEq(v.metadataURI, cfg.metadataURI);
        assertEq(v.creator, address(this));
        assertEq(v.voterCount, 0);
        assertEq(uint8(v.phase), uint8(ICopelandVoting.TallyPhase.NotStarted));
        assertEq(v.ballotsProcessed, 0);
    }

    function test_createElection_revertsOnEmptyCandidates() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.candidates = new bytes32[](0);
        vm.expectRevert(ICopelandVoting.EmptyCandidates.selector);
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnTooManyCandidates() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.candidates = new bytes32[](65);
        for (uint256 i = 0; i < 65; i++) {
            cfg.candidates[i] = bytes32(i + 1);
        }
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.TooManyCandidates.selector, 65, 64));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnDuplicateCandidate() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.candidates[2] = cfg.candidates[0]; // duplicate
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.DuplicateCandidate.selector, cfg.candidates[0]));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnFutureSnapshotBlock() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.snapshotBlock = block.number; // not strictly past
        vm.expectRevert(
            abi.encodeWithSelector(ICopelandVoting.InvalidSnapshotBlock.selector, block.number, block.number)
        );
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnInvalidTimeWindow() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.endTime = cfg.startTime; // not strictly greater
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.InvalidTimeWindow.selector, cfg.startTime, cfg.endTime));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnEndTimeInPast() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        vm.warp(cfg.endTime + 1);
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.EndTimeInPast.selector, cfg.endTime, block.timestamp));
        voting.createElection(cfg);
    }

    function test_createElection_revertsOnZeroToken() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.votingToken = IVotes(address(0));
        vm.expectRevert(ICopelandVoting.ZeroToken.selector);
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
        emit ICopelandVoting.BallotCast(id, ALICE, r);
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
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.UnknownElection.selector, 42));
        voting.castBallot(42, r);
    }

    function test_castBallot_revertsBeforeStart() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        cfg.startTime = uint64(block.timestamp + 1 hours);
        cfg.endTime = uint64(block.timestamp + 2 hours);
        uint256 id = voting.createElection(cfg);
        uint8[] memory r = new uint8[](1);
        vm.expectRevert(
            abi.encodeWithSelector(ICopelandVoting.VotingNotOpen.selector, cfg.startTime, cfg.endTime, block.timestamp)
        );
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsAfterEnd() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        uint8[] memory r = new uint8[](1);
        vm.expectRevert(
            abi.encodeWithSelector(ICopelandVoting.VotingNotOpen.selector, cfg.startTime, cfg.endTime, block.timestamp)
        );
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsRankingTooLong() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](4); // candidates.length is 3
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.RankingTooLong.selector, 4, 3));
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsOutOfBoundsIndex() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](1);
        r[0] = 3; // candidate count is 3 → valid indices are 0,1,2
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.CandidateIndexOutOfBounds.selector, 3, 3));
        voting.castBallot(id, r);
    }

    function test_castBallot_revertsDuplicateRanking() public {
        uint256 id = voting.createElection(_baseConfig());
        uint8[] memory r = new uint8[](3);
        r[0] = 1; // duplicate of 1
        r[1] = 0;
        r[2] = 1;
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.DuplicateRanking.selector, 1));
        voting.castBallot(id, r);
    }

    function _giveWeight(address voter, uint256 snapshotBlock, uint256 weight) internal {
        token.setPastVotes(voter, snapshotBlock, weight);
    }

    function test_tallyBallots_singleCallBuildsMatrix() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
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
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
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
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
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
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
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
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.VotingStillOpen.selector, cfg.endTime, block.timestamp));
        voting.tallyBallots(id, 10);
    }

    function test_tallyBallots_revertsOnUnknownElection() public {
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.UnknownElection.selector, 99));
        voting.tallyBallots(99, 10);
    }

    function test_finalize_setsPhaseAndRanking() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
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
        emit ICopelandVoting.Finalized(id, new uint8[](0)); // payload not strictly checked
        voting.finalize(id);

        uint8[] memory ranking = voting.getRanking(id);
        assertEq(ranking.length, 3);
        assertEq(ranking[0], 1); // candidate 1 wins (beats 0 and 2)
        assertEq(ranking[1], 0); // candidate 0 second (beats 2)
        assertEq(ranking[2], 2); // candidate 2 last

        ICopelandVoting.ElectionView memory v = voting.getElection(id);
        assertEq(uint8(v.phase), uint8(ICopelandVoting.TallyPhase.Finalized));

        int256[] memory scores = voting.getCopelandScores(id);
        assertEq(scores[1], 2);
        assertEq(scores[0], 0);
        assertEq(scores[2], -2);

        int256[] memory minimax = voting.getMinimaxScores(id);
        // candidate 1: min(10-0, 10-0) = 10
        assertEq(minimax[1], 10);
    }

    function test_finalize_revertsIfTallyNotComplete() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
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
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.TallyNotComplete.selector, 1, 2));
        voting.finalize(id);
    }

    function test_finalize_revertsIfAlreadyFinalized() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
        uint256 id = voting.createElection(cfg);
        vm.warp(cfg.endTime + 1);
        voting.tallyBallots(id, 10);
        voting.finalize(id);
        vm.expectRevert(ICopelandVoting.TallyAlreadyFinalized.selector);
        voting.finalize(id);
    }

    function test_finalize_noBallotsYieldsIdentityRanking() public {
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
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
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
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
        ICopelandVoting.ElectionConfig memory cfg = _baseConfig();
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
            abi.encodeWithSelector(ICopelandVoting.VotingNotOpen.selector, cfg.startTime, cfg.endTime, block.timestamp)
        );
        voting.castBallot(id, r);
    }
}
