# Turn `numactl --hardware` into one tab-separated record per node:
#
#   node <TAB> cpu_count <TAB> cpu_ranges <TAB> size <TAB> free
#
# cpu_ranges collapses the few hundred cpu ids numactl prints on a single line
# into "0-71,144-215". A node with no cpus yields count 0 and an empty range,
# which is how a memory-only node (CXL exposed as system-ram) shows up.

function ranges(s,   n, a, i, out, start, prev) {
    n = split(s, a, " ")
    if (n == 0) return ""
    start = a[1]; prev = a[1]; out = ""
    for (i = 2; i <= n; i++) {
        if (a[i] + 0 == prev + 1) { prev = a[i]; continue }
        out = out (out == "" ? "" : ",") (start == prev ? start : start "-" prev)
        start = a[i]; prev = a[i]
    }
    return out (out == "" ? "" : ",") (start == prev ? start : start "-" prev)
}

/^node [0-9]+ cpus:/ {
    node = $2
    cpus = $0; sub(/^node [0-9]+ cpus:[ \t]*/, "", cpus)
    count[node] = split(cpus, discard, " ")
    range[node] = ranges(cpus)
    order[++seen] = node
    next
}

/^node [0-9]+ (size|free):/ {
    if ($3 == "size:") size[$2] = substr($0, index($0, ":") + 2)
    else               free[$2] = substr($0, index($0, ":") + 2)
    next
}

END {
    for (i = 1; i <= seen; i++) {
        n = order[i]
        printf "%s\t%d\t%s\t%s\t%s\n", n, count[n], range[n], size[n], free[n]
    }
}
