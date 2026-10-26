# The detection itself: group the points, run the three analyses, pool the results,
# decide the category of every point and collect the reasons.

function empty_result(view::DataView, notes)
    empty = DataView(view.dataset, Int32[])
    counts = (;
        input = 0,
        kept = 0,
        outliers = 0,
        disputed = 0,
        physical = 0,
        tested = 0,
        untested = 0,
        single_source = 0,
        groups = 0,
        joint_skipped = 0,
    )
    return OutlierResult(
        view,
        empty,
        empty,
        view,
        UInt8[],
        ReasonRow[],
        DiagnosticRow[],
        counts,
        (;),
        notes,
    )
end

function run_detection(
    view,
    set,
    physical,
    trend,
    joint,
    transform,
    policy,
    limits,
    source_offset,
)
    ds = view.dataset
    n = length(view)
    notes = String[]
    n == 0 && return empty_result(view, notes)
    fraction_kind = fraction_kinds(ds)
    prep = prepare_points(view, policy, fraction_kind)
    pr = ds.properties

    # Stage 0: physical rules.
    phys = fill("", n)
    if physical
        bounds = [property_bounds(pr.label[p], limits) for p = 1:length(pr)]
        for pos = 1:n
            phys[pos] = physical_violation(
                ds,
                view.rows[pos],
                bounds[prep.prop[pos]],
                fraction_kind,
            )
        end
    end

    # Subgroups: same system, property and phase, and the same coordinates available.
    groups = Dict{NTuple{9,Int32},Vector{Int}}()
    if trend || joint
        for pos = 1:n
            isempty(phys[pos]) || continue
            isfinite(prep.y[pos]) || continue
            key = (
                prep.system[pos]...,
                prep.prop[pos],
                prep.phase[pos],
                Int32(prep.mask[pos]),
            )
            push!(get!(groups, key, Int[]), pos)
        end
    end
    group_keys = sort!(collect(keys(groups)))
    transforms = Transformation[]
    group_property = Int[]
    line_tasks = LineTask[]
    joint_tasks = JointTask[]
    coord = prep.coord
    for (g, key) in enumerate(group_keys)
        idx = groups[key]
        prop = Int(key[7])
        push!(group_property, prop)
        label = pr.label[prop]
        ys = prep.y[idx]
        temperatures = Float64[v for v in coord[idx, 1] if isfinite(v)]
        tr = choose_transformation(
            transform,
            label,
            pool_string(ds.phases, key[8]),
            ys,
            coord[idx, 2],
        )
        if tr.inverse_T && any(<=(0), temperatures)
            tr = Transformation(tr.log_response, false, tr.log_P)
        end
        push!(transforms, tr)
        bits = UInt8(key[9])
        present = [a for a = 1:4 if (bits >> (a - 1)) & 0x01 == 0x01]
        varying = Int[]
        for a in present
            lo, hi = extrema(@view coord[idx, a])
            if hi - lo > axis_tolerance(set.tolerance, a, max(abs(lo), abs(hi)))
                push!(varying, a)
            end
        end
        isempty(varying) && continue
        yt(i) = forward_response(tr, prep.y[i])
        ut(i) = tr.log_response ? prep.u[i] / prep.y[i] : prep.u[i]
        if trend
            for a in varying
                others = filter(!=(a), varying)
                for cluster in cluster_states(coord, idx, others, set.tolerance)
                    length(cluster) < set.min_points && continue
                    xi_of(i) = forward_axis(tr, a, coord[i, a])
                    ordered = sort(cluster; by = i -> (xi_of(i), i))
                    push!(
                        line_tasks,
                        LineTask(
                            g,
                            a,
                            ordered,
                            Float64[xi_of(i) for i in ordered],
                            Float64[coord[i, a] for i in ordered],
                            Float64[yt(i) for i in ordered],
                            Float64[ut(i) for i in ordered],
                            Int32[prep.ref[i] for i in ordered],
                        ),
                    )
                end
            end
        end
        if joint && length(varying) >= 2
            enough = all(varying) do a
                count_distinct(set.tolerance, a, sort(coord[idx, a])) >= 3
            end
            if enough
                d = length(varying)
                xi = Matrix{Float64}(undef, d, length(idx))
                x = Matrix{Float64}(undef, d, length(idx))
                for (c, i) in enumerate(idx), (l, a) in enumerate(varying)
                    xi[l, c] = forward_axis(tr, a, coord[i, a])
                    x[l, c] = coord[i, a]
                end
                push!(
                    joint_tasks,
                    JointTask(
                        g,
                        varying,
                        idx,
                        xi,
                        x,
                        Float64[yt(i) for i in idx],
                        Float64[ut(i) for i in idx],
                        Int32[prep.ref[i] for i in idx],
                    ),
                )
            else
                push!(
                    notes,
                    "subgroup $(g) ($(label)): the surface analysis needs at least " *
                    "3 distinct values on each varying axis; only the line analysis ran.",
                )
            end
        end
    end

    # Stages 1 and 2: the local fits.
    dynamic_foreach(length(line_tasks)) do _, i
        process_line!(line_tasks[i], set)
    end
    for task in joint_tasks
        process_joint!(task, set)
    end
    skipped = count(t -> t.skipped[], joint_tasks)
    skipped > 0 && push!(
        notes,
        "$(skipped) subgroup(s) were too small, or larger than " *
        "max_joint_points = $(set.max_joint_points), for the surface analysis.",
    )

    # ESD on the pooled standardized residuals, one pool per subgroup and analysis.
    line_pools = Dict{Tuple{Int,Int},Vector{Tuple{Int,Int}}}()
    for (ti, t) in enumerate(line_tasks), j in eachindex(t.z)
        isfinite(t.z[j]) || continue
        push!(get!(line_pools, (t.group, t.axis), Tuple{Int,Int}[]), (ti, j))
    end
    joint_pools = Dict{Int,Vector{Int}}()
    for (ti, t) in enumerate(joint_tasks)
        entries = Int[j for j in eachindex(t.z) if isfinite(t.z[j])]
        isempty(entries) || (joint_pools[ti] = entries)
    end
    tests = zeros(Int, length(group_keys))
    for (key, entries) in line_pools
        length(entries) >= set.min_pool && (tests[key[1]] += 1)
    end
    for (ti, entries) in joint_pools
        length(entries) >= set.min_pool && (tests[joint_tasks[ti].group] += 1)
    end
    line_cert = [fill(NaN, length(t.z)) for t in line_tasks]
    joint_cert = [fill(NaN, length(t.z)) for t in joint_tasks]
    esd_run(zs, group) = esd(
        zs;
        max_outliers = set.max_outliers,
        level = set.level / tests[group],
        critical = set.critical,
    )
    for key in sort!(collect(keys(line_pools)))
        entries = line_pools[key]
        length(entries) >= set.min_pool || continue
        zs = Float64[line_tasks[ti].z[j] for (ti, j) in entries]
        res = esd_run(zs, key[1])
        cert = flag_certainty(zs)
        for rank = 1:res.count
            k = res.order[rank]
            abs(zs[k]) > set.cutoff || continue
            ti, j = entries[k]
            t = line_tasks[ti]
            t.flag[j] = true
            t.statistic[j] = res.statistic[rank]
            t.critical[j] = res.critical[rank]
            t.rank[j] = rank
            line_cert[ti][j] = cert[k]
        end
    end
    for ti in sort!(collect(keys(joint_pools)))
        entries = joint_pools[ti]
        length(entries) >= set.min_pool || continue
        t = joint_tasks[ti]
        zs = Float64[t.z[j] for j in entries]
        res = esd_run(zs, t.group)
        cert = flag_certainty(zs)
        for rank = 1:res.count
            k = res.order[rank]
            abs(zs[k]) > set.cutoff || continue
            j = entries[k]
            t.flag[j] = true
            t.statistic[j] = res.statistic[rank]
            t.critical[j] = res.critical[rank]
            t.rank[j] = rank
            joint_cert[ti][j] = cert[k]
        end
    end

    # Reasons, diagnostics and categories.
    tested = falses(n)
    tested_line = falses(n)
    tested_joint = falses(n)
    multi = falses(n)
    flag_line = falses(n)
    flag_joint = falses(n)
    flag_offset = falses(n)
    reason_rows = ReasonRow[]
    diagnostic_rows = DiagnosticRow[]
    value_of(pos) = prep.y[pos]

    for pos = 1:n
        isempty(phys[pos]) || push!(
            reason_rows,
            ReasonRow(
                pos,
                :physical_rule,
                :none,
                NaN,
                NaN,
                0,
                NaN,
                NaN,
                NaN,
                1.0,
                phys[pos],
            ),
        )
    end
    esd_text(
        R,
        lambda,
        rank,
    ) = "ESD step $(rank): R = $(round(R; sigdigits = 4)) > λ = $(round(lambda; sigdigits = 4))."
    for (ti, t) in enumerate(line_tasks)
        tr = transforms[t.group]
        label = pr.label[group_property[t.group]]
        rule = sign_rule(label, t.axis)
        axis = AXES[t.axis]
        for j in eachindex(t.pos)
            t.window[j] > 0 || continue
            pos = t.pos[j]
            isfinite(t.z[j]) && (tested[pos] = true; tested_line[pos] = true)
            t.multi_source[j] && (multi[pos] = true)
            reference = backward_response(tr, t.yhat[j])
            scale_y = tr.log_response ? reference : 1.0
            fprime = axis_derivative(tr, t.axis, t.x[j])
            slope = t.slope[j] * fprime * scale_y
            slope_sd = t.slope_sd[j] * abs(fprime) * scale_y
            push!(
                diagnostic_rows,
                DiagnosticRow(
                    pos,
                    :trend_1d,
                    axis,
                    t.z[j],
                    t.window[j],
                    t.consensus[j],
                    t.phi[j],
                    slope,
                    slope_sd,
                    t.curvature[j],
                    t.curvature_sd[j],
                    t.influence[j],
                    sign_verdict(rule, slope, slope_sd, set.sign_sigma),
                    NaN,
                    NaN,
                    t.flag[j],
                    describe(tr),
                ),
            )
            if t.flag[j]
                flag_line[pos] = true
                detail =
                    "z = $(round(t.z[j]; digits = 2)) from a local parabola along $(axis) " *
                    "($(t.window[j]) points, $(t.consensus[j]) in agreement, fitted in " *
                    "$(describe(tr))). " *
                    esd_text(t.statistic[j], t.critical[j], t.rank[j]) *
                    unit_hint(value_of(pos), reference)
                push!(
                    reason_rows,
                    ReasonRow(
                        pos,
                        :trend_1d,
                        axis,
                        t.statistic[j],
                        t.critical[j],
                        t.rank[j],
                        t.z[j],
                        reference,
                        value_of(pos) - reference,
                        line_cert[ti][j],
                        detail,
                    ),
                )
            end
            if t.offset[j]
                flag_offset[pos] = true
                detail =
                    "$(t.offset_deviating[j]) of the $(t.offset_members[j]) points of the " *
                    "same publication in the window lie on the same side of the trend " *
                    "defined by the other sources (z = $(round(t.z[j]; digits = 2)) along $(axis)): " *
                    "a systematic offset of the source is more likely than isolated errors."
                push!(
                    reason_rows,
                    ReasonRow(
                        pos,
                        :source_offset,
                        axis,
                        NaN,
                        NaN,
                        0,
                        t.z[j],
                        reference,
                        value_of(pos) - reference,
                        NaN,
                        detail,
                    ),
                )
            end
        end
    end
    for (ti, t) in enumerate(joint_tasks)
        tr = transforms[t.group]
        names = join(AXES[a] for a in t.axes)
        for j in eachindex(t.pos)
            t.window[j] > 0 || continue
            pos = t.pos[j]
            isfinite(t.z[j]) && (tested[pos] = true; tested_joint[pos] = true)
            t.multi_source[j] && (multi[pos] = true)
            reference = backward_response(tr, t.yhat[j])
            scale_y = tr.log_response ? reference : 1.0
            push!(
                diagnostic_rows,
                DiagnosticRow(
                    pos,
                    :joint_surface,
                    :joint,
                    t.z[j],
                    t.window[j],
                    t.consensus[j],
                    t.phi[j],
                    NaN,
                    NaN,
                    NaN,
                    NaN,
                    NaN,
                    :not_applicable,
                    t.cross[j],
                    t.cross_sd[j],
                    t.flag[j],
                    describe(tr),
                ),
            )
            for (l, a) in enumerate(t.axes)
                fprime = axis_derivative(tr, a, t.x[l, j])
                push!(
                    diagnostic_rows,
                    DiagnosticRow(
                        pos,
                        :joint_surface,
                        AXES[a],
                        NaN,
                        t.window[j],
                        t.consensus[j],
                        t.phi[j],
                        t.slope[l, j] * fprime * scale_y,
                        t.slope_sd[l, j] * abs(fprime) * scale_y,
                        t.curvature[l, j],
                        t.curvature_sd[l, j],
                        NaN,
                        :not_applicable,
                        NaN,
                        NaN,
                        false,
                        describe(tr),
                    ),
                )
            end
            if t.flag[j]
                flag_joint[pos] = true
                detail =
                    "z = $(round(t.z[j]; digits = 2)) from a local quadratic surface in " *
                    "$(names) ($(t.window[j]) neighbours, $(t.consensus[j]) in agreement, " *
                    "fitted in $(describe(tr))). " *
                    esd_text(t.statistic[j], t.critical[j], t.rank[j]) *
                    unit_hint(value_of(pos), reference)
                push!(
                    reason_rows,
                    ReasonRow(
                        pos,
                        :joint_surface,
                        :joint,
                        t.statistic[j],
                        t.critical[j],
                        t.rank[j],
                        t.z[j],
                        reference,
                        value_of(pos) - reference,
                        joint_cert[ti][j],
                        detail,
                    ),
                )
            end
        end
    end

    # Category, by order of precedence: a physical violation is an outlier; a systematic
    # source offset is a dispute (or an outlier on request); a flag along an axis is an
    # outlier; a flag of the joint surface alone is a dispute.
    category = fill(KEPT, n)
    for pos = 1:n
        if !isempty(phys[pos])
            category[pos] = OUTLIER
        elseif flag_offset[pos]
            category[pos] = source_offset === :outlier ? OUTLIER : DISPUTED
        elseif flag_line[pos]
            category[pos] = OUTLIER
        elseif flag_joint[pos]
            category[pos] = DISPUTED
        end
    end
    sort!(reason_rows; by = r -> (r.pos, r.code, r.axis))
    sort!(diagnostic_rows; by = r -> (r.pos, r.stage, r.axis))

    pick(c) = DataView(ds, Int32[view.rows[pos] for pos = 1:n if category[pos] == c])
    untested = count(pos -> !tested[pos] && isempty(phys[pos]), 1:n)
    point_certainty = fill(NaN, n)
    for row in reason_rows
        isfinite(row.certainty) || continue
        point_certainty[row.pos] = max(
            isnan(point_certainty[row.pos]) ? 0.0 : point_certainty[row.pos],
            row.certainty,
        )
    end
    mean_certainty(c) = begin
        v = Float64[
            point_certainty[pos] for
            pos = 1:n if category[pos] == c && isfinite(point_certainty[pos])
        ]
        isempty(v) ? NaN : sum(v) / length(v)
    end
    certainty_outliers = mean_certainty(OUTLIER)
    certainty_disputed = mean_certainty(DISPUTED)
    flagged_certainty = Float64[
        point_certainty[pos] for
        pos = 1:n if category[pos] != KEPT && isfinite(point_certainty[pos])
    ]
    certainty =
        isempty(flagged_certainty) ? NaN :
        sum(flagged_certainty) / length(flagged_certainty)
    both_tested = 0
    both_flagged = 0
    for pos = 1:n
        (flag_line[pos] || flag_joint[pos]) && tested_line[pos] && tested_joint[pos] ||
            continue
        both_tested += 1
        flag_line[pos] && flag_joint[pos] && (both_flagged += 1)
    end
    corroboration = both_tested == 0 ? NaN : both_flagged / both_tested
    counts = (;
        input = n,
        kept = count(==(KEPT), category),
        outliers = count(==(OUTLIER), category),
        disputed = count(==(DISPUTED), category),
        physical = count(!isempty, phys),
        tested = count(tested),
        untested,
        single_source = count(pos -> tested[pos] && !multi[pos], 1:n),
        groups = length(group_keys),
        joint_skipped = skipped,
        certainty,
        certainty_outliers,
        certainty_disputed,
        corroboration,
    )
    if untested > 0
        push!(
            notes,
            "$(untested) point(s) had too few neighbours for any trend analysis " *
            "and were only checked against the physical rules.",
        )
    end
    parameters = (;
        physical,
        trend,
        joint,
        window = set.window,
        min_points = set.min_points,
        neighbors = set.neighbors,
        consensus_fraction = set.fraction,
        inlier_threshold = set.cutoff,
        level = set.level,
        max_outliers = set.max_outliers,
        critical = set.critical,
        transform,
        tolerance = set.tolerance,
        policy,
        seed = set.seed,
        source_offset,
        sign_sigma = set.sign_sigma,
        screening = set.screening,
        tile = set.tile,
    )
    return OutlierResult(
        pick(KEPT),
        pick(OUTLIER),
        pick(DISPUTED),
        view,
        category,
        reason_rows,
        diagnostic_rows,
        counts,
        parameters,
        notes,
    )
end
