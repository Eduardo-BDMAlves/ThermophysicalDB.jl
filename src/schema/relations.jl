# Description of the relations between the tables of a `Dataset`, read from the types.
#
# The columns, their element types and their number come from the definitions of the table
# structs. What a type cannot say (which `Int32` column points to which table, which columns
# identify a row) is declared once, in the constants below. `schema_tables` checks that the
# declarations cover every identifier column, so a column added to a table without a
# declaration here is an error and not a silent omission in the documentation.

"""
Columns of identifiers: `(table, column) => target`. The target is a table of the
`Dataset`, one of its string pools, or `:any` for a row of a table chosen by another column.
"""
const FOREIGN_KEYS = Dict{Tuple{Symbol,Symbol},Symbol}(
    (:references, :source) => :sources,
    (:properties, :group) => :groups,
    (:experiments, :reference) => :references,
    (:experiments, :source) => :sources,
    (:experiments, :components) => :compounds,
    (:experiments, :kinds) => :kinds,
    (:experiments, :samples) => :samples,
    (:experiments, :purpose) => :purposes,
    (:samples, :reference) => :references,
    (:samples, :compound) => :compounds,
    (:samples, :origin) => :origins,
    (:samples, :status) => :statuses,
    (:samples, :supplier) => :suppliers,
    (:samples, :analysis) => :analyses,
    (:samples, :purification) => :purifications,
    (:purity_steps, :sample) => :samples,
    (:purity_steps, :analysis) => :analyses,
    (:purity_steps, :analysis_text) => :extra_texts,
    (:purity_steps, :purification) => :purifications,
    (:purity_steps, :purification_text) => :extra_texts,
    (:measurements, :experiment) => :experiments,
    (:measurements, :property) => :properties,
    (:measurements, :method) => :methods,
    (:measurements, :phase) => :phases,
    (:measurements, :unc_method) => :unc_methods,
    (:extras, :row) => :any,
    (:extras, :key) => :extra_keys,
    (:extras, :text) => :extra_texts,
)

"`Int32` columns that are numbers and not identifiers."
const PLAIN_INT32_COLUMNS = Set{Tuple{Symbol,Symbol}}([
    (:experiments, :number),
    (:samples, :number),
    (:purity_steps, :step),
])

"Columns whose values identify a row, besides its position (the index dictionary of the table)."
const NATURAL_KEYS = Dict{Symbol,Vector{Symbol}}(
    :references => [:doi],
    :compounds => [:key],
    :samples => [:reference, :compound, :number],
    :properties => [:label, :unit],
)

"""
    SchemaColumn

One column of a table. `role` is `:plain`, `:unique` (part of the natural key), `:table`
(identifier of a row of another table), `:pool` (identifier of a string in a pool) or `:any`
(identifier of a row of a table chosen by another column). `target` names the table or the
pool, and is `:none` when there is no relation. `arity` is greater than one for the
columns held as a tuple of vectors, one per component.
"""
struct SchemaColumn
    name::Symbol
    eltype::String
    arity::Int
    role::Symbol
    target::Symbol
end

"""
    SchemaTable

A table of the `Dataset` with its columns, in the order of the struct.
"""
struct SchemaTable
    name::Symbol
    columns::Vector{SchemaColumn}
end

function column_shape(::Type{T}) where {T}
    T <: Tuple && return string(eltype(T.parameters[1])), length(T.parameters)
    return string(eltype(T)), 1
end

"""
    schema_pools() -> Vector{Symbol}

Names of the string pools of a `Dataset`.
"""
schema_pools() =
    Symbol[n for n in fieldnames(Dataset) if fieldtype(Dataset, n) === StringPool]

"""
    schema_tables() -> Vector{SchemaTable}

The tables of a `Dataset`, with the role of each column, read from the type definitions.
"""
function schema_tables()
    pools = schema_pools()
    names = Symbol[n for n in fieldnames(Dataset) if !(n in pools)]
    tables = SchemaTable[]
    for tname in names
        columns = SchemaColumn[]
        T = fieldtype(Dataset, tname)
        for cname in fieldnames(T)
            cname in DERIVED_FIELDS && continue
            element, arity = column_shape(fieldtype(T, cname))
            key = (tname, cname)
            target = get(FOREIGN_KEYS, key, :none)
            role = if target === :none
                if cname in get(NATURAL_KEYS, tname, Symbol[])
                    :unique
                elseif element == "Int32" && !(key in PLAIN_INT32_COLUMNS)
                    error("identifier column `$tname.$cname` has no entry in FOREIGN_KEYS")
                else
                    :plain
                end
            elseif target === :any
                :any
            elseif target in pools
                :pool
            elseif target in names
                :table
            else
                error(
                    "`$tname.$cname` points to `$target`, which is neither a table nor a pool",
                )
            end
            push!(columns, SchemaColumn(cname, element, arity, role, target))
        end
        push!(tables, SchemaTable(tname, columns))
    end
    return tables
end
