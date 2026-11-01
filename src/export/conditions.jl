# The conditions of the experiments (constraints, variables and phases that have no column
# in `table`) as a Tables.jl table.

const CONDITION_ROLE_NAMES = ("constraint", "variable", "phase")

"""
    condition_table(x) -> NamedTuple

One row per condition of a [`Dataset`](@ref), or of the experiments and points behind a
[`DataView`](@ref): everything the ThermoML source states besides the temperature, the
pressure and the composition of the components (frequency, the composition of a solvent, a
second density, ...), and the phases of the system. A Tables.jl table with the columns

`role, doi, experiment, measurement, group, label, value, digits, phase, component,
phase_component`.

- `role` is `"constraint"` (fixed for the whole experiment), `"variable"` (changes from
  point to point; `measurement` is the row of the point, the same row as in
  [`table`](@ref)'s source) or `"phase"` (a phase of the system; `label` is its name).
- `group` is the kind of condition in the ThermoML schema (`"eMiscellaneous"`,
  `"eSolventComposition"`, ...) and `label` its name with the unit, as the source wrote it.
- `digits` are the significant digits of `value` (`-1` when not given); `value` is `NaN`
  for a phase.
- `component` is the compound the condition refers to and `phase_component` the one its
  phase is stated for (`""` for none).
"""
function condition_table(ds::Dataset; view::Union{Nothing,DataView} = nothing)
    cd, ex, m = ds.conditions, ds.experiments, ds.measurements
    keep = trues(length(cd))
    if view !== nothing
        used_experiment = falses(length(ex))
        used_row = falses(length(m))
        for r in view.rows
            used_row[r] = true
            used_experiment[m.experiment[r]] = true
        end
        for i in eachindex(cd.row)
            keep[i] = cd.scope[i] == 1 ? used_experiment[cd.row[i]] : used_row[cd.row[i]]
        end
    end
    ids = findall(keep)
    name(c) = c == NO_ID ? "" : compound_label(ds.compounds, c)
    experiment_of(i) = cd.scope[i] == 1 ? cd.row[i] : m.experiment[cd.row[i]]
    return (;
        role = String[CONDITION_ROLE_NAMES[cd.role[i]] for i in ids],
        doi = String[ds.references.doi[ex.reference[experiment_of(i)]] for i in ids],
        experiment = Int32[experiment_of(i) for i in ids],
        measurement = Int32[cd.scope[i] == 2 ? cd.row[i] : NO_ID for i in ids],
        group = String[pool_string(ds.condition_groups, cd.group[i]) for i in ids],
        label = String[pool_string(ds.condition_labels, cd.label[i]) for i in ids],
        value = cd.value[ids],
        digits = Int[cd.digits[i] == NO_DIGITS ? -1 : Int(cd.digits[i]) for i in ids],
        phase = String[pool_string(ds.phases, cd.phase[i]) for i in ids],
        component = String[name(cd.component[i]) for i in ids],
        phase_component = String[name(cd.phase_component[i]) for i in ids],
    )
end

condition_table(view::DataView) = condition_table(view.dataset; view)
