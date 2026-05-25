// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CopelandTally
/// @notice Pure functions implementing Copeland-method tally math.
library CopelandTally {
    /// @notice Sort candidate indices by (score desc, margin desc, index asc).
    /// @dev Insertion sort — input sizes are bounded (C <= 64).
    /// @param scores Copeland scores per candidate (length = C)
    /// @param margins Sum of pairwise margins per candidate (length = C; same order as scores)
    /// @return ranking Candidate indices ordered most-preferred first
    function sortRanking(int256[] memory scores, int256[] memory margins)
        internal
        pure
        returns (uint8[] memory ranking)
    {
        uint256 c = scores.length;
        require(c == margins.length, "length mismatch");
        ranking = new uint8[](c);
        for (uint256 i = 0; i < c; i++) {
            ranking[i] = uint8(i);
        }
        // insertion sort: for each i, bubble ranking[i] leftward into place
        for (uint256 i = 1; i < c; i++) {
            uint8 cur = ranking[i];
            uint256 j = i;
            while (j > 0 && _isGreater(cur, ranking[j - 1], scores, margins)) {
                ranking[j] = ranking[j - 1];
                j--;
            }
            ranking[j] = cur;
        }
    }

    /// @notice Compute Copeland scores and sum-of-margin tiebreakers from a flat pairwise matrix.
    /// @param matrix Flat C*C matrix; matrix[i*C+j] = total weight of voters who explicitly preferred i over j.
    /// @param c Candidate count.
    /// @return scores Copeland score per candidate (+1 win, -1 loss, 0 tie, summed across opponents).
    /// @return margins Sum of (M[i][j] - M[j][i]) across all opponents, for use as tiebreaker.
    function computeScoresAndMargins(int256[] memory matrix, uint256 c)
        internal
        pure
        returns (int256[] memory scores, int256[] memory margins)
    {
        require(matrix.length == c * c, "matrix size");
        scores = new int256[](c);
        margins = new int256[](c);
        for (uint256 i = 0; i < c; i++) {
            for (uint256 j = 0; j < c; j++) {
                if (i == j) continue;
                int256 m = matrix[i * c + j] - matrix[j * c + i];
                margins[i] += m;
                if (m > 0) {
                    scores[i] += 1;
                } else if (m < 0) {
                    scores[i] -= 1;
                }
            }
        }
    }

    /// @dev True iff candidate `a` ranks above candidate `b` by (score, margin, index).
    function _isGreater(uint8 a, uint8 b, int256[] memory scores, int256[] memory margins)
        private
        pure
        returns (bool)
    {
        if (scores[a] != scores[b]) return scores[a] > scores[b];
        if (margins[a] != margins[b]) return margins[a] > margins[b];
        return a < b;
    }
}
