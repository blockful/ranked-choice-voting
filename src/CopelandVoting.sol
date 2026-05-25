// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ICopelandVoting} from "./interfaces/ICopelandVoting.sol";

/// @title CopelandVoting
/// @notice Onchain Copeland-method ranked choice voting for DAOs.
contract CopelandVoting is ICopelandVoting {
    uint8 public constant MAX_CANDIDATES = 64;

    struct Election {
        // immutable config
        bytes32[] candidates;
        IVotes votingToken;
        uint256 snapshotBlock;
        uint64 startTime;
        uint64 endTime;
        bytes32 metadataURI;
        address creator;
        // ballot storage
        address[] voters;
        mapping(address => uint8[]) ballots;
        mapping(address => uint256) voterIndexPlusOne;
        // tally state
        TallyPhase phase;
        uint256 ballotsProcessed;
        int256[] pairwiseFlat;
        int256[] copelandScores;
        int256[] marginSums;
        uint8[] finalRanking;
    }

    mapping(uint256 => Election) private _elections;
    uint256 private _electionCount;

    function electionCount() external view returns (uint256) {
        return _electionCount;
    }

    function createElection(ElectionConfig calldata cfg) external returns (uint256 electionId) {
        uint256 c = cfg.candidates.length;
        if (c == 0) revert EmptyCandidates();
        if (c > MAX_CANDIDATES) revert TooManyCandidates(c, MAX_CANDIDATES);
        if (address(cfg.votingToken) == address(0)) revert ZeroToken();
        if (cfg.snapshotBlock >= block.number) revert InvalidSnapshotBlock(cfg.snapshotBlock, block.number);
        if (cfg.startTime >= cfg.endTime) revert InvalidTimeWindow(cfg.startTime, cfg.endTime);
        if (cfg.endTime <= block.timestamp) revert EndTimeInPast(cfg.endTime, block.timestamp);

        // Duplicate-candidate check: O(c^2) is fine since c <= 64
        for (uint256 i = 0; i < c; i++) {
            for (uint256 j = i + 1; j < c; j++) {
                if (cfg.candidates[i] == cfg.candidates[j]) {
                    revert DuplicateCandidate(cfg.candidates[i]);
                }
            }
        }

        electionId = _electionCount;
        Election storage e = _elections[electionId];
        e.candidates = cfg.candidates;
        e.votingToken = cfg.votingToken;
        e.snapshotBlock = cfg.snapshotBlock;
        e.startTime = cfg.startTime;
        e.endTime = cfg.endTime;
        e.metadataURI = cfg.metadataURI;
        e.creator = msg.sender;
        e.pairwiseFlat = new int256[](c * c);
        unchecked {
            _electionCount = electionId + 1;
        }
        emit ElectionCreated(electionId, msg.sender, cfg);
    }

    function getElection(uint256 electionId) external view returns (ElectionView memory v) {
        Election storage e = _elections[electionId];
        v = ElectionView({
            candidates: e.candidates,
            votingToken: e.votingToken,
            snapshotBlock: e.snapshotBlock,
            startTime: e.startTime,
            endTime: e.endTime,
            metadataURI: e.metadataURI,
            creator: e.creator,
            voterCount: e.voters.length,
            phase: e.phase,
            ballotsProcessed: e.ballotsProcessed
        });
    }

    // --- stubs (to be implemented in later tasks) ---

    function castBallot(uint256 electionId, uint8[] calldata ranking) external {
        Election storage e = _elections[electionId];
        uint256 c = e.candidates.length;
        if (c == 0) revert UnknownElection(electionId);
        if (e.phase == TallyPhase.Finalized) revert ElectionFinalized();
        if (block.timestamp < e.startTime || block.timestamp > e.endTime) {
            revert VotingNotOpen(e.startTime, e.endTime, block.timestamp);
        }
        if (ranking.length > c) revert RankingTooLong(ranking.length, c);

        // Duplicate check via bitmap. MAX_CANDIDATES <= 64 → single uint256 is enough.
        uint256 seen;
        for (uint256 i = 0; i < ranking.length; i++) {
            uint8 idx = ranking[i];
            if (idx >= c) revert CandidateIndexOutOfBounds(idx, c);
            uint256 bit = uint256(1) << idx;
            if (seen & bit != 0) revert DuplicateRanking(idx);
            seen |= bit;
        }

        e.ballots[msg.sender] = ranking;
        if (e.voterIndexPlusOne[msg.sender] == 0) {
            e.voters.push(msg.sender);
            e.voterIndexPlusOne[msg.sender] = e.voters.length;
        }
        emit BallotCast(electionId, msg.sender, ranking);
    }

    function tallyBallots(uint256, uint256) external pure returns (bool) {
        revert("not implemented");
    }

    function finalize(uint256) external pure {
        revert("not implemented");
    }

    function getRanking(uint256) external pure returns (uint8[] memory) {
        revert("not implemented");
    }

    function getBallot(uint256 electionId, address voter) external view returns (uint8[] memory) {
        return _elections[electionId].ballots[voter];
    }

    function getPairwiseMatrix(uint256) external pure returns (int256[][] memory) {
        revert("not implemented");
    }

    function getCopelandScores(uint256) external pure returns (int256[] memory) {
        revert("not implemented");
    }

    function getMarginSums(uint256) external pure returns (int256[] memory) {
        revert("not implemented");
    }

    function getVoters(uint256 electionId) external view returns (address[] memory) {
        return _elections[electionId].voters;
    }
}
