#ifndef EX_VRP_MATRIXVIEW_H
#define EX_VRP_MATRIXVIEW_H

#include "Matrix.h"

#include <cstddef>
#include <optional>
#include <vector>

namespace ex_vrp
{
/**
 * A read-only view of a square matrix in which at most one row is replaced by
 * a row held elsewhere. Routing profiles that differ only in that row, such as
 * a depot row dated at each vehicle's departure hour, share one base matrix
 * through it instead of each owning a full copy.
 *
 * The view keeps a pointer to each row, so it costs one pointer per row
 * rather than a copy of the matrix. It does not own the rows: it must not
 * outlive the matrix and the row it points into.
 */
template <typename T> class MatrixView
{
    std::vector<T const *> rows_;
    size_t cols_;

public:
    MatrixView(Matrix<T> const &base,
               std::optional<size_t> overrideRow,
               T const *row)
        : rows_(base.numRows()), cols_(base.numCols())
    {
        for (size_t from = 0; from != rows_.size(); ++from)
            rows_[from] = base.data() + cols_ * from;

        if (overrideRow && *overrideRow < rows_.size())
            rows_[*overrideRow] = row;
    }

    [[nodiscard, gnu::always_inline]] inline T operator()(size_t from,
                                                          size_t to) const
    {
        return rows_[from][to];
    }

    /**
     * Pointer to the first of the row's ``numCols()`` entries. Two views of
     * one base matrix return the same pointer for every row neither replaces,
     * which lets callers skip rows they have already seen.
     */
    [[nodiscard, gnu::always_inline]] inline T const *row(size_t from) const
    {
        return rows_[from];
    }

    [[nodiscard]] size_t numCols() const { return cols_; }

    [[nodiscard]] size_t numRows() const { return rows_.size(); }
};
}  // namespace ex_vrp

#endif  // EX_VRP_MATRIXVIEW_H
