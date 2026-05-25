// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CopelandTally
/// @notice Pure functions implementing Copeland-method tally math.
library CopelandTally {
    /// @notice Sort candidate indices by (score desc, minimax desc, index asc).
    /// @dev Insertion sort — input sizes are bounded (C <= 64).
    /// @param scores Copeland scores per candidate (length = C)
    /// @param minimaxScores Minimax tiebreaker per candidate (length = C; same order as scores; higher is better)
    /// @return ranking Candidate indices ordered most-preferred first
    function sortRanking(int256[] memory scores, int256[] memory minimaxScores)
        internal
        pure
        returns (uint8[] memory ranking)
    {
        uint256 c = scores.length;
        require(c == minimaxScores.length, "length mismatch");
        ranking = new uint8[](c);
        for (uint256 i = 0; i < c; i++) {
            ranking[i] = uint8(i);
        }
        // insertion sort: for each i, bubble ranking[i] leftward into place
        for (uint256 i = 1; i < c; i++) {
            uint8 cur = ranking[i];
            uint256 j = i;
            while (j > 0 && _isGreater(cur, ranking[j - 1], scores, minimaxScores)) {
                ranking[j] = ranking[j - 1];
                j--;
            }
            ranking[j] = cur;
        }
    }

    /// @notice Compute Copeland scores and Minimax tiebreaker values from a flat pairwise matrix.
    /// @param matrix Flat C*C matrix; matrix[i*C+j] = total weight of voters who explicitly preferred i over j.
    /// @param c Candidate count.
    /// @return scores Copeland score per candidate (+1 win, -1 loss, 0 tie, summed across opponents).
    /// @return minimaxScores Minimax score per candidate: the SMALLEST pairwise margin across opponents.
    ///         Higher = better (Condorcet winner has positive minimaxScore; Condorcet loser has strongly negative).
    ///         For c == 1, returns 0.
    function computeScoresAndMinimax(int256[] memory matrix, uint256 c)
        internal
        pure
        returns (int256[] memory scores, int256[] memory minimaxScores)
    {
        require(matrix.length == c * c, "matrix size");
        scores = new int256[](c);
        minimaxScores = new int256[](c);
        for (uint256 i = 0; i < c; i++) {
            bool any = false;
            int256 minMargin = 0;
            for (uint256 j = 0; j < c; j++) {
                if (i == j) continue;
                int256 m = matrix[i * c + j] - matrix[j * c + i];
                if (m > 0) {
                    scores[i] += 1;
                } else if (m < 0) {
                    scores[i] -= 1;
                }
                if (!any || m < minMargin) {
                    minMargin = m;
                    any = true;
                }
            }
            if (any) minimaxScores[i] = minMargin;
        }
    }

    /// @dev True iff candidate `a` ranks above candidate `b` by (score, minimax, index).
    function _isGreater(uint8 a, uint8 b, int256[] memory scores, int256[] memory minimaxScores)
        private
        pure
        returns (bool)
    {
        if (scores[a] != scores[b]) return scores[a] > scores[b];
        if (minimaxScores[a] != minimaxScores[b]) return minimaxScores[a] > minimaxScores[b];
        return a < b;
    }
}
