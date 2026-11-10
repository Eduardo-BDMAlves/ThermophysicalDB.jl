# A deterministic synthetic database for the benchmarks.
#
# Only the public interface of the package is used (apart from the empty `Dataset` that holds the
# data), so the same file runs on any revision, the latest release included. The numbers are
# invented: smooth functions of temperature, pressure and composition plus noise, with a few
# per cent of wrong points injected on purpose so that the search for outliers has something to find.

module Synthetic

using Random: Xoshiro, rand, randn, randperm
using ThermophysicalDB: ThermophysicalDB

const T = ThermophysicalDB

# Number of measurements of each size of the benchmark.
const SCALES = (small = 20_000, medium = 200_000, full = 2_780_000)

const SEED = 20260101
const COMPOUND_COUNT = 60
const POINTS_PER_REFERENCE = 90

# label, unit, base value, relative change with temperature (per K), with pressure (per kPa)
const PROPERTIES = (
    ("Mass density", "kg/m3", 800.0, -7.0e-4, 4.0e-7),
    ("Viscosity", "Pa s", 1.2e-3, -1.6e-2, 2.0e-6),
    ("Thermal conductivity", "W/m/K", 0.14, -1.0e-3, 1.0e-7),
    ("Heat capacity at constant pressure per volume", "J/K/m3", 1.7e6, 4.0e-4, 2.0e-8),
    ("Speed of sound", "m/s", 1250.0, -2.5e-3, 6.0e-7),
    ("Vapor pressure", "kPa", 55.0, 3.0e-2, 0.0),
)

inchikey(i::Integer) = string(
    join(Char('A' + (7 * i + 3 * k) % 26) for k = 1:14),
    '-',
    join(Char('A' + (11 * i + 5 * k) % 26) for k = 1:10),
    "-N",
)
compound_name(i::Integer) = string("alkane-", lpad(i, 2, '0'))

"""
    compound_database() -> CompoundDB

The compounds of the synthetic database, known by two names, a formula and a number of CAS.
"""
function compound_database()
    cdb = T.CompoundDB()
    for i = 1:COMPOUND_COUNT
        T.register_compound!(
            cdb;
            names = [compound_name(i), string("synthetic compound ", i)],
            inchikey = inchikey(i),
            cas = string(10000 + i, "-", 10 + i % 90, "-", i % 10),
            formula = string("C", i, "H", 2i + 2),
        )
    end
    return cdb
end

# The experiments of one article: `count` systems with one to three compounds each.
function experiments(rng, count::Integer, wrong::Float64)
    list = NamedTuple[]
    for _ = 1:count
        ncomp = rand(rng, 1:3)
        picked = randperm(rng, COMPOUND_COUNT)[1:ncomp]
        label, unit, base, dT, dP = PROPERTIES[rand(rng, 1:length(PROPERTIES))]
        temperatures = collect(range(250.0, 450.0; length = rand(rng, 8:12)))
        pressures = [101.325, 5.0e3, 2.0e4, 6.0e4][1:rand(rng, 2:4)]
        n = length(temperatures) * length(pressures)
        T_col = repeat(temperatures; inner = length(pressures))
        P_col = repeat(pressures; outer = length(temperatures))
        fractions = ncomp == 1 ? zeros(n, 0) : rand(rng, n, ncomp - 1) ./ ncomp
        shift = 1 + 0.3 * sum(picked) / (COMPOUND_COUNT * ncomp)
        value = [
            base *
            shift *
            (1 + dT * (T_col[k] - 300.0) + dP * (P_col[k] - 101.325)) *
            (1 + 0.002 * randn(rng)) for k = 1:n
        ]
        for k = 1:n
            rand(rng) < wrong && (value[k] *= rand(rng, (0.7, 1.4)))
        end
        row = (
            components = [inchikey(i) for i in picked],
            property = label,
            unit = unit,
            temperature = T_col,
            pressure = P_col,
            value = value,
            unc = 0.01 .* abs.(value),
            unc_k = 2.0,
        )
        if ncomp > 1
            row = merge(row, (; composition_scale = fill(:mole_fraction, ncomp)))
            for j = 1:(ncomp-1)
                row = merge(row, NamedTuple{(Symbol("x", j),)}((fractions[:, j],)))
            end
        end
        push!(list, row)
    end
    return list
end

"""
    article(index; seed = SEED, wrong = 0.02) -> (reference, experiments)

The data of the article number `index`, always the same for the same arguments: what
`add_reference_data!` takes as `reference` and `experiments`. About 90 points.
"""
function article(index::Integer; seed::Integer = SEED, wrong::Real = 0.02)
    rng = Xoshiro(seed + index)
    reference = (
        doi = string("10.5555/synthetic-", lpad(index, 6, '0')),
        authors = ["Author, A.", "Writer, B."],
        title = string("Synthetic measurements number ", index),
        year = 1990 + index % 35,
    )
    return reference, experiments(rng, 3, Float64(wrong))
end

"""
    build(dir; scale = :medium, seed = SEED, name = "bench") -> NamedTuple

Create the database of the user `name` in `dir`, fill it with about `SCALES[scale]` measurements
and save it. Returns `(; db, compounds, path, articles, points)`.
"""
function build(
    dir::AbstractString;
    scale::Symbol = :medium,
    seed::Integer = SEED,
    name = "bench",
)
    target = SCALES[scale]
    articles = max(1, cld(target, POINTS_PER_REFERENCE))
    cdb = compound_database()
    db = T.Database([T.Member("seed"; kind = :user, dataset = T.Dataset())])
    T.add_database!(db, name; dir)
    points = 0
    for i = 1:articles
        reference, list = article(i; seed)
        result = T.add_reference_data!(
            db;
            reference,
            experiments = list,
            database = name,
            compounds = cdb,
            warn_duplicates = false,
        )
        points += result.points
    end
    T.save_database(db, name)
    member = only(m for m in T.members(db) if m.name == name)
    return (; db, compounds = cdb, path = member.path, articles, points)
end

end # module
