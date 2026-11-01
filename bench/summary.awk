# The summary at the end of `just bench-compare` (bench/README.md): for each
# operation and size class, this package's throughput against each other
# arm's. The classes are icons (at most 64 by 64 pixels), up to a
# megapixel, and larger, from the -WxH that ends each input's name.
#
#     awk -f bench/summary.awk [-v rows=FILE] DIR/image.txt DIR/wuffs.txt ...
#
# The first file is this package's; each holds `Benchmark<Row>/<input> <n> <MP/s> MP/s`
# lines, one per round, in round order, so the k-th line of a row in each
# file comes from the same round. `just bench-compare` times the arms on a
# row back to back, so a row's ratio in one round compares the arms on the
# same machine state. A row's ratio is the median over the rounds of
# image's MP/s divided by the arm's in the same round, with a 95% confidence
# interval from the order statistics, as benchstat's; an operation's ratio
# is the geometric mean of its rows'. Above 1, image is faster.
#
# Against the first other arm, Wuffs, the summary also counts the rows
# image is slower on beyond their interval (`<1`), the rows whose interval
# holds 1 (`~`: their spread exceeds their gap, so they cannot be called
# either way), gives the spread of the operation's geomean over the rounds
# (`±`, half its interval), and names the slowest row and its interval.
# With `-v rows=FILE`, every row against every arm goes to FILE: the row, the
# arm, both median MP/s, the median ratio and its interval, and `<`, `>`,
# or `~`.

FNR == 1 {
    arm = FILENAME
    sub(/.*\//, "", arm)
    sub(/\.txt$/, "", arm)
    arms[++narms] = arm
}

/^Benchmark/ {
    row = $1
    sub(/^Benchmark/, "", row)
    op = row
    sub(/\/.*/, "", op)
    op = op "/" class(row)
    if (!(op in seen)) {
        seen[op] = 1
        ops[++nops] = op
    }
    if (!((op, row) in has_row)) {
        has_row[op, row] = 1
        op_rows[op, ++nrows[op]] = row
    }
    k = arm SUBSEP row
    v[k, ++n[k]] = $3
}

# An input's size class, from the -WxH that ends its name.
function class(row,    s, d) {
    s = row
    sub(/.*-/, "", s)
    split(s, d, /[x.]/)
    return d[1] * d[2] <= 4096 ? "icon" : d[1] * d[2] <= 1048576 ? "1mp" : "large"
}

function sort(a, m,    i, j, t) {
    for (i = 2; i <= m; i++) {
        t = a[i]
        for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]
        a[j + 1] = t
    }
}

function median(a, m) {
    return m % 2 ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
}

# The rank of the order statistic that bounds a 95% interval for the median
# of m values: the largest c with P(Binomial(m, 1/2) < c) <= 0.025, at least
# 1 (the extremes, below 6 values).
function rank(m,    c, p, cum) {
    p = 0.5 ^ m
    cum = p
    for (c = 1; ; c++) {
        p = p * (m - c + 1) / c
        if (cum + p > 0.025) break
        cum += p
    }
    return c
}

# Sorts a[1..m] and sets lo, mid, and hi to its median and interval.
function interval(a, m,    c) {
    sort(a, m)
    c = rank(m)
    lo = a[c]
    hi = a[m + 1 - c]
    mid = median(a, m)
}

function gbs(k,    i, a) {
    for (i = 1; i <= n[k]; i++) a[i] = v[k, i] + 0
    sort(a, n[k])
    return median(a, n[k])
}

function verdict(lo, hi) {
    return hi < 1 ? "<" : lo > 1 ? ">" : "~"
}

function fmt(x) {
    return x == "" ? "-" : sprintf("%.2f", x)
}

END {
    if (narms < 2) exit
    ref = arms[1]
    printf "%-30s %5s %10s", "image/arm, geomean", "rows", "image MP/s"
    for (a = 2; a <= narms; a++) printf " %8s", arms[a]
    printf " %5s %4s %4s   %s\n", "±", "<1", "~", "slowest vs " arms[2]
    for (i = 1; i <= nops; i++) {
        op = ops[i]
        own = 0; nown = 0
        delete logsum; delete nshared; delete round_log; delete round_n
        worst = ""; worst_row = ""; under = 0; level = 0
        for (r = 1; r <= nrows[op]; r++) {
            row = op_rows[op, r]
            ku = ref SUBSEP row
            if (!(ku in n)) continue
            u = gbs(ku)
            own += log(u); nown++
            for (a = 2; a <= narms; a++) {
                k = arms[a] SUBSEP row
                if (!(k in n)) continue
                m = n[k] < n[ku] ? n[k] : n[ku]
                delete q
                for (j = 1; j <= m; j++) {
                    q[j] = v[ku, j] / v[k, j]
                    if (a == 2) { round_log[j] += log(q[j]); round_n[j]++ }
                }
                interval(q, m)
                logsum[a] += log(mid); nshared[a]++
                all_logsum[a] += log(mid); all_n[a]++
                if (rows != "")
                    printf "%-64s %-8s %9.1f %9.1f %6.3f %6.3f %6.3f %s\n", row, arms[a], u, gbs(k), mid, lo, hi, verdict(lo, hi) > rows
                if (a != 2) continue
                if (hi < 1) under++
                else if (lo <= 1) level++
                if (worst == "" || mid < worst) {
                    worst = mid; worst_lo = lo; worst_hi = hi
                    worst_row = row
                    sub(/^[^\/]*\//, "", worst_row)
                }
            }
        }
        if (nown == 0) continue
        all_own += own; all_nown += nown
        all_under += under; all_level += level
        printf "%-30s %5d %10.1f", op, nown, exp(own / nown)
        for (a = 2; a <= narms; a++) printf " %8s", fmt(nshared[a] ? exp(logsum[a] / nshared[a]) : "")
        spread = "-"
        if (nshared[2]) {
            # The operation's geomean against Wuffs in each round, over
            # the rows every round has.
            delete g; m = 0
            for (j = 1; (j in round_n) && round_n[j] == nshared[2]; j++) g[++m] = exp(round_log[j] / round_n[j])
            if (m > 1) {
                interval(g, m)
                spread = sprintf("%.0f%%", 50 * (hi - lo) / mid)
            }
        }
        printf " %5s %4d %4d   %s\n", spread, under, level, worst == "" ? "-" : sprintf("%.2f [%.2f, %.2f] %s", worst, worst_lo, worst_hi, worst_row)
    }
    printf "%-30s %5d %10.1f", "all", all_nown, all_nown ? exp(all_own / all_nown) : 0
    for (a = 2; a <= narms; a++) printf " %8s", fmt(all_n[a] ? exp(all_logsum[a] / all_n[a]) : "")
    printf " %5s %4d %4d\n", "", all_under, all_level
}
