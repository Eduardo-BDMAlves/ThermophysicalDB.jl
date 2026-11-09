# Databases of the user: a member of a `Database` that starts empty, receives references,
# experiments and points, and is written to a file of its own only when the user asks. The ThermoML
# archive is never written: every function here refuses it. Nothing is guessed: a compound must come
# with an InChIKey or a CAS number (or a name that the compound database knows exactly), and a point
# that does not make sense (no value, a temperature that is not positive) is refused with a message.

const MEMBER_FORMAT = "thermophysicaldb-member"
const MEMBER_FILE = "dataset.jld2"
const MEMBER_META = "member.toml"
const MEMBER_NAME_REGEX = r"^[A-Za-z0-9][A-Za-z0-9_. -]*$"

"""
    databases_dir(; create = false) -> String

Directory where the databases of the user are saved, one folder for each (`<name>/dataset.jld2`
and `<name>/member.toml`). [`database`](@ref) opens every one that it finds there.
"""
databases_dir(; create::Bool = false) = subdir("databases", create)

# ----------------------------------------------------------------------------------
# Creating, saving and finding databases
# ----------------------------------------------------------------------------------

"""
    add_database!(db, name; kind = :user, priority = nothing, dir = databases_dir()) -> Member

Create an empty database of your own called `name` and add it to `db`. `kind` is `:user` (what you
measured) or `:literature` (points that you found in articles); `priority` decides which database
wins when [`points`](@ref) is asked for points that several hold (a smaller number first; by
default the archive comes first, then `:literature`, then `:user`). The database lives in memory
until [`save_database`](@ref) writes it to `dir`; then [`database`](@ref) opens it in every session.
`name` becomes a folder name: letters, digits, `_`, `-`, `.` and spaces.

```julia
db = database()
add_database!(db, "my_lab")
```
"""
function add_database!(
    db::Database,
    name::AbstractString;
    kind::Symbol = :user,
    priority::Union{Nothing,Integer} = nothing,
    dir::AbstractString = databases_dir(),
)
    name = String(strip(name))
    kind in (:literature, :user) || throw(
        ArgumentError(
            "a database of your own has kind :literature or :user, got :$kind; the archive is :thermoml and is never created here",
        ),
    )
    (occursin(MEMBER_NAME_REGEX, name) && length(name) <= 64) || throw(
        ArgumentError(
            "the name of a database is a folder name (letters, digits, _ - . and spaces, at most 64), got \"$name\"",
        ),
    )
    lowercase(name) == "thermoml" &&
        throw(ArgumentError("the name \"thermoml\" belongs to the archive"))
    any(m -> lowercase(m.name) == lowercase(name), db.members) &&
        throw(ArgumentError("there is already a database called \"$name\""))
    path = joinpath(dir, name, MEMBER_FILE)
    isfile(joinpath(dir, name, MEMBER_META)) && throw(
        ArgumentError(
            "a database called \"$name\" is saved in $(joinpath(dir, name)); open it with database() or choose another name",
        ),
    )
    member = Member(
        name;
        kind,
        path,
        dataset = Dataset(),
        priority = something(priority, DEFAULT_PRIORITY[kind]),
        persistent = false,
    )
    add_member!(db, member)
    return member
end

function write_member_meta(m::Member, n::Integer)
    meta = Dict{String,Any}(
        "format" => MEMBER_FORMAT,
        "schema_version" => SCHEMA_VERSION,
        "name" => m.name,
        "kind" => String(m.kind),
        "priority" => m.priority,
        "saved_at" => utc_timestamp(),
        "measurements" => Int(n),
    )
    path = joinpath(dirname(m.path), MEMBER_META)
    tmp = path * ".tmp"
    open(io -> TOML.print(io, meta), tmp, "w")
    mv(tmp, path; force = true)
    return path
end

function writable_member(db::Database, name::Union{Nothing,AbstractString})
    if name === nothing
        own = [m for m in db.members if m.kind !== :thermoml]
        isempty(own) && throw(
            ArgumentError(
                "there is no database of your own to receive the data; create one with add_database!(db, name)",
            ),
        )
        length(own) == 1 || throw(
            ArgumentError(
                "several databases can receive the data ($(join(repr.(m.name for m in own), ", "))); say which with database = \"name\"",
            ),
        )
        return only(own)
    end
    m = db.members[member_index(db, name)]
    m.kind === :thermoml && throw(
        ArgumentError(
            "the ThermoML archive is never changed; add the data to a database of your own (add_database!)",
        ),
    )
    return m
end

"""
    save_database(db, name) -> String

Write the database `name` to its folder (`<databases_dir()>/<name>`) and return the path of the
file. From then on [`database`](@ref) opens it in every session. The file is written whole, to a
temporary name first and then moved into place, so a failure never leaves a half-written database.
Nothing is saved unless you call this.
"""
function save_database(db::Database, name::AbstractString)
    m = writable_member(db, name)
    isempty(m.path) &&
        throw(ArgumentError("the database \"$(m.name)\" has no file to be saved to"))
    ds = member_dataset(m)
    mkpath(dirname(m.path))
    meta = joinpath(dirname(m.path), MEMBER_META)
    # An old description must not vouch for data that is being replaced.
    rm(meta; force = true)
    part = m.path * ".part"
    try
        JLD2.jldopen(part, "w") do file
            write_dataset((key, value) -> (file[key] = value; nothing), ds)
        end
        mv(part, m.path; force = true)
    finally
        rm(part; force = true)
    end
    m.persistent = true
    write_member_meta(m, length(ds.measurements))
    return m.path
end

"""
    set_priority!(db, name, priority) -> Database

Change the priority of a database (a smaller number comes first). The order decides which database
wins when points are repeated. A saved database keeps the new priority in its description file.
"""
function set_priority!(db::Database, name::AbstractString, priority::Integer)
    m = db.members[member_index(db, name)]
    m.priority = Int(priority)
    sort!(db.members; by = x -> x.priority)
    db.registry = build_registry(db.members)
    if m.persistent && isfile(joinpath(dirname(m.path), MEMBER_META))
        write_member_meta(m, is_open(m) ? length(m.dataset.measurements) : member_points(m))
    end
    return db
end

# The databases saved in `root`: a folder with a description and a data file. One that cannot be
# used (another schema version, a damaged file) is skipped with a warning, never an error.
function discover_members(root::AbstractString; taken = String[])
    found = Member[]
    isdir(root) || return found
    for entry in sort(readdir(root))
        dir = joinpath(root, entry)
        meta_path = joinpath(dir, MEMBER_META)
        data = joinpath(dir, MEMBER_FILE)
        (isdir(dir) && isfile(meta_path) && isfile(data)) || continue
        try
            meta = TOML.parsefile(meta_path)
            get(meta, "format", "") == MEMBER_FORMAT ||
                error("it is not a database of this package")
            version = get(meta, "schema_version", -1)
            version == SCHEMA_VERSION || error(
                "it was saved with schema version $version and this version of the package reads $SCHEMA_VERSION",
            )
            kind = Symbol(get(meta, "kind", "user"))
            kind in (:literature, :user) ||
                error("its kind :$kind is not a database of your own")
            name = String(get(meta, "name", entry))
            name in taken && error("there is already a database called \"$name\"")
            member = Member(
                name;
                kind,
                path = data,
                priority = Int(get(meta, "priority", DEFAULT_PRIORITY[kind])),
                persistent = true,
            )
            member_catalog(member)    # reads the file; fails here, not in the first query
            push!(found, member)
            push!(taken, name)
        catch err
            err isa InterruptException && rethrow()
            @warn "A saved database was skipped" folder = dir reason =
                sprint(showerror, err)
        end
    end
    return found
end

# ----------------------------------------------------------------------------------
# Compounds: an InChIKey, a CAS number, or a name that the compound database knows
# ----------------------------------------------------------------------------------

struct CompoundSpec
    inchikey::String
    cas::String
    names::Vector{String}
    formula::String
end

const COMPOUND_FIELDS = (:inchikey, :cas, :name, :names, :formula)

# The compound database used to recognise a CAS number or a name: the one given, else the one of
# the session, else (only when `needed`) the one of the package, which is downloaded once.
function compound_source(compounds, needed::Bool)
    compounds === nothing || return compounds
    memo = COMPOUND_MEMO[]
    memo === nothing || return memo[2]
    return needed ? compound_database(; progress = false) : nothing
end

function spec_fields(spec)
    if spec isa AbstractString
        text = String(strip(spec))
        kind = identifier_kind(text)
        kind === :inchikey && return (uppercase(text), "", String[], "")
        kind === :cas && return ("", normalize_cas(text), String[], "")
        kind === :name && return ("", "", [text], "")
        throw(
            ArgumentError(
                "\"$(first(text, 40))\" is an InChI or a SMILES; give the InChIKey, the CAS number or the name of the compound",
            ),
        )
    elseif spec isa NamedTuple || spec isa AbstractDict
        get_field(k) =
            spec isa NamedTuple ? get(spec, k, "") : get(spec, k, get(spec, String(k), ""))
        for k in keys(spec)
            Symbol(k) in COMPOUND_FIELDS || throw(
                ArgumentError(
                    "unknown field $(repr(k)) of a compound; the fields are $(join(COMPOUND_FIELDS, ", "))",
                ),
            )
        end
        names = String[]
        for k in (:name, :names)
            value = get_field(k)
            value isa AbstractString ?
            isempty(value) || push!(names, String(strip(value))) :
            append!(names, String.(strip.(value)))
        end
        inchikey = uppercase(String(strip(get_field(:inchikey))))
        cas = String(strip(get_field(:cas)))
        isempty(cas) || (cas = normalize_cas(cas))
        return (inchikey, cas, unique!(names), String(strip(get_field(:formula))))
    end
    throw(
        ArgumentError(
            "a compound is a name, a CAS number, an InChIKey or a (inchikey = ..., cas = ..., name = ...), got $(typeof(spec))",
        ),
    )
end

# What the compound database says about `text` when it is identified exactly (a name that only
# contains the text or resembles it does not count).
function exact_records(cdb::CompoundDB, text::AbstractString, by::Symbol)
    found = lookup_compounds(cdb, text; by, limit = 20)
    keep = [i for i in eachindex(found.id) if found.match[i] ∉ (:contains, :similar)]
    return (;
        (k => getfield(found, k)[keep] for k in (:name, :cas, :formula, :inchikey))...
    )
end

"""
    resolve_compound(spec; compounds = nothing) -> CompoundSpec

Identify the compound of an experiment of your own. `spec` is an InChIKey, a CAS number, a name, or
`(inchikey = ..., cas = ..., name = ..., formula = ...)`. The compound must be identified: a name
alone is accepted only when the compound database knows it exactly (the first call may download it
once). A CAS number the compound database does not know gives the key `cas:<number>`, which is
replaced by nothing automatically: if the InChIKey is learnt later, add the data again with it.
"""
function resolve_compound(spec; compounds = nothing)
    inchikey, cas, names, formula = spec_fields(spec)
    isempty(inchikey) ||
        occursin(INCHIKEY_REGEX, inchikey) ||
        throw(ArgumentError("\"$inchikey\" is not an InChIKey"))
    isempty(cas) ||
        occursin(CAS_REGEX, cas) ||
        throw(ArgumentError("\"$cas\" is not a CAS number (like 7732-18-5)"))
    if !isempty(inchikey)
        cdb = compound_source(compounds, false)
        if cdb !== nothing
            rec = exact_records(cdb, inchikey, :inchikey)
            for i in eachindex(rec.name)
                push!(names, rec.name[i])
                isempty(formula) && (formula = rec.formula[i])
            end
        end
        return CompoundSpec(inchikey, "", unique!(names), formula)
    end
    text, by = isempty(cas) ? (isempty(names) ? "" : first(names), :name) : (cas, :cas)
    isempty(text) && throw(
        ArgumentError(
            "a compound needs an InChIKey, a CAS number or a name that the compound database knows",
        ),
    )
    cdb = compound_source(compounds, true)
    rec = exact_records(cdb, text, by)
    found = unique(k for k in rec.inchikey if !isempty(k))
    length(found) > 1 && throw(
        ArgumentError(
            "\"$text\" is $(length(found)) different compounds ($(join(rec.name, ", "))); give the InChIKey",
        ),
    )
    if length(found) == 1
        i = findfirst(==(only(found)), rec.inchikey)
        push!(names, rec.name[i])
        isempty(formula) && (formula = rec.formula[i])
        return CompoundSpec(only(found), "", unique!(names), formula)
    end
    if isempty(cas) && !isempty(rec.cas)
        cas = first(c for c in rec.cas if !isempty(c))
    end
    isempty(cas) && throw(
        ArgumentError(
            "the compound database does not know \"$text\"; give its InChIKey or its CAS number",
        ),
    )
    # Known by CAS only: the number is the identity until an InChIKey is given.
    append!(names, rec.name)
    push!(names, cas)
    return CompoundSpec("", cas, unique!(names), formula)
end

function intern_compound!(ds::Dataset, c::CompoundSpec)
    return add_compound!(
        ds.compounds;
        inchikey = c.inchikey,
        cas = c.cas,
        formula = c.formula,
        names = c.names,
    )
end

# ----------------------------------------------------------------------------------
# References, experiments and points
# ----------------------------------------------------------------------------------

"""
    ReferenceRef

A reference of a database of your own, as returned by [`add_reference!`](@ref); it is what
[`add_experiment!`](@ref) is given.
"""
struct ReferenceRef
    database::Database
    member::Member
    id::Int32
end

"""
    ExperimentRef

An experiment of a database of your own, as returned by [`add_experiment!`](@ref); it is what
[`add_measurement!`](@ref) is given.
"""
struct ExperimentRef
    database::Database
    member::Member
    id::Int32
    reference::Int32
    ncomp::Int
end

function Base.show(io::IO, r::ReferenceRef)
    ds = member_dataset(r.member)
    doi = ds.references.doi[r.id]
    return print(
        io,
        "ReferenceRef(\"",
        r.member.name,
        "\", ",
        isempty(doi) ? "#$(r.id)" : doi,
        ")",
    )
end

function Base.show(io::IO, e::ExperimentRef)
    return print(io, "ExperimentRef(\"", e.member.name, "\", experiment ", e.id, ")")
end

function normalize_doi(text::AbstractString)
    s = strip(String(text))
    s = replace(s, r"^(?i:https?://(?:dx\.)?doi\.org/|doi:\s*)" => "")
    return String(strip(s))
end

catalog_size(ds::Dataset) =
    (length(ds.compounds), length(ds.properties), length(ds.references))

# The catalog of a member that changed is read again and the registry built again, so the new
# compounds, properties and references can be found (and the member is not left out of a query).
function refresh!(db::Database, m::Member)
    m.catalog = nothing
    db.registry = build_registry(db.members)
    return db
end

const REFERENCE_FIELDS = (:doi, :title, :journal, :year, :volume, :pages, :authors)

function reference_fields(;
    doi = "",
    title = "",
    journal = "",
    year = 0,
    volume = "",
    pages = "",
    authors = String[],
)
    authors = authors isa AbstractString ? String[authors] : String.(collect(authors))
    doi = normalize_doi(doi)
    (isempty(doi) && isempty(authors) && isempty(strip(title))) && throw(
        ArgumentError(
            "a reference needs a DOI, authors or a title, so that the points can be credited",
        ),
    )
    (year == 0 || 1500 <= year <= 2200) || throw(
        ArgumentError("the year of a reference must be between 1500 and 2200, got $year"),
    )
    return (;
        doi,
        title = String(strip(title)),
        journal = String(strip(journal)),
        year = Int(year),
        volume = String(volume),
        pages = String(pages),
        authors,
    )
end

"""
    add_reference!(db; database = nothing, doi, title, journal, year, volume, pages, authors)
        -> ReferenceRef

Add the article (or report, or thesis) that the points come from, to the database of your own
`database` (the only one when there is one). One of `doi`, `authors` or `title` is needed. A DOI
that is already there gives the same reference again. The reference is what
[`add_experiment!`](@ref) is given; an experiment is only part of what an article measured, so a
reference can have as many as the article has.
"""
function add_reference!(db::Database; database = nothing, kwargs...)
    unknown = [k for k in keys(kwargs) if k ∉ REFERENCE_FIELDS]
    isempty(unknown) || throw(
        ArgumentError(
            "unknown keyword $(first(unknown)); the fields of a reference are $(join(REFERENCE_FIELDS, ", "))",
        ),
    )
    m = writable_member(db, database)
    fields = reference_fields(; kwargs...)
    return commit_reference!(db, m, fields)
end

function commit_reference!(db::Database, m::Member, fields)
    ds = member_dataset(m)
    before = catalog_size(ds)
    id = add_reference!(ds.references; fields..., source = intern!(ds.sources, m.name))
    catalog_size(ds) == before || refresh!(db, m)
    return ReferenceRef(db, m, id)
end

function find_reference(db::Database, m::Member, reference)
    reference isa ReferenceRef && return reference
    if reference isa AbstractString
        ds = member_dataset(m)
        id = get(ds.references.index, normalize_doi(reference), NO_ID)
        id == NO_ID && throw(
            ArgumentError(
                "the database \"$(m.name)\" has no reference with the DOI \"$reference\"; add it with add_reference!",
            ),
        )
        return ReferenceRef(db, m, id)
    end
    throw(
        ArgumentError(
            "a reference is the result of add_reference! or a DOI that is already in the database, got $(typeof(reference))",
        ),
    )
end

function check_scales(scale, ncomp::Integer)
    ncomp == 1 && scale === nothing && return Symbol[]
    scales =
        scale === nothing ? fill(:mole_fraction, ncomp) :
        scale isa Symbol ? fill(scale, ncomp) : Symbol.(collect(scale))
    length(scales) == ncomp || throw(
        ArgumentError(
            "composition_scale gives $(length(scales)) scales for $ncomp components",
        ),
    )
    for s in scales
        s in COMPOSITION_SCALES || throw(
            ArgumentError(
                "composition_scale must be one of $(COMPOSITION_SCALES), got :$s",
            ),
        )
    end
    return scales
end

function check_components(components, compounds)
    list =
        components isa AbstractString || components isa NamedTuple ? [components] :
        collect(components)
    isempty(list) && throw(ArgumentError("an experiment needs at least one component"))
    length(list) <= MAX_COMPONENTS || throw(
        ArgumentError("systems with more than $MAX_COMPONENTS components are unsupported"),
    )
    return [resolve_compound(c; compounds) for c in list]
end

function commit_experiment!(
    ref::ReferenceRef,
    specs::Vector{CompoundSpec},
    scales::Vector{Symbol};
    purpose = "",
    number::Integer = 0,
)
    ds = member_dataset(ref.member)
    before = catalog_size(ds)
    ids = Int32[intern_compound!(ds, c) for c in specs]
    id = add_experiment!(
        ds.experiments;
        reference = ref.id,
        components = ids,
        kinds = Int32[intern!(ds.kinds, SCALE_KINDS[s]) for s in scales],
        source = intern!(ds.sources, ref.member.name),
        number,
        purpose = intern!(ds.purposes, String(purpose)),
    )
    catalog_size(ds) == before || refresh!(ref.database, ref.member)
    return ExperimentRef(ref.database, ref.member, id, ref.id, length(specs))
end

"""
    add_experiment!(ref; components, composition_scale = nothing, purpose = "", number = 0,
                    compounds = nothing) -> ExperimentRef
    add_experiment!(db; reference, database = nothing, components, ...) -> ExperimentRef

Add an experiment to a reference of a database of your own: a set of points of one system, that is
of one list of `components` (up to $(MAX_COMPONENTS)). A component is an InChIKey, a CAS number, a
name that the compound database knows exactly, or `(inchikey = ..., cas = ..., name = ...)`, see
[`resolve_compound`](@ref). `compounds` is a `CompoundDB` to look them up in (by default the one of
the package). `composition_scale` is one of [`COMPOSITION_SCALES`](@ref) for all components, or one
for each; the default is `:mole_fraction` for a mixture, and a pure compound has no composition.
`reference` of the second form is the result of [`add_reference!`](@ref) or a DOI already in the
database.

```julia
ref = add_reference!(db; doi = "10.1000/example", authors = ["Silva, A."], year = 2024)
exp = add_experiment!(ref; components = ["water", "7647-14-5"], composition_scale = :molality)
```
"""
function add_experiment!(
    ref::ReferenceRef;
    components,
    composition_scale = nothing,
    purpose::AbstractString = "",
    number::Integer = 0,
    compounds = nothing,
)
    specs = check_components(components, compounds)
    scales = check_scales(composition_scale, length(specs))
    return commit_experiment!(ref, specs, scales; purpose, number)
end

function add_experiment!(db::Database; reference, database = nothing, kwargs...)
    m = reference isa ReferenceRef ? reference.member : writable_member(db, database)
    return add_experiment!(find_reference(db, m, reference); kwargs...)
end

# The unit a property is stored in. A point is the same property as another when label and unit
# are the same text, so the unit of a point is the one the databases already use for that label (of
# the same dimension); a property that no database has is stored in SI. The choice is remembered, so
# the points of one call agree even before the first of them is in a database.
struct UnitChoices
    database::Database
    memo::Dict{Tuple{String,DimVector},String}
end
UnitChoices(db::Database) = UnitChoices(db, Dict{Tuple{String,DimVector},String}())

function known_unit(db::Database, label::AbstractString, dim::DimVector)
    ids = get(db.registry.label_index, lowercase(strip(label)), nothing)
    ids === nothing && return nothing
    for g in ids
        text = db.registry.property_keys[g][2]
        unit = isempty(text) ? nothing : readable_unit(text)
        unit !== nothing && unit.dim == dim && return text
    end
    return nothing
end

# The units that the databases use for a label (any dimension).
function known_units(db::Database, label::AbstractString)
    ids = get(db.registry.label_index, lowercase(strip(label)), nothing)
    ids === nothing && return String[]
    return unique!(
        String[
            db.registry.property_keys[g][2] for
            g in ids if !isempty(db.registry.property_keys[g][2])
        ],
    )
end

# `source` is a unit text that the exact parser reads; the result is the text of the stored unit.
function stored_unit(c::UnitChoices, label::AbstractString, source::AbstractString)
    parsed = parse_exact_unit(source)
    dim = parsed.dim
    return get!(c.memo, (lowercase(strip(label)), dim)) do
        known = known_unit(c.database, label, dim)
        known !== nothing && return String(known)
        other = known_units(c.database, label)
        isempty(other) || throw(
            ArgumentError(
                "\"$(strip(label))\" is in $(join(other, ", ")) in the databases, which is not " *
                "a unit of the same quantity as \"$source\"",
            ),
        )
        isone(parsed.scale) && return String(strip(source))
        return si_unit_text(dim)
    end
end

# The unit that a value written as a text or a quantity carries, or `nothing`.
carried_unit(::Real) = nothing
function carried_unit(x::AbstractString)
    text = split_number_unit(x)[2]
    return isempty(text) || haskey(RELATIVE_UNITS, text) ? nothing : text
end
function carried_unit(x)
    parts = quantity_parts(backend_of(x), x)
    return parts === nothing ? nothing : parts[2]
end

# One number of a point in the stored unit `spec`. `declared` is the unit of a plain number.
function property_number(x, spec::UnitSpec, declared, difference::Bool, reference::Float64)
    affine(text) = begin
        a = quantity_affine(spec, text)
        a === nothing && throw(ArgumentError("cannot read \"$text\" as a unit"))
        difference ? difference_of(a) : a
    end
    plain(number) =
        declared === nothing || declared == spec.native ? Float64(number) :
        apply_exact(affine(declared), number)
    x isa Real && return plain(x)
    if x isa AbstractString
        number, text = split_number_unit(x)
        isempty(text) && return plain(number)
        fraction = get(RELATIVE_UNITS, text, nothing)
        if fraction !== nothing
            difference || throw(ArgumentError("a value cannot be given as a percentage"))
            isfinite(reference) ||
                throw(ArgumentError("a percentage needs the value of the point"))
            return number * fraction * abs(reference)
        end
        return apply_exact(affine(text), number)
    end
    return difference ? native_difference(x, spec) : native_value(x, spec)
end

# The temperature, pressure, value and uncertainty of a point as they are stored: `Float64` in K,
# kPa and the unit of the property, which is returned as text.
function convert_point(c::UnitChoices, property, unit, value, temperature, pressure, unc)
    t = input_named("the temperature", temperature, NativeTemperature(), false)
    p = input_named("the pressure", pressure, NativePressure(), false)
    (property isa AbstractString && unit isa AbstractString) ||
        return (; unit, value, t, p, unc)
    declared = strip(unit)
    readable = isempty(declared) ? nothing : readable_unit(declared)
    carried = carried_unit(value)
    source = readable !== nothing ? declared : carried
    if source === nothing
        # No unit that can be converted: as written, as before.
        carried === nothing || throw(ArgumentError("cannot read \"$carried\" as a unit"))
        return (; unit = String(declared), value, t, p, unc)
    end
    stored = try
        stored_unit(c, property, source)
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("the unit of the value: $(err.msg)"))
    end
    spec = UnitSpec(stored, stored, stored)
    given = readable !== nothing ? String(declared) : nothing
    v = try
        property_number(value, spec, given, false, NaN)
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("the value: $(err.msg)"))
    end
    u = try
        unc isa Real && isnan(unc) ? Float64(unc) : property_number(unc, spec, given, true, v)
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("the uncertainty: $(err.msg)"))
    end
    return (; unit = stored, value = v, t, p, unc = u)
end

# Everything about one point that can be wrong, checked before anything is added.
function check_point(
    ncomp::Integer,
    property,
    value,
    temperature,
    pressure,
    composition,
    unc,
    unc_k,
    unc_level,
)
    (property isa AbstractString && !isempty(strip(property))) || throw(
        ArgumentError("a point needs the name of its property, like \"Mass density\""),
    )
    (value isa Real && isfinite(value)) || throw(
        ArgumentError("the value of a point must be a finite number, got $(repr(value))"),
    )
    (temperature isa Real && (isnan(temperature) || temperature > 0)) || throw(
        ArgumentError(
            "the temperature is in K and must be positive (NaN when not given), got $(repr(temperature))",
        ),
    )
    (pressure isa Real && (isnan(pressure) || pressure >= 0)) || throw(
        ArgumentError(
            "the pressure is in kPa and must not be negative (NaN when not given), got $(repr(pressure))",
        ),
    )
    (unc isa Real && (isnan(unc) || unc >= 0)) ||
        throw(ArgumentError("an uncertainty must not be negative, got $(repr(unc))"))
    (unc_k isa Real && (isnan(unc_k) || unc_k > 0)) ||
        throw(ArgumentError("a coverage factor must be positive, got $(repr(unc_k))"))
    (unc_level isa Real && (isnan(unc_level) || 0 < unc_level < 1)) || throw(
        ArgumentError(
            "a level of confidence is a fraction between 0 and 1, got $(repr(unc_level))",
        ),
    )
    amounts = composition isa Real ? [composition] : collect(composition)
    length(amounts) <= ncomp || throw(
        ArgumentError("$(length(amounts)) amounts for an experiment of $ncomp components"),
    )
    all(a -> a isa Real, amounts) || throw(ArgumentError("the composition must be numbers"))
    all(a -> isnan(a) || a >= 0, amounts) ||
        throw(ArgumentError("an amount of a component must not be negative"))
    return ntuple(i -> i <= length(amounts) ? Float64(amounts[i]) : NaN, MAX_COMPONENTS)
end

# ----------------------------------------------------------------------------------
# Uncertainties of the temperature, the pressure and the amounts of a point
# ----------------------------------------------------------------------------------

# Nothing was given for this uncertainty.
input_missing(x) = x === nothing || x === missing || (x isa Real && isnan(x))

# One uncertainty of an input of the point as a term in the native unit of the quantity (K, kPa,
# the amount as stored). A plain number is a standard uncertainty (k = 1), as everywhere a term is
# expected; an `UncertaintyTerm` states its own coverage. A text with a unit is a difference; a
# percentage is a fraction of `reference`, the value as stored: of the temperature in K and of the
# pressure in kPa, so a percentage of a temperature in degC or degF is always taken of the
# absolute scale (K, and so also Ra for degF).
function input_term(x, kind, reference::Real, quantity::Symbol, what::AbstractString)
    isfinite(reference) || throw(
        ArgumentError(
            "the uncertainty of $what is given but $what is not: give the value or leave the uncertainty out",
        ),
    )
    ctx = (;
        kind,
        reference = Float64(reference),
        where = "the point",
        why = "the amounts have no unit that can be given; use a number or a percentage",
        relative_why = "",
    )
    try
        return x isa UncertaintyTerm ? resolve_term(x, ctx, quantity) :
               UncertaintyTerm(uncertainty_native(x, ctx, quantity); k = 1.0)
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("the uncertainty of $what: $(err.msg)"))
    end
end

# The terms of a point, checked: `(quantity, term)` for every uncertainty that was given.
# `u_composition` is one entry for each amount (a scalar stands for every amount that is given).
function input_uncertainties(
    ncomp::Integer,
    t,
    p,
    comp,
    u_temperature,
    u_pressure,
    u_composition,
)
    terms = Tuple{Symbol,UncertaintyTerm{Float64}}[]
    if !input_missing(u_temperature)
        push!(
            terms,
            (
                :temperature,
                input_term(
                    u_temperature,
                    NativeTemperature(),
                    t,
                    :temperature,
                    "the temperature",
                ),
            ),
        )
    end
    if !input_missing(u_pressure)
        push!(
            terms,
            (
                :pressure,
                input_term(u_pressure, NativePressure(), p, :pressure, "the pressure"),
            ),
        )
    end
    list =
        u_composition isa Union{AbstractVector,Tuple} ? collect(u_composition) :
        fill(u_composition, ncomp)
    length(list) <= ncomp || throw(
        ArgumentError(
            "$(length(list)) uncertainties of the composition for $ncomp component(s)",
        ),
    )
    for (j, x) in enumerate(list)
        input_missing(x) && continue
        (j <= length(comp) && isfinite(comp[j])) || begin
            u_composition isa Union{AbstractVector,Tuple} && throw(
                ArgumentError(
                    "the uncertainty of the amount of component $j is given but the amount is not",
                ),
            )
            continue
        end
        q = Symbol("composition", j)
        push!(terms, (q, input_term(x, nothing, comp[j], q, "the amount of component $j")))
    end
    return terms
end

# The terms are stored as the expanded uncertainty with its coverage, and the combined standard
# uncertainty that follows from it (``u = U / k``), as `set_uncertainty!` does for an expanded term,
# without its search for shared terms (these are the user's own points, one call for each point).
function store_input_uncertainties!(ds::Dataset, row::Integer, terms)
    isempty(terms) && return nothing
    method = intern!(ds.unc_methods, DERIVED_FROM_EXPANDED_TEXT)
    for (quantity, term) in terms
        add_uncertainty!(
            ds.uncertainties;
            scope = :measurement,
            row,
            quantity,
            kind = :expanded,
            value = term.value,
            k = term.k,
            level = term.level,
        )
        add_uncertainty!(
            ds.uncertainties;
            scope = :measurement,
            row,
            quantity,
            kind = :combined,
            value = term.value / term.k,
            k = 1.0,
            level = level_of_coverage(1.0),
            method,
            origin = :derived,
        )
    end
    return nothing
end

function commit_point!(
    e::ExperimentRef,
    property::AbstractString,
    unit::AbstractString,
    group::AbstractString,
    method::AbstractString,
    phase::AbstractString,
    value,
    temperature,
    pressure,
    composition,
    unc,
    unc_k,
    unc_level,
    terms = (),
)
    ds = member_dataset(e.member)
    before = length(ds.properties)
    prop = add_property!(
        ds.properties,
        strip(property),
        strip(unit);
        group = intern!(ds.groups, String(group)),
    )
    row = add_measurement!(
        ds.measurements;
        experiment = e.id,
        property = prop,
        value,
        method = intern!(ds.methods, String(method)),
        phase = intern!(ds.phases, String(phase)),
        unc,
        unc_k,
        unc_level,
        temperature,
        pressure,
        composition,
    )
    store_input_uncertainties!(ds, row, terms)
    length(ds.properties) == before || refresh!(e.database, e.member)
    return row
end

"""
    add_measurement!(experiment; property, unit = "", value, temperature = NaN, pressure = NaN,
                     composition = (), unc = NaN, unc_k = NaN, unc_level = NaN,
                     unc_temperature = NaN, unc_pressure = NaN, unc_composition = NaN,
                     group = "", method = "", phase = "") -> Int

Add one point to an experiment of a database of your own and return its row. `property` is the
name ThermoML uses ("Mass density"), `unit` the unit of a plain `value` and `unc` ("kg/m3"):
the point is the same property as the archive's only when the label and the stored unit are the
same text. `composition` is the amount of each component in the scale of the experiment (as many as
you know, in the order of `components`), `unc` is the uncertainty (with its coverage factor `unc_k`
or its level of confidence `unc_level`, when you know them). What is not given is `NaN`; nothing is
filled in.

`temperature`, `pressure`, `value` and `unc` are converted here, once, to the numbers the database
stores. Each can be a plain number (`temperature` in K, `pressure` in kPa, `value` and `unc` in
`unit`), a text with a unit (`"20 degC"`, `"0.01 bar"`, `"0.9982 g/cm3"`, `unc = "0.1 %"`) or a
quantity of a units package that is loaded. The value is stored in the unit that the databases
already use for the property (of the same dimension), and in the SI when none has it; a unit of
another quantity, a gauge pressure or a unit that cannot be read is an `ArgumentError`. An
uncertainty is a difference: only its scale is converted. With no `unit`, a plain number is stored
as it is.

`unc_temperature`, `unc_pressure` and `unc_composition` (one for each amount, or a single value
for all the amounts that are given) are the uncertainties of the conditions of the point; they are
optional and stored in the uncertainty table (see [`uncertainty_table`](@ref)). A plain number is
a standard uncertainty (``k = 1``) in K, kPa or the scale of the composition; a text with a unit is
a difference (`"0.05 degC"` is 0.05 K, `"0.09 degF"` is 0.05 K); and `UncertaintyTerm(0.1; k = 2)`
states the coverage. A **percentage** is taken of the value in an **absolute** scale: of the
temperature in kelvin, even when the temperature was given in degC (`"0.01 %"` of 25 degC is 0.01 %
of 298.15 K, that is 0.030 K) and, for degF, equally of the rankine scale (the same number of
kelvin); of the pressure in kPa; and of the amount as stored. A relative uncertainty of a
temperature in an offset scale would otherwise depend on where its zero is.
"""
function add_measurement!(
    e::ExperimentRef;
    property,
    unit::AbstractString = "",
    value,
    temperature = NaN,
    pressure = NaN,
    composition = (),
    unc = NaN,
    unc_k = NaN,
    unc_level = NaN,
    unc_temperature = NaN,
    unc_pressure = NaN,
    unc_composition = NaN,
    group::AbstractString = "",
    method::AbstractString = "",
    phase::AbstractString = "",
)
    c = convert_point(
        UnitChoices(e.database),
        property,
        unit,
        value,
        temperature,
        pressure,
        unc,
    )
    comp = check_point(
        e.ncomp,
        property,
        c.value,
        c.t,
        c.p,
        composition,
        c.unc,
        unc_k,
        unc_level,
    )
    terms = input_uncertainties(
        e.ncomp,
        c.t,
        c.p,
        comp,
        unc_temperature,
        unc_pressure,
        unc_composition,
    )
    return commit_point!(
        e,
        property,
        c.unit,
        group,
        method,
        phase,
        c.value,
        c.t,
        c.p,
        comp,
        c.unc,
        unc_k,
        unc_level,
        terms,
    )
end

const POINT_COLUMNS = (
    :property,
    :unit,
    :group,
    :method,
    :phase,
    :value,
    :temperature,
    :pressure,
    :x1,
    :x2,
    :x3,
    :unc,
    :unc_k,
    :unc_level,
    :unc_temperature,
    :unc_pressure,
    :unc_x1,
    :unc_x2,
    :unc_x3,
)
const EXPERIMENT_KEYS = (:components, :composition_scale, :purpose, :number, :compounds)

# One column of an experiment given as a table: a scalar is repeated for every point.
column_at(column, i) = column isa AbstractVector ? column[i] : column

function point_count(experiment, number::Integer)
    lengths = Int[
        length(v) for
        (k, v) in pairs(experiment) if k in POINT_COLUMNS && v isa AbstractVector
    ]
    isempty(lengths) && throw(
        ArgumentError(
            "experiment $number has no points: give at least one column (value, temperature, ...) as a vector",
        ),
    )
    allequal(lengths) || throw(
        ArgumentError("experiment $number: the columns have different lengths $(lengths)"),
    )
    return first(lengths)
end

"""
    add_reference_data!(db; reference, experiments, database = nothing, compounds = nothing,
                        warn_duplicates = true) -> NamedTuple

Add everything one article measured: its `reference` (the fields of [`add_reference!`](@ref) as a
`NamedTuple`, the result of `add_reference!`, or a DOI already in the database) and its
`experiments`, a list of `NamedTuple`s, each one system. An experiment gives `components`,
optionally `composition_scale`, `purpose`, `number`, and its points as columns: `property`,
`unit`, `value` and the ones you have (`temperature`, `pressure`, `x1`, `x2`, `x3` for the amounts
of the components, `unc`, `unc_k`, `unc_level`, `group`, `method`, `phase`, and the uncertainties
of the conditions `unc_temperature`, `unc_pressure`, `unc_x1`, `unc_x2`, `unc_x3`, read as in
[`add_measurement!`](@ref): a plain number is a standard uncertainty, an `UncertaintyTerm` states its
coverage, and a percentage is taken of the temperature in K and of the pressure in kPa). A column is
a vector with one entry per point, or a single value that is repeated.
`temperature`, `pressure`, `value` and `unc` are converted as in [`add_measurement!`](@ref): a
plain number, a text with a unit or a quantity, one by one, so a column may mix them.

Everything is checked before anything is added, so a mistake in the fifth experiment leaves the
database as it was; with `dry_run = true` only that check is done and nothing is added. Returns
`(reference, experiments, points)`.

When the same work (its DOI, or its first author and year) is already in another database, a warning
says where, how many of the new points repeat points that are there and which calls show both
(`points(db; doi = ...)`), one copy (`duplicate = false`), the pairs ([`duplicates`](@ref)) and the
disagreements ([`conflicts`](@ref)). Nothing is removed or changed; `warn_duplicates = false`
silences it. The search reads the other databases once.

```julia
add_reference_data!(
    db;
    reference = (doi = "10.1000/example", authors = ["Silva, A.", "Souza, B."], year = 2024),
    experiments = [
        (
            components = ["water", "7647-14-5"],
            composition_scale = :molality,
            property = "Mass density", unit = "kg/m3",
            temperature = [293.15, 298.15, 303.15], pressure = 101.325,
            x2 = [1.0, 1.0, 1.0], value = [1038.1, 1036.4, 1034.5],
        ),
    ],
)
```
"""
function add_reference_data!(
    db::Database;
    reference,
    experiments,
    database = nothing,
    compounds = nothing,
    warn_duplicates::Bool = true,
    dry_run::Bool = false,
)
    m = reference isa ReferenceRef ? reference.member : writable_member(db, database)
    list =
        experiments isa NamedTuple || experiments isa AbstractDict ? [experiments] :
        collect(experiments)
    isempty(list) && throw(ArgumentError("give at least one experiment"))
    # First pass: nothing is added.
    choices = UnitChoices(db)
    fields = nothing
    if reference isa NamedTuple || reference isa AbstractDict
        unknown = [k for k in keys(reference) if Symbol(k) ∉ REFERENCE_FIELDS]
        isempty(unknown) || throw(
            ArgumentError(
                "unknown field $(repr(first(unknown))) of a reference; the fields are $(join(REFERENCE_FIELDS, ", "))",
            ),
        )
        fields = reference_fields(; (Symbol(k) => v for (k, v) in pairs(reference))...)
    else
        find_reference(db, m, reference)
    end
    prepared = map(enumerate(list)) do (n, exp)
        exp = exp isa AbstractDict ? (; (Symbol(k) => v for (k, v) in pairs(exp))...) : exp
        exp isa NamedTuple || throw(
            ArgumentError("experiment $n must be a NamedTuple, got $(typeof(exp))"),
        )
        for k in keys(exp)
            (k in POINT_COLUMNS || k in EXPERIMENT_KEYS) || throw(
                ArgumentError(
                    "experiment $n: unknown column $(repr(k)); the columns are $(join(POINT_COLUMNS, ", ")) and $(join(EXPERIMENT_KEYS, ", "))",
                ),
            )
        end
        haskey(exp, :components) ||
            throw(ArgumentError("experiment $n needs `components`"))
        haskey(exp, :property) || throw(ArgumentError("experiment $n needs `property`"))
        haskey(exp, :value) || throw(ArgumentError("experiment $n needs `value`"))
        specs = check_components(exp.components, get(exp, :compounds, compounds))
        scales = check_scales(get(exp, :composition_scale, nothing), length(specs))
        count = point_count(exp, n)
        points = map(1:count) do i
            col(k, default) = haskey(exp, k) ? column_at(exp[k], i) : default
            amounts = [col(:x1, NaN), col(:x2, NaN), col(:x3, NaN)]
            for j = (length(specs)+1):MAX_COMPONENTS
                haskey(exp, Symbol("x", j)) && throw(
                    ArgumentError(
                        "experiment $n has a column x$j but only $(length(specs)) components",
                    ),
                )
            end
            c, comp, terms = try
                c = convert_point(
                    choices,
                    col(:property, ""),
                    col(:unit, ""),
                    col(:value, NaN),
                    col(:temperature, NaN),
                    col(:pressure, NaN),
                    col(:unc, NaN),
                )
                comp = check_point(
                    length(specs),
                    col(:property, ""),
                    c.value,
                    c.t,
                    c.p,
                    amounts[1:length(specs)],
                    c.unc,
                    col(:unc_k, NaN),
                    col(:unc_level, NaN),
                )
                for j = (length(specs)+1):MAX_COMPONENTS
                    input_missing(col(Symbol("unc_x", j), NaN)) || throw(
                        ArgumentError(
                            "the column unc_x$j needs $j components, the experiment has $(length(specs))",
                        ),
                    )
                end
                terms = input_uncertainties(
                    length(specs),
                    c.t,
                    c.p,
                    comp,
                    col(:unc_temperature, NaN),
                    col(:unc_pressure, NaN),
                    [col(:unc_x1, NaN), col(:unc_x2, NaN), col(:unc_x3, NaN)][1:length(specs)],
                )
                (c, comp, terms)
            catch err
                err isa ArgumentError &&
                    throw(ArgumentError("experiment $n, point $i: $(err.msg)"))
                rethrow()
            end
            (; comp, i, c, terms)
        end
        (; exp, specs, scales, points)
    end
    dry_run && return (;
        reference = nothing,
        experiments = ExperimentRef[],
        points = sum(p -> length(p.points), prepared),
    )
    # Second pass: add.
    ref =
        fields === nothing ? find_reference(db, m, reference) :
        commit_reference!(db, m, fields)
    experiments_added = ExperimentRef[]
    total = 0
    for (; exp, specs, scales, points) in prepared
        e = commit_experiment!(
            ref,
            specs,
            scales;
            purpose = get(exp, :purpose, ""),
            number = get(exp, :number, 0),
        )
        push!(experiments_added, e)
        for (; comp, i, c, terms) in points
            col(k, default) = haskey(exp, k) ? column_at(exp[k], i) : default
            commit_point!(
                e,
                col(:property, ""),
                c.unit,
                col(:group, ""),
                col(:method, ""),
                col(:phase, ""),
                c.value,
                c.t,
                c.p,
                comp,
                c.unc,
                col(:unc_k, NaN),
                col(:unc_level, NaN),
                terms,
            )
            total += 1
        end
    end
    if warn_duplicates
        # A notice about data that are already in another database must never undo the work.
        try
            notify_repeats(db, m, ref.id, total)
        catch err
            err isa InterruptException && rethrow()
            @warn "The search for the same work in the other databases failed" reason =
                sprint(showerror, err)
        end
    end
    return (; reference = ref, experiments = experiments_added, points = total)
end
