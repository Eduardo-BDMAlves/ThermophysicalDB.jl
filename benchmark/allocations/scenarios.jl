# What is measured. One `scenario!` per call of the package on prepared data; to cover a new
# feature, add its scenarios here (`setup` builds the state outside the measurement, `run` is
# measured, `fingerprint` reduces the result to what must not change). A scenario that fails on the
# data (a function that does not exist yet, an option the data cannot satisfy) is reported as left
# out and the others go on.

using .AllocStudy: AllocStudy, scenario!
using DynamicQuantities: DynamicQuantities
using FlexUnits: FlexUnits
using Logging: Logging
using Tables: Tables
using Unitful: Unitful
using XLSX: XLSX
using ZipArchives: ZipArchives

# What of the types of the package goes into a fingerprint.
AllocStudy.canon(v::T.DataView) = v.rows
AllocStudy.canon(v::T.DatabaseView) = [p.rows for p in v.parts]
AllocStudy.canon(r::T.OutlierResult) =
    (r.kept.rows, r.outliers.rows, r.disputed.rows, r.category, r.counts)
append!(
    AllocStudy.SKIP_TYPES,
    (T.Dataset, T.Database, T.LinkedDatabase, T.CompoundDB, T.Member),
)

# The rows of a result, for the size that the allocated bytes are compared with.
rows_of(v::T.DataView) = v.rows
rows_of(v::T.DatabaseView) = reduce(vcat, (p.rows for p in v.parts); init = Int32[])

quietly(f) = Logging.with_logger(f, Logging.NullLogger())

# The files stamp the time of the export (`exported at`): two runs a second apart would differ, so
# the time is left out of the text that goes into the fingerprint.
mask_times(text::AbstractString) =
    replace(text, r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ" => "<time>")

# The text files of a directory, for the fingerprint of what an export writes (the binary formats
# hold the time they were written, so they are left out).
function directory_text(dir::AbstractString)
    found = Tuple{String,String}[]
    for (root, _, names) in walkdir(dir)    # `:thermoml_xml` writes a directory of documents
        for name in names
            (endswith(name, ".xlsx") || endswith(name, ".jld2")) && continue
            path = joinpath(root, name)
            push!(found, (relpath(path, dir), mask_times(read(path, String))))
        end
    end
    return sort!(found; by = first)
end

# ----------------------------------------------------------------------------------
# load: a database that exists (synthetic only: needs the stored file)
# ----------------------------------------------------------------------------------

open_member(ctx) = T.Member(BENCH_MEMBER; kind = :user, path = ctx.path)
open_database(ctx) = T.Database([open_member(ctx)])

scenario!(
    "load",
    "open_database";
    requires = :synthetic,
    setup = ctx -> open_member(ctx),
    run = member -> T.Database([member]),
    output = db -> db.members,
)
scenario!(
    "load",
    "member_dataset";
    requires = :synthetic,
    setup = ctx -> open_member(ctx),
    run = member -> T.member_dataset(member),
    fingerprint = ds ->
        (length(ds.measurements), length(ds.experiments), length(ds.references)),
    output = ds -> ds.measurements.value,
)
scenario!(
    "load",
    "open_and_first_query";
    requires = :synthetic,
    setup = ctx -> (db = open_database(ctx), key = ctx.key),
    run = st -> T.points(st.db; component = st.key),
    output = rows_of,
)
scenario!(
    "load",
    "link_compounds";
    requires = :synthetic,
    setup = ctx -> (
        db = open_database(ctx);
        T.member_dataset(db, BENCH_MEMBER);
        (; db, compounds = ctx.compounds)
    ),
    run = st -> T.link_compounds(st.db, st.compounds),
    fingerprint = l -> length(T.member_dataset(l.dataset.members[1]).measurements),
    output = l -> length(l.dataset.members),
)

# ----------------------------------------------------------------------------------
# add: new points in the database of the user (synthetic only: needs the generator)
# ----------------------------------------------------------------------------------

function copy_database(path::AbstractString)
    dir = mktempdir()
    target = joinpath(dir, BENCH_MEMBER)
    mkpath(target)
    cp(path, joinpath(target, basename(path)))
    return joinpath(target, basename(path))
end

# A database of the stored file, copied so that what is measured may write to it.
copied_database(ctx) =
    T.Database([T.Member(BENCH_MEMBER; kind = :user, path = copy_database(ctx.path))])

function empty_database()
    db = T.Database([T.Member("seed"; kind = :user, dataset = T.Dataset())])
    T.add_database!(db, BENCH_MEMBER; dir = mktempdir())
    return db
end

function add_article!(db, compounds, index; warn_duplicates = false)
    reference, list = Synthetic.article(index)
    return T.add_reference_data!(
        db;
        reference,
        experiments = list,
        database = BENCH_MEMBER,
        compounds,
        warn_duplicates,
    )
end

const NEW_ARTICLE = 10_000_000
added_points(result) = (result.points, result.experiments)

scenario!(
    "add",
    "article_90_points_empty_database";
    requires = :synthetic,
    setup = ctx -> (db = empty_database(), compounds = ctx.compounds),
    run = st -> add_article!(st.db, st.compounds, 1),
    fingerprint = r -> r.points,
)
scenario!(
    "add",
    "article_90_points_large_database";
    requires = :synthetic,
    setup = ctx -> (db = copied_database(ctx), compounds = ctx.compounds),
    run = st -> add_article!(st.db, st.compounds, NEW_ARTICLE),
    fingerprint = r -> r.points,
)
scenario!(
    "add",
    "article_90_points_large_database_duplicate_check";
    requires = :synthetic,
    setup = ctx -> (db = copied_database(ctx), compounds = ctx.compounds),
    run = st -> add_article!(st.db, st.compounds, NEW_ARTICLE; warn_duplicates = true),
    fingerprint = r -> r.points,
)
scenario!(
    "add",
    "ten_articles_empty_database";
    requires = :synthetic,
    setup = ctx -> (db = empty_database(), compounds = ctx.compounds),
    run = st -> [add_article!(st.db, st.compounds, i).points for i = 1:10],
)
scenario!(
    "add",
    "pointwise_100_points";
    requires = :synthetic,
    setup = ctx -> (
        db = empty_database(),
        compounds = ctx.compounds,
        key = ctx.key,
        property = ctx.property,
    ),
    run = st -> begin
        reference = T.add_reference!(
            st.db;
            database = BENCH_MEMBER,
            doi = "10.5555/pointwise-1",
        )
        experiment = T.add_experiment!(
            reference;
            components = [st.key],
            compounds = st.compounds,
        )
        for k = 1:100
            T.add_measurement!(
                experiment;
                property = st.property,
                unit = "kg/m3",
                value = 700.0 + k,
                temperature = 280.0 + k,
                pressure = 101.325,
            )
        end
        return length(T.member_dataset(st.db, BENCH_MEMBER).measurements)
    end,
)
scenario!(
    "add",
    "save_database_large";
    requires = :synthetic,
    setup = ctx -> begin
        db = copied_database(ctx)
        T.member_dataset(db, BENCH_MEMBER)
        db
    end,
    run = db -> (
        T.save_database(db, BENCH_MEMBER);
        filesize(only(m for m in T.members(db)).path) > 0
    ),
)

# ----------------------------------------------------------------------------------
# filter: one after another, and everything in one call
# ----------------------------------------------------------------------------------

stage1(source, component) = T.points(source; component)
stage1(source::T.LinkedDatabase, component) = T.points(source; component, choose = :error)
stage2(view, ctx) = T.points(view; property = ctx.property)
stage3(view, ctx) = T.points(view; temperature = ctx.temperature)
stage4(view, ctx) = T.points(view; pressure = ctx.pressure)
single(source, component, ctx) = T.points(
    source;
    component,
    property = ctx.property,
    temperature = ctx.temperature,
    pressure = ctx.pressure,
)
single(source::T.LinkedDatabase, component, ctx) = T.points(
    source;
    component,
    property = ctx.property,
    temperature = ctx.temperature,
    pressure = ctx.pressure,
    choose = :error,
)

function filter_scenarios!(group, source, component)
    s1(ctx) = stage1(source(ctx), component(ctx))
    s2(ctx) = stage2(s1(ctx), ctx)
    s3(ctx) = stage3(s2(ctx), ctx)
    scenario!(
        group,
        "1_component";
        setup = ctx -> (src = source(ctx), c = component(ctx)),
        run = st -> stage1(st.src, st.c),
        output = rows_of,
    )
    scenario!(
        group,
        "2_property_after_component";
        setup = ctx -> (v = s1(ctx), ctx = ctx),
        run = st -> stage2(st.v, st.ctx),
        output = rows_of,
    )
    scenario!(
        group,
        "3_temperature_after_property";
        setup = ctx -> (v = s2(ctx), ctx = ctx),
        run = st -> stage3(st.v, st.ctx),
        output = rows_of,
    )
    scenario!(
        group,
        "4_pressure_after_temperature";
        setup = ctx -> (v = s3(ctx), ctx = ctx),
        run = st -> stage4(st.v, st.ctx),
        output = rows_of,
    )
    scenario!(
        group,
        "cascade_4_calls";
        setup = ctx -> (src = source(ctx), c = component(ctx), ctx = ctx),
        run = st -> stage4(stage3(stage2(stage1(st.src, st.c), st.ctx), st.ctx), st.ctx),
        output = rows_of,
    )
    scenario!(
        group,
        "single_call_4_filters";
        setup = ctx -> (src = source(ctx), c = component(ctx), ctx = ctx),
        run = st -> single(st.src, st.c, st.ctx),
        output = rows_of,
    )
    return nothing
end

filter_scenarios!("filter/database", ctx -> ctx.db, ctx -> ctx.key)
filter_scenarios!("filter/linked_by_name", ctx -> ctx.linked, ctx -> ctx.name)

scenario!(
    "filter/other",
    "property_only_whole_database";
    setup = ctx -> (db = ctx.db, property = ctx.property),
    run = st -> T.points(st.db; property = st.property),
    output = rows_of,
)
scenario!(
    "filter/other",
    "property_only_keeping_repeated_points";
    setup = ctx -> (db = ctx.db, property = ctx.property),
    run = st -> T.points(st.db; property = st.property, duplicate = true),
    output = rows_of,
)
scenario!(
    "filter/other",
    "pure_compounds_of_property";
    setup = ctx -> (db = ctx.db, property = ctx.property),
    run = st -> T.points(st.db; property = st.property, pure = true),
    output = rows_of,
)
scenario!(
    "filter/other",
    "component_exact";
    setup = ctx -> (db = ctx.db, key = ctx.key),
    run = st -> T.points(st.db; component = st.key, exact = true),
    output = rows_of,
)
scenario!(
    "filter/other",
    "doi";
    setup = ctx -> (db = ctx.db, doi = ctx.doi),
    run = st -> T.points(st.db; doi = st.doi),
    output = rows_of,
)
scenario!(
    "filter/other",
    "author";
    setup = ctx -> (db = ctx.db, author = ctx.author),
    run = st -> T.points(st.db; author = st.author),
    output = rows_of,
)
scenario!(
    "filter/other",
    "year_range";
    setup = ctx -> (db = ctx.db, year = ctx.year),
    run = st -> T.points(st.db; year = st.year),
    output = rows_of,
)
scenario!(
    "filter/other",
    "mixture_binary_system";
    setup = ctx -> begin
        ctx.pair === nothing && error("the database has no binary system")
        (db = ctx.db, pair = ctx.pair)
    end,
    run = st -> T.mixture(st.db, st.pair...),
    output = rows_of,
)

# ----------------------------------------------------------------------------------
# units and tables: plain numbers, conversions and the units packages
# ----------------------------------------------------------------------------------

table_setup(ctx) = (view = ctx.whole,)

scenario!("tables", "table_native"; setup = table_setup, run = st -> T.table(st.view))
scenario!(
    "tables",
    "table_si";
    setup = table_setup,
    run = st -> T.table(st.view; units = :si),
)
scenario!(
    "tables",
    "table_temperature_degC_pressure_bar";
    setup = table_setup,
    run = st -> T.table(st.view; temperature_unit = "degC", pressure_unit = "bar"),
)
scenario!(
    "tables",
    "table_details";
    setup = table_setup,
    run = st -> T.table(st.view; details = true),
)
scenario!(
    "tables",
    "table_columntable_then_rows";
    setup = table_setup,
    run = st -> begin
        t = T.table(st.view)
        total = 0.0
        for row in Tables.rows(t)
            total += row.value
        end
        total
    end,
)
scenario!(
    "tables",
    "points_temperature_limits_plain";
    setup = ctx ->
        (db = ctx.db, key = ctx.key, property = ctx.property, limits = ctx.temperature),
    run = st -> T.points(
        st.db;
        component = st.key,
        property = st.property,
        temperature = st.limits,
    ),
    output = rows_of,
)

# The package, a quantity in K, and the module that `table` is told to use.
const BACKENDS = (
    unitful = (module_ = Unitful, kelvin = x -> x * Unitful.uparse("K")),
    dynamicquantities = (
        module_ = DynamicQuantities,
        kelvin = x -> x * DynamicQuantities.uparse("K"),
    ),
    flexunits = (module_ = FlexUnits, kelvin = x -> x * FlexUnits.UnitRegistry.uparse("K")),
)

for (name, backend) in pairs(BACKENDS)
    scenario!(
        string("units/", name),
        "table_quantities";
        setup = table_setup,
        run = st -> T.table(st.view; quantities = backend.module_),
    )
    scenario!(
        string("units/", name),
        "points_quantity_limits";
        setup = ctx -> (
            db = ctx.db,
            key = ctx.key,
            property = ctx.property,
            limits = (
                backend.kelvin(ctx.temperature[1]),
                backend.kelvin(ctx.temperature[2]),
            ),
        ),
        run = st -> T.points(
            st.db;
            component = st.key,
            property = st.property,
            temperature = st.limits,
        ),
        output = rows_of,
    )
end

scenario!(
    "composition",
    "convert_composition_10000_calls";
    setup = ctx -> nothing,
    run = _ -> begin
        total = 0.0
        for _ = 1:10_000
            x = T.convert_composition(
                [0.3, 0.7],
                :mole_fraction,
                :mass_fraction;
                molar_mass = [100.0, 50.0],
            )
            total += x[1]
        end
        total
    end,
)

# ----------------------------------------------------------------------------------
# duplicates, compounds and uncertainty
# ----------------------------------------------------------------------------------

scenario!(
    "duplicates",
    "duplicates_of_property";
    setup = ctx -> (view = T.points(ctx.db; property = ctx.property, duplicate = true),),
    run = st -> T.duplicates(st.view),
)
scenario!(
    "duplicates",
    "conflicts_of_property";
    setup = ctx -> (view = T.points(ctx.db; property = ctx.property, duplicate = true),),
    run = st -> T.conflicts(st.view),
)
scenario!(
    "compounds",
    "find_compounds_in_database";
    setup = ctx -> (db = ctx.db, text = ctx.key),
    run = st -> T.find_compounds(st.db, st.text),
)
scenario!(
    "compounds",
    "find_compounds_with_compound_database";
    setup = ctx -> (db = ctx.db, compounds = ctx.compounds, text = ctx.name),
    run = st -> T.find_compounds(st.db, st.compounds, st.text),
)
scenario!(
    "uncertainty",
    "expanded_uncertainty_k2";
    setup = ctx -> (view = first(ctx.whole.parts),),
    run = st -> T.expanded_uncertainty(st.view, :property),
)
scenario!(
    "uncertainty",
    "uncertainty_table";
    setup = ctx -> (ds = T.member_dataset(ctx.db.members[1]),),
    run = st -> T.uncertainty_table(st.ds),
)
scenario!(
    "uncertainty",
    "condition_table";
    setup = ctx -> (ds = T.member_dataset(ctx.db.members[1]),),
    run = st -> T.condition_table(st.ds),
)
scenario!(
    "uncertainty",
    "sample_table";
    setup = ctx -> (ds = T.member_dataset(ctx.db.members[1]),),
    run = st -> T.sample_table(st.ds),
)

# ----------------------------------------------------------------------------------
# exports
# ----------------------------------------------------------------------------------

export_view(ctx) = T.points(ctx.db; component = ctx.key, property = ctx.property)

# References are not written (`references = false`, DOI as the reference) and never fetched
# (`online = false`): the study must not depend on the network.
function export_to(st, format::Symbol)
    quietly() do
        T.export_points(
            st.dir,
            st.view;
            formats = (format,),
            references = false,
            reference = :doi,
            online = false,
        )
    end
    return st.dir
end

for format in (:csv, :md, :tex, :json, :jld2, :thermoml, :thermoml_xml, :xlsx)
    scenario!(
        "export",
        string("export_points_", format);
        setup = ctx -> (view = export_view(ctx), dir = joinpath(mktempdir(), "out")),
        run = st -> export_to(st, format),
        fingerprint = directory_text,
        repeats = 2,
    )
end
scenario!(
    "export",
    "reference_summary";
    setup = ctx -> (view = export_view(ctx),),
    run = st -> quietly(() -> T.reference_summary(st.view; online = false)),
    repeats = 2,
)

# ----------------------------------------------------------------------------------
# the spreadsheet template
# ----------------------------------------------------------------------------------

for count in (2, 20)
    scenario!(
        "template",
        string("export_template_", count, "_experiments");
        setup = ctx -> (db = ctx.db, dir = mktempdir()),
        run = st -> begin
            path = joinpath(st.dir, "template.xlsx")
            T.export_template(st.db, path; experiments = count)
            isfile(path)
        end,
        repeats = 2,
    )
end
for file in ("example-literature.xlsx", "example-own-measurements.xlsx")
    scenario!(
        "template",
        string("import_check_", replace(splitext(file)[1], "-" => "_"));
        setup = ctx -> begin
            path = joinpath(ctx.assets, file)
            isfile(path) || error("example file not found: $path")
            (db = ctx.db, path = path)
        end,
        run = st -> quietly(() -> T.import_template(st.db, st.path; only_check = true)),
        repeats = 2,
    )
end

# ----------------------------------------------------------------------------------
# outliers
# ----------------------------------------------------------------------------------

scenario!(
    "outliers",
    "find_outliers_default";
    setup = ctx -> (set = ctx.outlier_set,),
    run = st -> T.find_outliers(st.set),
    repeats = 2,
)
scenario!(
    "outliers",
    "find_outliers_physical_only";
    setup = ctx -> (set = ctx.outlier_set,),
    run = st -> T.find_outliers(st.set; trend = false, joint = false),
)
scenario!(
    "outliers",
    "find_outliers_trend_without_joint";
    setup = ctx -> (set = ctx.outlier_set,),
    run = st -> T.find_outliers(st.set; joint = false),
    repeats = 2,
)
