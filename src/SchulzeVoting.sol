// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRankedChoiceVoting} from "./interfaces/IRankedChoiceVoting.sol";
import {ISchulzeVoting} from "./interfaces/ISchulzeVoting.sol";
import {SchulzeTally} from "./libraries/SchulzeTally.sol";

/// @title SchulzeVoting
/// @notice Onchain Schulze-method ranked choice voting for DAOs.
contract SchulzeVoting is ISchulzeVoting, ReentrancyGuard {
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
        /// @dev Stored as `voters.length + 1` on first cast so that the default
        ///      zero value distinguishes "never voted". Only the zero / non-zero
        ///      distinction is consulted; the index itself is not read back.
        mapping(address => uint256) voterIndexPlusOne;
        // tally state
        TallyPhase phase;
        uint256 ballotsProcessed;
        int256[] pairwiseFlat;
        uint256[] schulzeScores;
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

    function castBallot(uint256 electionId, uint8[] calldata ranking) external nonReentrant {
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

    /// @notice Tally up to `maxBallots` voter ballots, accumulating weighted pairwise wins.
    /// @dev Reverts if any voter's weight exceeds int256 max. Standard ERC20Votes implementations
    ///      cap at uint208, so this only matters with non-standard token contracts.
    function tallyBallots(uint256 electionId, uint256 maxBallots) external nonReentrant returns (bool done) {
        Election storage e = _elections[electionId];
        uint256 c = e.candidates.length;
        if (c == 0) revert UnknownElection(electionId);
        if (e.phase == TallyPhase.Finalized) revert TallyAlreadyFinalized();
        if (block.timestamp <= e.endTime) revert VotingStillOpen(e.endTime, block.timestamp);

        if (e.phase == TallyPhase.NotStarted) e.phase = TallyPhase.Tallying;

        uint256 total = e.voters.length;
        uint256 cursor = e.ballotsProcessed;
        if (cursor >= total) {
            return true;
        }
        uint256 end = cursor + maxBallots;
        if (end > total) end = total;

        for (uint256 vi = cursor; vi < end; vi++) {
            address voter = e.voters[vi];
            uint256 weight = e.votingToken.getPastVotes(voter, e.snapshotBlock);
            if (weight == 0) continue;
            if (weight > uint256(type(int256).max)) {
                revert WeightExceedsInt256Max(voter, weight);
            }
            uint8[] storage ranking = e.ballots[voter];
            uint256 k = ranking.length;
            for (uint256 a = 0; a < k; a++) {
                uint8 ia = ranking[a];
                for (uint256 b = a + 1; b < k; b++) {
                    uint8 ib = ranking[b];
                    e.pairwiseFlat[uint256(ia) * c + uint256(ib)] += int256(weight);
                }
            }
        }

        e.ballotsProcessed = end;
        emit TallyProgress(electionId, end, total);
        done = end == total;
    }

    /// @inheritdoc IRankedChoiceVoting
    function finalize(uint256 electionId) external nonReentrant {
        Election storage e = _elections[electionId];
        uint256 c = e.candidates.length;
        if (c == 0) revert UnknownElection(electionId);
        if (e.phase == TallyPhase.Finalized) revert TallyAlreadyFinalized();
        if (block.timestamp <= e.endTime) revert VotingStillOpen(e.endTime, block.timestamp);
        if (e.phase == TallyPhase.NotStarted) e.phase = TallyPhase.Tallying;
        if (e.ballotsProcessed != e.voters.length) {
            revert TallyNotComplete(e.ballotsProcessed, e.voters.length);
        }

        int256[] memory paths = SchulzeTally.computeStrongestPaths(e.pairwiseFlat, c);
        uint256[] memory scores = SchulzeTally.computeScores(paths, c);
        uint8[] memory ranking = SchulzeTally.sortRanking(scores);

        e.schulzeScores = scores; // persisted
        e.finalRanking = ranking; // persisted
        // strongest paths NOT persisted — recomputed on view (too large for storage at C=64)

        e.phase = TallyPhase.Finalized;
        emit Finalized(electionId, ranking);
    }

    /// @inheritdoc IRankedChoiceVoting
    function getCurrentResult(uint256 electionId) external view returns (uint8[] memory) {
        Election storage e = _elections[electionId];
        uint256 c = e.candidates.length;
        if (c == 0) revert UnknownElection(electionId);
        int256[] memory paths = SchulzeTally.computeStrongestPaths(e.pairwiseFlat, c);
        uint256[] memory scores = SchulzeTally.computeScores(paths, c);
        return SchulzeTally.sortRanking(scores);
    }

    function getRanking(uint256 electionId) external view returns (uint8[] memory) {
        return _elections[electionId].finalRanking;
    }

    function getBallot(uint256 electionId, address voter) external view returns (uint8[] memory) {
        return _elections[electionId].ballots[voter];
    }

    function getPairwiseMatrix(uint256 electionId) external view returns (int256[][] memory matrix) {
        Election storage e = _elections[electionId];
        uint256 c = e.candidates.length;
        matrix = new int256[][](c);
        for (uint256 i = 0; i < c; i++) {
            int256[] memory row = new int256[](c);
            for (uint256 j = 0; j < c; j++) {
                row[j] = e.pairwiseFlat[i * c + j];
            }
            matrix[i] = row;
        }
    }

    /// @inheritdoc ISchulzeVoting
    function getStrongestPaths(uint256 electionId) external view returns (int256[][] memory matrix) {
        Election storage e = _elections[electionId];
        uint256 c = e.candidates.length;
        if (c == 0) revert UnknownElection(electionId);
        int256[] memory flat = SchulzeTally.computeStrongestPaths(e.pairwiseFlat, c);
        matrix = new int256[][](c);
        for (uint256 i = 0; i < c; i++) {
            int256[] memory row = new int256[](c);
            for (uint256 j = 0; j < c; j++) {
                row[j] = flat[i * c + j];
            }
            matrix[i] = row;
        }
    }

    /// @inheritdoc ISchulzeVoting
    function getSchulzeScores(uint256 electionId) external view returns (uint256[] memory) {
        return _elections[electionId].schulzeScores;
    }

    function getVoters(uint256 electionId) external view returns (address[] memory) {
        return _elections[electionId].voters;
    }
}
