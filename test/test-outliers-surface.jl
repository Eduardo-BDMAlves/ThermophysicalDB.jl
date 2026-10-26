# The engine of the joint (surface) analysis: neighbour grid, tiles, small linear algebra,
# the cheap and the consensus fits, and the properties that the optimisations must keep.

@testitem "the neighbour grid finds the same points as a brute-force search" tags = [:unit] begin
    using StableRNGs
    T = ThermophysicalDB
    rng = StableRNG(1)
    for d in (2, 3), n in (60, 400)
        c = rand(rng, d, n)
        # Duplicated states and ties in distance, as in real data with several sources.
        c[:, 11:15] .= c[:, 10]
        c[:, 21] = c[:, 20] .+ [0.01, zeros(d - 1)...]
        c[:, 22] = c[:, 20] .- [0.01, zeros(d - 1)...]
        grid = T.SurfaceGrid(c, 4)
        ws = T.SurfaceWS(d, 40)
        for trial = 1:25
            m = rand(rng, 1:6)
            members = rand(rng, 1:n, m)
            unique!(members)
            m = length(members)
            ws.win[1:m] .= members
            ws.centre .= vec(sum(c[:, members]; dims = 2)) ./ m
            want = 23
            found = T.nearest_others!(ws, grid, c, m, want)
            others = setdiff(1:n, members)
            dist(j) = sum(abs2, c[:, j] .- ws.centre)
            expected = sort(others; by = j -> (dist(j), j))[1:want]
            @test found == want
            @test Int.(ws.best_i[1:want]) == expected
        end
    end
end

@testitem "tiles partition the points and stay small" tags = [:unit] begin
    using StableRNGs
    T = ThermophysicalDB
    rng = StableRNG(2)
    c = rand(rng, 2, 500)
    c[:, 100:160] .= c[:, 100]                        # a crowded cell
    grid = T.SurfaceGrid(c, 6)
    tiles = T.Tiles(grid, 24, 6)
    seen = zeros(Int, 500)
    for t in eachindex(tiles.lo)
        @test 1 <= tiles.hi[t] - tiles.lo[t] + 1 <= 6
        for a = tiles.lo[t]:tiles.hi[t]
            j = grid.members[a]
            seen[j] += 1
            @test tiles.tile_of[j] == t
        end
    end
    @test all(==(1), seen)
    @test tiles.wmax == 24 + 6 - 1
end

@testitem "the hand-written small linear algebra matches LinearAlgebra" tags =
    [:unit, :fast] begin
    using StableRNGs, LinearAlgebra
    T = ThermophysicalDB
    rng = StableRNG(3)
    for p in (3, 6, 10)
        B = randn(rng, 3p, p)
        S = B' * B
        L = tril(copy(S))
        @test T.cholesky_lower!(L, p)
        @test tril(L) ≈ Matrix(cholesky(Symmetric(S, :L)).L)
        b = randn(rng, p)
        x = copy(b)
        T.cholesky_solve!(L, x, p)
        @test x ≈ S \ b
        inv = zeros(p, p)
        T.cholesky_inverse!(inv, L, p)
        @test inv ≈ LinearAlgebra.inv(S)
    end
    # Not positive definite: refused, not trusted.
    @test !T.cholesky_lower!([1.0 0.0; 2.0 1.0], 2)
    for n in (1, 2, 7, 40), _ = 1:20
        v = randn(rng, 40)
        for k in unique((1, (n + 1) ÷ 2, n))
            w = copy(v)
            @test T.kth_smallest!(w, n, k) == sort(v[1:n])[k]
        end
        w = copy(v)
        T.sort_prefix!(w, n)
        @test w[1:n] == sort(v[1:n])
    end
    # Many equal values.
    v = Float64[3, 1, 3, 3, 2, 3, 1]
    @test T.kth_smallest!(copy(v), 7, 4) == 3.0
    @test T.kth_smallest!(copy(v), 7, 2) == 1.0
end

@testitem "the generator and the sampling are deterministic" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    out1, s1 = T.splitmix(UInt64(42))
    out2, s2 = T.splitmix(UInt64(42))
    @test out1 == out2 && s1 == s2
    @test T.splitmix(s1)[1] != out1
end

# A smooth surface with noise, a few isolated errors and one cluster of neighbouring errors.
@testmodule Surface begin
    using ThermophysicalDB: ThermophysicalDB
    using StableRNGs: StableRNG
    const T = ThermophysicalDB

    surface(a, b) = 1 + 2a - b + 0.5a * b + 0.8a^2 - 0.4b^2

    function task(; n = 900, noise = 0.01, seed = 4, planted = 12, cluster = true, d = 2)
        rng = StableRNG(seed)
        c = rand(rng, d, n)
        y = [
            surface(c[1, i], c[2, i]) + (d == 3 ? 0.3c[3, i] : 0.0) + noise * randn(rng) for i = 1:n
        ]
        bad = Int[]
        for k = 1:planted
            i = 7 * k + 3
            y[i] += (isodd(k) ? 1 : -1) * 25noise
            push!(bad, i)
        end
        if cluster
            centre = c[:, 500]
            order = sortperm([sum(abs2, c[:, j] .- centre) for j = 1:n])
            near = filter(j -> !(j in bad), order)[1:3]
            for i in near
                y[i] += 30noise
                push!(bad, i)
            end
        end
        xi = copy(c)
        t = T.JointTask(
            1,
            collect(1:d),
            collect(1:n),
            xi,
            copy(xi),
            y,
            fill(noise, n),
            rand(rng, Int32(1):Int32(3), n),
        )
        return t, unique!(bad)
    end
end

@testitem "the surface stage standardizes clean points and exposes planted errors" setup =
    [Surface] tags = [:unit] begin
    T = ThermophysicalDB
    for d in (2, 3)
        t, bad = Surface.task(; d, n = d == 2 ? 900 : 1500)
        T.process_joint!(t, T.Settings())
        clean = setdiff(findall(isfinite, t.z), bad)
        @test length(clean) > 0.95 * (length(t.z) - length(bad))
        zs = t.z[clean]
        # Calibration: the standardized residuals of the clean points have unit scale.
        @test 0.85 < sqrt(sum(abs2, zs) / length(zs)) < 1.35
        @test count(>(3.5), abs.(zs)) / length(zs) < 0.02
        # Every planted error, including the three that sit side by side, is far out.
        @test all(i -> isfinite(t.z[i]) && abs(t.z[i]) > 5, bad)
        # And the consensus leaves them out.
        @test all(i -> t.consensus[i] < t.window[i], bad)
        # The fitted surface agrees with the truth where the points are clean.
        if d == 2
            err = [abs(t.yhat[i] - Surface.surface(t.xi[1, i], t.xi[2, i])) for i in clean]
            @test maximum(err) < 0.05
            @test sort(err)[length(err)÷2] < 0.01
        end
    end
end

@testitem "tiles, screening and the number of threads do not change what is flagged" setup =
    [Surface] tags = [:unit] begin
    T = ThermophysicalDB
    _, bad = Surface.task()
    flagged(t) = Set(findall(z -> isfinite(z) && abs(z) > 3.5, t.z))
    reference = Ref{Any}(nothing)
    for (tile, screening) in ((1, 0.0), (1, 0.7), (3, 0.7), (6, 0.7), (6, 0.0))
        t, _ = Surface.task()
        T.process_joint!(t, T.Settings(; tile, screening))
        f = flagged(t)
        @test issubset(Set(bad), f)
        reference[] === nothing && (reference[] = f)
        # A handful of borderline points may differ; no more than that.
        @test length(symdiff(f, reference[])) ≤ 6
    end
    # Sequential and threaded runs are bit for bit equal.
    a, _ = Surface.task()
    b, _ = Surface.task()
    set = T.Settings(; tile = 4)
    T.process_joint!(a, set; threaded = false)
    T.process_joint!(b, set)
    @test isequal(a.z, b.z) && isequal(a.yhat, b.yhat) && isequal(a.slope_sd, b.slope_sd)
    @test isequal(a.curvature, b.curvature) && isequal(a.cross, b.cross)
    # The seed only changes which subsets the consensus search draws; only borderline points
    # can change side.
    c, _ = Surface.task()
    T.process_joint!(c, T.Settings(; tile = 4, seed = 99))
    @test issubset(Set(bad), flagged(c))
    @test length(symdiff(flagged(c), flagged(a))) ≤ 4
end

@testitem "screening skips the consensus fit of clean regions and the clusters around errors" setup =
    [Surface] tags = [:unit] begin
    T = ThermophysicalDB
    t, bad = Surface.task()
    set = T.Settings()
    grid = T.SurfaceGrid(t.scaled, set.tile)
    tiles = T.Tiles(grid, 24, set.tile)
    peak = zeros(length(tiles.lo))
    # No point is beyond the screening threshold: nothing is promoted.
    @test isempty(T.promoted_tiles(tiles, peak, 24, set))
    # A tile with a suspicious point is promoted, and one beyond the inlier threshold also
    # promotes the tiles of its closest neighbours.
    peak[1] = 0.9 * set.cutoff
    @test T.promoted_tiles(tiles, peak, 24, set) == [1]
    ws = T.SurfaceWS(2, tiles.wmax)
    @test T.make_window!(ws, grid, t.scaled, tiles, 1, 24)
    peak[1] = 1.1 * set.cutoff
    promoted = T.promoted_tiles(tiles, peak, 24, set)
    @test 1 in promoted && length(promoted) > 1
    nearest = tiles.windows[(tiles.hi[1]-tiles.lo[1]+2):(tiles.hi[1]-tiles.lo[1]+1+12), 1]
    @test all(j -> tiles.tile_of[j] in promoted, nearest)
    # Screening off: every tile that could be fitted is refitted.
    all_tiles =
        T.promoted_tiles(tiles, zeros(length(tiles.lo)), 24, T.Settings(; screening = 0.0))
    @test length(all_tiles) == length(tiles.lo)
end

@testitem "degenerate subgroups are reported as untested, not as errors" tags = [:unit] begin
    T = ThermophysicalDB
    n = 60
    # All points on a line of the plane: the quadratic surface is not determined.
    s = collect(range(0.0, 1.0; length = n))
    xi = vcat(s', s')
    t = T.JointTask(
        1,
        [1, 2],
        collect(1:n),
        xi,
        copy(xi),
        1 .+ s,
        fill(0.01, n),
        fill(Int32(1), n),
    )
    T.process_joint!(t, T.Settings())
    @test all(==(0), t.window)
    @test all(isnan, t.z)
    # Too few points for the window: the subgroup is skipped.
    xi = rand(2, 10)
    t = T.JointTask(
        1,
        [1, 2],
        collect(1:10),
        xi,
        copy(xi),
        xi[1, :],
        fill(0.01, 10),
        fill(Int32(1), 10),
    )
    T.process_joint!(t, T.Settings())
    @test t.skipped[]
    # A window requested below the number of coefficients is refused.
    xi = rand(2, 100)
    t = T.JointTask(
        1,
        [1, 2],
        collect(1:100),
        xi,
        copy(xi),
        xi[1, :],
        fill(0.01, 100),
        fill(Int32(1), 100),
    )
    @test_throws ArgumentError T.process_joint!(t, T.Settings(; neighbors = 6))
end

@testitem "the consensus recovers a surface among a third of wrong points" setup = [Surface] tags =
    [:unit] begin
    using StableRNGs
    T = ThermophysicalDB
    rng = StableRNG(8)
    d, W = 2, 30
    ws = T.SurfaceWS(d, W)
    ws.W = W
    c = rand(rng, d, W) .- 0.5
    for l = 1:W
        ws.delta[:, l] .= c[:, l]
        ws.X[l, 1] = 1.0
        ws.X[l, 2] = c[1, l]
        ws.X[l, 3] = c[2, l]
        ws.X[l, 4] = c[1, l]^2
        ws.X[l, 5] = c[1, l] * c[2, l]
        ws.X[l, 6] = c[2, l]^2
        ws.y[l] =
            1 + 2c[1, l] - c[2, l] + 0.5c[1, l]^2 + 0.3c[1, l] * c[2, l] + 0.002randn(rng)
        ws.u[l] = 0.002
        ws.wgt[l] = 1 / 0.002^2
    end
    wrong = collect(1:3:W)                       # a third of the window
    ws.y[wrong] .+= 0.2 .+ 0.1 .* rand(rng, length(wrong))
    ws.known = true
    ws.ymax = maximum(abs, ws.y)
    ws.rng = UInt64(5)
    @test T.lqs_consensus!(ws, 20, 2.5)
    @test !any(ws.mask[wrong])
    @test count(ws.mask) ≥ 19
    @test T.robust_refit!(ws, 2.5, T.truncated_variance(2.5))
    @test all(abs.(ws.z[wrong]) .> 10)
    others = setdiff(1:W, wrong)
    @test count(i -> abs(ws.z[i]) < 3.5, others) ≥ length(others) - 1
end
