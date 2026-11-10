# Benchmarks of ThermophysicalDB.jl for AirspeedVelocity.jl (`benchpkg`).
#
# The data are synthetic (`synthetic.jl`) and the same for every revision, so a difference is a
# difference of the code. The size comes from `TDB_BENCH_SCALE` (`small`, `medium` by default, `full`)
# and the folder of the stored database from `TDB_BENCH_CACHE` (see `data.jl`).
#
# Groups: "load" (reading a database that exists), "add" (adding points), "filter" (the filters one
# after another and in one call, with and without a linked compound database), "units" (the same
# with the units packages), "template" (the spreadsheet) and "outliers". The allocations of every
# benchmark are the memory that AirspeedVelocity compares; the size of what stays in memory after
# loading is measured by `memory.jl`.
#
# A benchmark that cannot run on a revision (the function did not exist yet) is left out with a
# warning, so the same script can measure the latest release and a pull request.

using BenchmarkTools: BenchmarkTools, BenchmarkGroup, @benchmarkable
using ThermophysicalDB: ThermophysicalDB
using Unitful: Unitful
using DynamicQuantities: DynamicQuantities
using FlexUnits: FlexUnits
using Logging: Logging
using XLSX: XLSX
using ZipArchives: ZipArchives

include(joinpath(@__DIR__, "data.jl"))

const T = ThermophysicalDB
const SUITE = BenchmarkGroup()

# ----------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------

# `time` and `samples` of the benchmarks that start from a clean state each time.
const ONCE = (; evals = 1, samples = 10, seconds = 120)

function register!(group::BenchmarkGroup, name::AbstractString, bench)
    # Run once, so that a benchmark that does not work on this revision is left out and the
    # others are still measured.
    try
        BenchmarkTools.run(bench; samples = 1, evals = 1, seconds = 600)
        group[name] = bench
    catch err
        err isa InterruptException && rethrow()
        @warn "Benchmark left out" name reason = sprint(showerror, err)
    end
    return nothing
end

# The import warns about what the example files hold that is not stored yet; the log is not the
# subject of the benchmark.
quietly(f) = Logging.with_logger(f, Logging.NullLogger())

open_database(path::AbstractString) =
    T.Database([T.Member(BENCH_MEMBER; kind = :user, path = String(path))])

# A copy of the stored file in a folder of its own, for the benchmarks that write.
function copy_database(path::AbstractString)
    dir = mktempdir()
    target = joinpath(dir, BENCH_MEMBER)
    mkpath(target)
    cp(path, joinpath(target, basename(path)))
    return joinpath(target, basename(path))
end

# ----------------------------------------------------------------------------------
# Data
# ----------------------------------------------------------------------------------

const PREPARED = prepared_database(T)
const PATH = PREPARED.path
const COMPOUNDS = Synthetic.compound_database()
@info "Synthetic database" scale = bench_scale() path = PATH built = PREPARED.built seconds =
    PREPARED.seconds size_MB = round(filesize(PATH) / 1e6; digits = 1)

const DB = open_database(PATH)
const LINKED = T.link_compounds(DB, COMPOUNDS)

# A compound and a property that have points in the ranges of the filters, found once.
const TEMPERATURE = (300.0, 400.0)
const PRESSURE = (100.0, 30000.0)

function chosen_filters()
    for i = 1:Synthetic.COMPOUND_COUNT, (label,) in Synthetic.PROPERTIES
        try
            v = T.points(
                DB;
                component = Synthetic.inchikey(i),
                property = label,
                temperature = TEMPERATURE,
                pressure = PRESSURE,
            )
            length(v) >= 30 &&
                return (; key = Synthetic.inchikey(i), index = i, property = label)
        catch err
            err isa ArgumentError || rethrow()
        end
    end
    error("the synthetic database has no compound with points in the ranges of the filters")
end

const CHOSEN = chosen_filters()
const KEY = CHOSEN.key
const NAME = string("synthetic compound ", CHOSEN.index)  # a synonym: found through the linked database
const PROPERTY = CHOSEN.property

# ----------------------------------------------------------------------------------
# load: a database that exists
# ----------------------------------------------------------------------------------

load = SUITE["load"] = BenchmarkGroup()
register!(
    load,
    "open_database",
    @benchmarkable(
        T.Database([member]),
        setup = (member = T.Member(BENCH_MEMBER; kind = :user, path = $PATH)),
        evals = 1,
        samples = 10,
    ),
)
register!(
    load,
    "member_dataset",
    @benchmarkable(
        T.member_dataset(member),
        setup = (member = T.Member(BENCH_MEMBER; kind = :user, path = $PATH)),
        evals = 1,
        samples = 10,
    ),
)
register!(
    load,
    "open_and_first_query",
    @benchmarkable(
        T.points(db; component = $KEY),
        setup = (db = open_database($PATH)),
        evals = 1,
        samples = 10,
    ),
)
register!(
    load,
    "link_compounds",
    @benchmarkable(
        T.link_compounds(db, $COMPOUNDS),
        setup = (db = open_database($PATH); T.member_dataset(db, BENCH_MEMBER)),
        evals = 1,
        samples = 10,
    ),
)

# ----------------------------------------------------------------------------------
# add: new points in the database of the user
# ----------------------------------------------------------------------------------

add = SUITE["add"] = BenchmarkGroup()

# The article number `index` of the generator, as `add_reference_data!` takes it.
function add_article!(db, index)
    reference, list = Synthetic.article(index)
    return T.add_reference_data!(
        db;
        reference,
        experiments = list,
        database = BENCH_MEMBER,
        compounds = COMPOUNDS,
        warn_duplicates = false,
    )
end

function empty_database()
    db = T.Database([T.Member("seed"; kind = :user, dataset = T.Dataset())])
    T.add_database!(db, BENCH_MEMBER; dir = mktempdir())
    return db
end

# Number of an article that the stored database does not have.
const NEW_ARTICLE = 10_000_000

register!(
    add,
    "article_90_points_empty_database",
    @benchmarkable(
        add_article!(db, 1),
        setup = (db = empty_database()),
        evals = 1,
        samples = 10,
    ),
)
register!(
    add,
    "article_90_points_large_database",
    @benchmarkable(
        add_article!(db, $NEW_ARTICLE),
        setup = (db = open_database(copy_database($PATH))),
        evals = 1,
        samples = 10,
    ),
)
register!(
    add,
    "ten_articles_empty_database",
    @benchmarkable(
        for i = 1:10
            add_article!(db, i)
        end,
        setup = (db = empty_database()),
        evals = 1,
        samples = 10,
    ),
)
register!(
    add,
    "article_90_points_large_database_with_duplicate_check",
    @benchmarkable(
        T.add_reference_data!(
            db;
            reference,
            experiments,
            database = BENCH_MEMBER,
            compounds = $COMPOUNDS,
        ),
        setup = (
            db = open_database(copy_database($PATH));
            (reference, experiments) = Synthetic.article($NEW_ARTICLE)
        ),
        evals = 1,
        samples = 10,
    ),
)

# One point at a time, with the functions of the experiment.
function add_pointwise!(db)
    reference = T.add_reference!(db; database = BENCH_MEMBER, doi = "10.5555/pointwise-1")
    experiment = T.add_experiment!(reference; components = [KEY], compounds = COMPOUNDS)
    for k = 1:100
        T.add_measurement!(
            experiment;
            property = PROPERTY,
            unit = "kg/m3",
            value = 700.0 + k,
            temperature = 280.0 + k,
            pressure = 101.325,
        )
    end
    return nothing
end
register!(
    add,
    "pointwise_100_points",
    @benchmarkable(
        add_pointwise!(db),
        setup = (db = empty_database()),
        evals = 1,
        samples = 10
    ),
)

# ----------------------------------------------------------------------------------
# filter: one after another, and everything in one call
# ----------------------------------------------------------------------------------

# The same ways to ask for the same points over a database (`source`): the four stages of the
# cascade measured alone (each starts from the result of the one before), the four stages chained,
# and the four filters in one call. They find the same points, so the difference between the chain
# and the single call is the cost of the way of asking.
stage1(source, component) = T.points(source; component)
stage1(source::T.LinkedDatabase, component) = T.points(source; component, choose = :error)
stage2(view) = T.points(view; property = PROPERTY)
stage3(view) = T.points(view; temperature = TEMPERATURE)
stage4(view) = T.points(view; pressure = PRESSURE)
cascade(source, component) = stage4(stage3(stage2(stage1(source, component))))
single(source, component) = T.points(
    source;
    component,
    property = PROPERTY,
    temperature = TEMPERATURE,
    pressure = PRESSURE,
)
single(source::T.LinkedDatabase, component) = T.points(
    source;
    component,
    property = PROPERTY,
    temperature = TEMPERATURE,
    pressure = PRESSURE,
    choose = :error,
)

function filter_group!(group, source, component)
    register!(
        group,
        "1_component",
        @benchmarkable(stage1($source, $component), evals = 1, samples = 20),
    )
    register!(
        group,
        "2_property_after_component",
        @benchmarkable(
            stage2(v),
            setup = (v = stage1($source, $component)),
            evals = 1,
            samples = 20,
        ),
    )
    register!(
        group,
        "3_temperature_after_property",
        @benchmarkable(
            stage3(v),
            setup = (v = stage2(stage1($source, $component))),
            evals = 1,
            samples = 20,
        ),
    )
    register!(
        group,
        "4_pressure_after_temperature",
        @benchmarkable(
            stage4(v),
            setup = (v = stage3(stage2(stage1($source, $component)))),
            evals = 1,
            samples = 20,
        ),
    )
    register!(
        group,
        "cascade_4_calls",
        @benchmarkable(cascade($source, $component), evals = 1, samples = 20),
    )
    register!(
        group,
        "single_call_4_filters",
        @benchmarkable(single($source, $component), evals = 1, samples = 20),
    )
    return nothing
end

filters = SUITE["filter"] = BenchmarkGroup()
filters["database"] = BenchmarkGroup()
filters["linked_by_name"] = BenchmarkGroup()
filter_group!(filters["database"], DB, KEY)
filter_group!(filters["linked_by_name"], LINKED, NAME)

# ----------------------------------------------------------------------------------
# units: the same operations with the units packages
# ----------------------------------------------------------------------------------

# The package, a quantity in K (a number of kelvin) and the module that `table` is told to use.
const BACKENDS = (
    unitful = (module_ = Unitful, kelvin = x -> x * Unitful.uparse("K")),
    dynamicquantities = (
        module_ = DynamicQuantities,
        kelvin = x -> x * DynamicQuantities.uparse("K"),
    ),
    flexunits = (module_ = FlexUnits, kelvin = x -> x * FlexUnits.UnitRegistry.uparse("K")),
)

SUITE["units"] = BenchmarkGroup()

# All the points of one property: tens of thousands of rows, so that the conversion is visible.
const WHOLE_PROPERTY = T.points(DB; property = PROPERTY)

units_plain = SUITE["units"]["plain_numbers"] = BenchmarkGroup()
register!(
    units_plain,
    "table_native",
    @benchmarkable(T.table($WHOLE_PROPERTY), evals = 1, samples = 10),
)
register!(
    units_plain,
    "table_si",
    @benchmarkable(T.table($WHOLE_PROPERTY; units = :si), evals = 1, samples = 10),
)
register!(
    units_plain,
    "table_temperature_degC_pressure_bar",
    @benchmarkable(
        T.table($WHOLE_PROPERTY; temperature_unit = "degC", pressure_unit = "bar"),
        evals = 1,
        samples = 10,
    ),
)
register!(
    units_plain,
    "points_temperature_limits",
    @benchmarkable(
        T.points(DB; component = KEY, property = PROPERTY, temperature = $TEMPERATURE),
        evals = 1,
        samples = 20,
    ),
)

for (name, backend) in pairs(BACKENDS)
    group = SUITE["units"][String(name)] = BenchmarkGroup()
    limits = (backend.kelvin(TEMPERATURE[1]), backend.kelvin(TEMPERATURE[2]))
    register!(
        group,
        "table_quantities",
        @benchmarkable(
            T.table($WHOLE_PROPERTY; quantities = $(backend.module_)),
            evals = 1,
            samples = 10,
        ),
    )
    register!(
        group,
        "points_quantity_limits",
        @benchmarkable(
            T.points(DB; component = KEY, property = PROPERTY, temperature = $limits),
            evals = 1,
            samples = 20,
        ),
    )
end

# ----------------------------------------------------------------------------------
# template: the spreadsheet
# ----------------------------------------------------------------------------------

template = SUITE["template"] = BenchmarkGroup()
register!(
    template,
    "export_template_2_experiments",
    @benchmarkable(
        T.export_template(DB, joinpath(dir, "template.xlsx"); experiments = 2),
        setup = (dir = mktempdir()),
        evals = 1,
        samples = 5,
    ),
)
register!(
    template,
    "export_template_20_experiments",
    @benchmarkable(
        T.export_template(DB, joinpath(dir, "template.xlsx"); experiments = 20),
        setup = (dir = mktempdir()),
        evals = 1,
        samples = 5,
    ),
)

# The two example files of the documentation: read and checked, nothing is added.
const ASSETS = joinpath(pkgdir(T), "docs", "src", "assets")
for file in ("example-literature.xlsx", "example-own-measurements.xlsx")
    path = joinpath(ASSETS, file)
    isfile(path) || (@warn "Example file not found, benchmark left out" path; continue)
    register!(
        template,
        string("import_check_", replace(splitext(file)[1], "-" => "_")),
        @benchmarkable(
            quietly(() -> T.import_template($DB, $path; only_check = true)),
            evals = 1,
            samples = 5,
        ),
    )
end

# ----------------------------------------------------------------------------------
# outliers: a standard set of points
# ----------------------------------------------------------------------------------

# The points of one property of pure compounds: the same set in every revision.
const OUTLIER_SET = T.points(DB; property = PROPERTY, pure = true)

outliers = SUITE["outliers"] = BenchmarkGroup()
register!(
    outliers,
    "find_outliers_default",
    @benchmarkable(T.find_outliers($OUTLIER_SET), evals = 1, samples = 3, seconds = 600),
)
register!(
    outliers,
    "find_outliers_physical_only",
    @benchmarkable(
        T.find_outliers($OUTLIER_SET; trend = false, joint = false),
        evals = 1,
        samples = 5,
    ),
)
