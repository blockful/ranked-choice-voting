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
    address internal constant BOB   = address(0xB0B);
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
        for (uint256 i = 0; i < 65; i++) cfg.candidates[i] = bytes32(i + 1);
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
        vm.expectRevert(abi.encodeWithSelector(ICopelandVoting.InvalidSnapshotBlock.selector, block.number, block.number));
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
        r[0] = 2; r[1] = 0; r[2] = 1;

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
        r[0] = 0; r[1] = 1;

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
        vm.prank(ALICE); voting.castBallot(id, r);
        vm.prank(BOB);   voting.castBallot(id, r);
        vm.prank(CAROL); voting.castBallot(id, r);
        address[] memory vs = voting.getVoters(id);
        assertEq(vs.length, 3);
        assertEq(vs[0], ALICE);
        assertEq(vs[1], BOB);
        assertEq(vs[2], CAROL);
    }
}
