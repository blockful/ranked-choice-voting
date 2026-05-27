// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title IRankedChoiceVoting
/// @notice Common interface implemented by any pairwise-Condorcet ranked-choice
///         voting method (e.g., Copeland, Schulze). Holds every type, event,
///         error, lifecycle function and shared view that does not depend on a
///         specific tally algorithm. Method-specific getters live on the
///         concrete sub-interfaces (`ICopelandVoting`, `ISchulzeVoting`).
interface IRankedChoiceVoting {
    enum TallyPhase {
        NotStarted,
        Tallying,
        Finalized
    }

    struct ElectionConfig {
        bytes32[] candidates;
        IVotes votingToken;
        uint256 snapshotBlock;
        uint64 startTime;
        uint64 endTime;
        bytes32 metadataURI;
    }

    struct ElectionView {
        bytes32[] candidates;
        IVotes votingToken;
        uint256 snapshotBlock;
        uint64 startTime;
        uint64 endTime;
        bytes32 metadataURI;
        address creator;
        uint256 voterCount;
        TallyPhase phase;
        uint256 ballotsProcessed;
    }

    // Events (identical across methods)
    event ElectionCreated(uint256 indexed electionId, address indexed creator, ElectionConfig cfg);
    event BallotCast(uint256 indexed electionId, address indexed voter, uint8[] ranking);
    event TallyProgress(uint256 indexed electionId, uint256 ballotsProcessed, uint256 totalBallots);
    event Finalized(uint256 indexed electionId, uint8[] ranking);

    // Errors (shared across methods)
    error EmptyCandidates();
    error TooManyCandidates(uint256 provided, uint256 max);
    error DuplicateCandidate(bytes32 candidate);
    error InvalidSnapshotBlock(uint256 snapshotBlock, uint256 currentBlock);
    error InvalidTimeWindow(uint64 startTime, uint64 endTime);
    error EndTimeInPast(uint64 endTime, uint256 currentTime);
    error ZeroToken();
    error UnknownElection(uint256 electionId);
    error VotingNotOpen(uint64 startTime, uint64 endTime, uint256 currentTime);
    error VotingStillOpen(uint64 endTime, uint256 currentTime);
    error ElectionFinalized();
    error TallyNotComplete(uint256 processed, uint256 total);
    error TallyAlreadyFinalized();
    error RankingTooLong(uint256 provided, uint256 max);
    error CandidateIndexOutOfBounds(uint8 index, uint256 max);
    error DuplicateRanking(uint8 index);
    error WeightExceedsInt256Max(address voter, uint256 weight);

    // Lifecycle
    function createElection(ElectionConfig calldata cfg) external returns (uint256 electionId);
    function castBallot(uint256 electionId, uint8[] calldata ranking) external;
    function tallyBallots(uint256 electionId, uint256 maxBallots) external returns (bool done);
    function finalize(uint256 electionId) external;

    // Results
    function getRanking(uint256 electionId) external view returns (uint8[] memory);

    /// @notice The ranking the contract would produce if `finalize()` were called right now.
    /// @dev Works at any lifecycle phase. During `Tallying`, returns the ranking based on the
    ///      partially-built pairwise matrix (i.e., "if we stopped now, this is the result").
    ///      For `NotStarted` or an empty matrix, returns the identity ranking `[0..C-1]`.
    ///      Always reverts `UnknownElection` if the id doesn't exist; never reverts based on phase.
    function getCurrentResult(uint256 electionId) external view returns (uint8[] memory);

    // State
    function getElection(uint256 electionId) external view returns (ElectionView memory);
    function getBallot(uint256 electionId, address voter) external view returns (uint8[] memory);
    function getPairwiseMatrix(uint256 electionId) external view returns (int256[][] memory);
    function getVoters(uint256 electionId) external view returns (address[] memory);
    function electionCount() external view returns (uint256);

    function MAX_CANDIDATES() external view returns (uint8);
}
