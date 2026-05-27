// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRankedChoiceVoting} from "./IRankedChoiceVoting.sol";

/// @title ICopelandVoting
/// @notice Copeland-method extension of `IRankedChoiceVoting`. Adds getters for
///         the Copeland score and the Minimax tiebreaker that are computed
///         and persisted by the contract during `finalize()`.
interface ICopelandVoting is IRankedChoiceVoting {
    /// @notice Copeland score per candidate: (# pairs i won) - (# pairs i lost). Populated by finalize().
    function getCopelandScores(uint256 electionId) external view returns (int256[] memory);

    /// @notice Minimax tiebreaker per candidate: smallest pairwise margin across opponents. Populated by finalize().
    function getMinimaxScores(uint256 electionId) external view returns (int256[] memory);
}
