"""
    ThermophysicalDB

Download, cache and query experimental thermophysical property data from public
databases, starting with the NIST/TRC ThermoML Archive.
"""
module ThermophysicalDB

using CodecZlib: GzipCompressorStream, GzipDecompressorStream
using Dates: Dates
using DOI2BibTeX: DOI2BibTeX
using Downloads: Downloads
using FileWatching: FileWatching
using JLD2: JLD2
using JSON: JSON
using LaTeXStrings: LaTeXStrings
using LinearAlgebra: I, LAPACK, Symmetric, cholesky!, issuccess, lu
using Preferences: Preferences
using SHA: SHA
using SpecialFunctions: SpecialFunctions
using TOML: TOML
using Tables: Tables
using Tar: Tar
using Unicode: Unicode
using UUIDs: UUIDs
using YAML: YAML

include("remote/datadir.jl")
include("audit/log.jl")
include("remote/checksum.jl")
include("remote/releases.jl")
include("remote/manifest.jl")
include("remote/archive.jl")
include("remote/download.jl")
include("remote/install.jl")
include("remote/local.jl")
include("units/decimal.jl")
include("units/exact.jl")
include("units/catalog.jl")
include("units/backend.jl")
include("uncertainty/coverage.jl")
include("schema/pool.jl")
include("schema/pooled.jl")
include("schema/tables.jl")
include("schema/dataset.jl")
include("schema/relations.jl")
include("query/compounds.jl")
include("query/select.jl")
include("query/filters.jl")
include("parse/types.jl")
include("parse/purity.jl")
include("parse/article.jl")
include("parse/ingest.jl")
include("parse/build.jl")
include("query/table.jl")
include("query/pointtable.jl")
include("query/sort.jl")
include("uncertainty/budget.jl")
include("store/serialize.jl")
include("store/cache.jl")
include("store/database.jl")
include("compounds/seed.jl")
include("compounds/table.jl")
include("compounds/store.jl")
include("compounds/pubchem.jl")
include("compounds/link.jl")
include("composition/scales.jl")
include("composition/convert.jl")
include("references.jl")
include("notice.jl")
include("export/bibtex.jl")
include("export/citation.jl")
include("export/check.jl")
include("export/purity.jl")
include("export/summary.jl")
include("export/points.jl")
include("export/phases.jl")
include("export/thermoml.jl")
include("export/conditions.jl")
include("outliers/stats.jl")
include("outliers/esd.jl")
include("outliers/physical.jl")
include("outliers/polyfit.jl")
include("outliers/prepare.jl")
include("outliers/trend.jl")
include("outliers/surface.jl")
include("outliers/detect.jl")
include("outliers/pipeline.jl")
include("database/publication.jl")
include("database/members.jl")
include("database/registry.jl")
include("database/inputs.jl")
include("database/repeats.jl")
include("database/database.jl")
include("database/export.jl")
include("compounds/linked.jl")
include("database/duplicates.jl")
include("query/combine.jl")
include("database/user.jl")
include("database/share.jl")
include("database/subset.jl")
include("database/remove.jl")
include("database/conflicts.jl")
include("database/edit.jl")
include("database/template.jl")
include("plots/symbols_table.jl")
include("plots/labels.jl")
include("plots/deviation.jl")
include("plots/kde.jl")
include("plots/style.jl")
include("plots/spec.jl")
include("plots/data.jl")
include("plots/builders.jl")
include("plots/vle.jl")
include("plots/extra.jl")
include("plots/api.jl")
include("precompile.jl")

export COMPOSITION_SCALES,
    Database,
    DatabaseView,
    DuplicateReport,
    DuplicateRules,
    ExperimentRef,
    Member,
    ReferenceRef,
    add_database!,
    add_template_experiments!,
    add_experiment!,
    add_measurement!,
    add_member!,
    add_reference!,
    add_reference_data!,
    databases_dir,
    clear_database!,
    export_database,
    import_database!,
    member_dataset,
    members,
    Overlap,
    overlap,
    parts,
    pure_component,
    remove_database!,
    remove_reference!,
    remove_points!,
    update_points!,
    remove_member!,
    resolve_compound,
    save_database,
    created_at,
    modified_at,
    set_priority!,
    Publication,
    set_publication!,
    publication,
    CompositionConversion,
    CompoundDB,
    convert_composition,
    DataView,
    PointTable,
    DeviationSpec,
    FigureSpec,
    PlotData,
    PlotStyle,
    axis_label,
    deviation,
    EquilibriumPoints,
    equilibrium,
    plot_by_reference,
    plot_deviation_map,
    plot_deviation_map!,
    plot_excess,
    plot_excess!,
    plot_ternary,
    plot_ternary!,
    plot_years,
    plot_years!,
    plot_by_reference!,
    plot_pxy!,
    plot_saturation!,
    plot_txy!,
    plot_xy!,
    plot_comparison!,
    plot_facets!,
    plot_isobars!,
    plot_isotherms!,
    plot_parity!,
    plot_residuals!,
    plot_xpt!,
    plot_comparison,
    plot_defaults,
    plot_facets,
    plot_isobars,
    plot_isotherms,
    plot_parity,
    plot_pxy,
    plot_residuals,
    plot_saturation,
    plot_style,
    plot_txy,
    plot_xpt,
    plot_xy,
    plotdata,
    register_symbol!,
    render,
    reset_plot_defaults!,
    UncertaintyTerm,
    audit_checkpoint,
    audit_log,
    bibtex,
    check_update,
    compound_database,
    compound_record,
    conflicts,
    condition_table,
    csv_table,
    database_dir,
    database,
    diagnostics,
    duplicates,
    ensure_archive,
    esd,
    expanded_uncertainty,
    export_points,
    export_template,
    fetch_pubchem!,
    find_compounds,
    find_outliers,
    import_template,
    forget_choices!,
    install_archive!,
    latex_table,
    link_compounds,
    link_compounds!,
    link_table,
    lookup_compounds,
    markdown_table,
    measured_properties,
    measurement_methods,
    mixture,
    molar_mass,
    phases,
    points,
    prefetch_compounds!,
    pubchem_rate!,
    purity_step_table,
    reasons,
    register_compound!,
    reference_summary,
    reset_database_dir!,
    sample_table,
    save_compounds,
    set_database_dir!,
    set_uncertainty!,
    table,
    thermoml_phase,
    thermoml_phases,
    uncertainty_table,
    update_database!,
    verify_audit_log,
    write_bibtex,
    write_references

end
