# [Developer documentation](@id dev_docs)

!!! note "Contributing guidelines"
    If you haven't, please read the [Contributing guidelines](90-contributing.md) first.

If you want to make contributions to this package that involves code, then this guide is for you.

## First time clone

!!! tip "If you have writing rights"
    If you have writing rights, you don't have to fork. Instead, simply clone and skip ahead. Whenever **upstream** is mentioned, use **origin** instead.

If this is the first time you work with this repository, follow the instructions below to clone the repository.

1. Fork this repo
2. Clone your repo (this will create a `git remote` called `origin`)
3. Add this repo as a remote:

   ```bash
   git remote add upstream https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl
   ```

This will ensure that you have two remotes in your git: `origin` and `upstream`.
You will create branches and push to `origin`, and you will fetch and update your local `main` branch from `upstream`.

## Linting and formatting

Install a plugin on your editor to use [EditorConfig](https://editorconfig.org).
This will ensure that your editor is configured with important formatting settings.

We use [https://pre-commit.com](https://pre-commit.com) to run the linters and formatters.
In particular, the Julia code is formatted using [JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl), so please install it globally first:

```julia-repl
julia> # Press ]
pkg> activate
pkg> add JuliaFormatter
```

To install `pre-commit`, we recommend using [pipx](https://pipx.pypa.io) as follows:

```bash
# Install pipx following the link
pipx install pre-commit
```

With `pre-commit` installed, activate it as a pre-commit hook:

```bash
pre-commit install
```

To run the linting and formatting manually, enter the command below:

```bash
pre-commit run -a
```

**Now, you can only commit if all the pre-commit tests pass**.

### Link checking locally

We use `lychee` for link checking in CI. You can run it locally to avoid waiting for CI. First, [install lychee](https://github.com/lycheeverse/lychee?tab=readme-ov-file#installation), then run against the repository root using the project config:

```bash
lychee --no-progress --config lychee.toml .
```

## Testing

As with most Julia packages, you can just open Julia in the repository folder, activate the environment, and run `test`:

```julia-repl
julia> # press ]
pkg> activate .
pkg> test
```

## Working on a new issue

We try to keep a linear history in this repo, so it is important to keep your branches up-to-date.

1. Fetch from the remote and fast-forward your local main

   ```bash
   git fetch upstream
   git switch main
   git merge --ff-only upstream/main
   ```

2. Branch from `main` to address the issue (see below for naming)

   ```bash
   git switch -c 42-add-answer-universe
   ```

3. Push the new local branch to your personal remote repository

   ```bash
   git push -u origin 42-add-answer-universe
   ```

4. Create a pull request to merge your remote branch into the org main.

### Branch naming

- If there is an associated issue, add the issue number.
- If there is no associated issue, **and the changes are small**, add a prefix such as "typo", "hotfix", "small-refactor", according to the type of update.
- If the changes are not small and there is no associated issue, then create the issue first, so we can properly discuss the changes.
- Use dash separated imperative wording related to the issue (e.g., `14-add-tests`, `15-fix-model`, `16-remove-obsolete-files`).

### Commit message

- Use imperative or present tense, for instance: *Add feature* or *Fix bug*.
- Have informative titles.
- When necessary, add a body with details.
- If there are breaking changes, add the information to the commit message.

### Before creating a pull request

!!! tip "Atomic git commits"
    Try to create "atomic git commits" (recommended reading: [The Utopic Git History](https://blog.esciencecenter.nl/the-utopic-git-history-d44b81c09593)).

- Make sure the tests pass.
- Make sure the pre-commit tests pass.
- Fetch any `main` updates from upstream and rebase your branch, if necessary:

  ```bash
  git fetch upstream
  git rebase upstream/main BRANCH_NAME
  ```

- Then you can open a pull request and work with the reviewer to address any issues.

## Building and viewing the documentation locally

The site is built with [Documenter.jl](https://documenter.juliadocs.org) and [DocumenterVitepress.jl](https://luxdl.github.io/DocumenterVitepress.jl/dev/). The tutorials execute real code against the ThermoML Archive, so building them needs the database.

1. Run `julia --project=docs` to open Julia in the environment of the docs.
1. If this is the first time building the docs
   1. Press `]` to enter `pkg` mode
   1. Run `pkg> dev .` to use the development version of your package
   1. Press backspace to leave `pkg` mode
1. Build the site with `julia> include("docs/make.jl")`. The first build downloads and parses the archive (a few minutes); later builds load the binary cache. Starting Julia with `-t auto` makes the parsing faster.

To edit text without running any example, use the draft mode, which skips every executed block:

```bash
THERMOPHYSICALDB_DOCS_DRAFT=true julia --project=docs docs/make.jl
```

To keep the data somewhere else than the default location, set `THERMOPHYSICALDB_DATA_DIR` before starting Julia (see [Downloads, updates and cache](@ref updates)).

The look of the site lives in `docs/src/.vitepress/theme/style.css` (colours, cards, figures), the logo and the hero picture in `docs/src/assets`, and the shared plot theme of the examples in `docs/DocsSetup.jl`.
The accent colour is the orange of a neon (Ne) discharge tube: the neon lines span about 585 nm to 640 nm, and the middle of the band, Ne I 614.31 nm (spectral colour near `rgb(255, 120, 0)`), is rendered as `#ff7a1a` (`--neon-ne`); in light mode a deeper `#b34700` keeps the text legible.
Title gradients run through the colours of discharge tubes: the mercury line Hg 435.83 nm (`#4f6bff`, `--neon-blue`), the helium line He I 447.15 nm (`#3347ff`, `--neon-he`, the closest tube colour to the navy of the laboratory logo), hydrogen H-alpha 656.28 nm (red, `#ff2f3f`) and the neon orange as the dominant end.
To preview the generated Markdown with live reload, build once and then call `DocumenterVitepress.dev_docs("docs/build")` from a second Julia session, as explained in the DocumenterVitepress manual.

The JavaScript side of the site is declared in `docs/package.json`, a copy of the default of DocumenterVitepress plus an `overrides` block.
The default pins `vitepress` 1.6, which depends on `vite` 5 and `esbuild` 0.21, and `@mathjax/src`, which depends on old `glob` and `minimatch`; `npm audit` reports 10 known vulnerabilities in them (moderate, and one high in `vite`).
All of them are in development tooling (the development server and glob patterns of the build), none reaches the published pages, and the `overrides` raise those four packages to patched versions, so `npm audit` reports none.
When updating DocumenterVitepress, compare this file with its `template/package.json` and, once VitePress 2 is supported, drop the `overrides` and check `npm audit` again.

### Timing of the build

`docs/DocsTiming.jl` runs `makedocs` under a logger that adds `[HH:MM:SS | +time since the previous mark | time since the start]` to the start of every Documenter phase (`SetupBuildDirectory`, `ExpandTemplates`, ..., the VitePress build) and of every page, and ends the build with a table of the time of each phase and of each page, slowest first. The examples of a page run while its template is expanded, so the time between two page marks is the time of that page. Nothing else in the output changes. `THERMOPHYSICALDB_DOCS_TIMING=false` turns it off.

### Credits and versions, generated by the build

The articles behind the data and the versions of the packages are never written by hand; `docs/DocsCredits.jl` produces them while the examples run.

- **A page that shows data** ends with the folded block "Sources of the data", whose example calls `Main.DocsCredits.credits(views...)` with the selections the page uses. It lists the articles of the page from the metadata of the archive (no network) and registers the points. A new page that shows data only needs that block; a page whose selections only illustrate how to select (such as the whole archive in "Selecting points") leaves it out.
- **"Data credits"** (`96-data-credits.md`) lists every registered article and writes `data-credits.bib` for download, with the entries that `bibtex` builds (the DOI resolver first, the archive for what is missing). By default the build does not contact `doi.org`: it uses the entries already in the cache of the data directory, and writes the others from the metadata of the archive alone, which keeps the build fast. A release build sets `THERMOPHYSICALDB_DOCS_ONLINE=true` to ask the resolver (once per article, then cached) for the entries that are missing. Documenter expands the pages in alphabetical order unless `expandfirst` says otherwise, so `docs/make.jl` lists every page except this one in `expandfirst`: it runs last, when the registry is complete.
- **The front page** calls `Main.DocsCredits.environment()`, which reads the versions of Julia, of the package (with the commit), of the archive (version and SHA-256) and of the direct dependencies of `docs/Project.toml` from the environment that is building the site, writes them to `versions.toml` for download and prints the commands that install them. The packages that build the site (`TOOLING` in `DocsCredits.jl`) are in the file but not in the table. Nothing needs updating when a dependency changes.

Both downloads are written into `public/` of the build directory, so they are not in git.

### Conventions for pages and figures

- **Page names** follow the template: numbered prefixes (`10-`, `20-`, ...) that set the order, hyphens between words, and numbered folders for sections. A folder needs a title in the `titles` dictionary of `docs/make.jl`.
- **Units in labels** go in square brackets, never after a slash: `T [K]`, `p [MPa]`, `λ [W m⁻¹ K⁻¹]`. A quantity that is a ratio carries the unit of its scale in brackets, for example `(ρ − ρ_ref)/ρ_ref [%]`. A slash divides quantities; it does not mark a unit.
- **Pictures** use the shared theme (`Main.DocsSetup.activate!()` in a hidden `@setup` block). Colour continuous data with the default colormap (cold to hot: blue, cyan, white, amber, red; blue is low or negative and red is high or positive) and do not add emoji or icons to the text.
- **References.** The works the package credits (the ThermoML Archive and standard, the articles about them, the work of the group) are written once, in the `references:` of `CITATION.cff`, and everything else is generated from it: the notice, the `.bib` of every export and `docs/src/refs.bib` (not in git; `docs/make.jl` writes it).
Each reference needs an `abbreviation`, its citation key in the pattern of the reference manager (surname of the first author, year and first word of the title, all lower case: `riccardi2022towards`), and `keywords`: `data-source` (credited in every export from that database), `group` (work of the research group) or `background`.
Run `ThermophysicalDB.check_references()` after editing: it verifies the fields and the keys and compares each article with the record of its DOI.
Literature that is not about the data goes in `docs/src/refs-literature.bib`.
Cite from any page with `[key](@cite)`; the entries are listed on the [Bibliography](@ref bibliography) page.
Check the volume and pages against the publisher.
- **Data credit.** Every page that shows archive data should make clear that the data come from the NIST/TRC ThermoML Archive and the original articles, not from this package. See [About the data](@ref 40-about-data).

## Supporting another unit package

The package works with plain `Float64`; a unit package is only a way to write and to show quantities, and it is an extension in `ext/`, activated when the user loads the package. The core defines a small internal protocol (in `src/units/backend.jl`, nothing is exported), and an extension implements it for its package:

| Function | What it does |
|---|---|
| `register_unit_backend!(Module, backend)` | called in `__init__`, so that `quantities = Module` finds the backend |
| `parse_unit(backend, text)` | the unit of a text such as `"kPa"` |
| `attach_unit(backend, column, unit)` | the `Float64` column with the unit |
| `native_value(x, kind)` | the value of a quantity in the unit of the archive (`kind` is `NativeTemperature()`, `NativePressure()` or a unit of the catalog) |
| `native_difference(x, kind)` | the same for an interval, by scale only (0.01 °C is 0.01 K) |
| `unit_factor(backend, from, to)` | the factor between two parsed units of a property: a `Rational` if the package is exact, otherwise a `Float64`; it throws if the dimensions differ or if `to` has an offset |
| `quantity_parts(backend, x)` | optional: `(number, unit_text)` of a quantity; if the text is understood the input is converted exactly by the package |
| `package_native_value(backend, x, kind)`, `package_native_difference(backend, x, kind)` | the conversion of an input that the package does itself, when the unit is not understood (or when the package stores SI and keeps no text) |
| `package_convert_native(backend, x, kind, to)` | the same for `reference_summary` |
| `unit_text(backend, unit)` | optional: the unit as text in a syntax the exact parser reads (`"mW m^-1 K^-1"`), or `nothing`; when it is understood, the conversion is done by the package and the backend only attaches the unit |
| `convert_native(x, kind, to)` | the conversion for `reference_summary` |

The conversions that the core does by itself are in `src/units/exact.jl`: `ExactUnit` (an exact scale and the exponents of the six base dimensions), `ExactAffine` (scale and offset), `parse_exact_unit` (the strings of the catalog) and `FloatAffine` with the column kernels `apply` and `apply!`. A new unit is added by writing its legal definition with rationals; never write a rounded decimal.

Do not call `uparse` at the top level of an extension: it evaluates code, which breaks precompilation. Use the `u"..."` macro or parse at run time. `ext/ThermophysicalDBUnitfulExt.jl` is the shortest model to copy, and `test/test-units-backends.jl` has the tests that a backend has to pass.

## Benchmarks

The folder `benchmark/` measures what a change costs, with [AirspeedVelocity.jl](https://github.com/MilesCranmer/AirspeedVelocity.jl). Every pull request that touches `src/`, `ext/` or `benchmark/` runs the workflow `.github/workflows/Benchmark.yml`, which compares the pull request with the latest release (the latest tag `v*`; until there is a release, with `main`) and comments the result on the pull request. It marks a benchmark when the time or the allocated memory changes by more than 15 %; it never fails the pull request. A runner of GitHub varies by some per cent from one run to the next, so read a single marked line with care and a pattern (several related benchmarks) with more trust; the allocated memory does not vary between runs.

What is measured, in `benchmark/benchmarks.jl`:

| Group | What it measures |
|---|---|
| `load` | opening a database that is stored (the registry alone, then the dataset), the first query, `link_compounds` |
| `add` | `add_reference_data!` of one article (about 90 points) in an empty and in a large database, with and without the check of repeated points, ten articles, and 100 points added one by one |
| `filter` | the filters by compound, property, temperature and pressure: each stage alone (starting from the result of the stage before), the four calls one after the other, and the four filters in one call; over the database and over the database linked to the compound database, by a name |
| `units` | `table` and `points` with plain numbers, then with Unitful, DynamicQuantities and FlexUnits |
| `template` | writing the spreadsheet with 2 and with 20 experiments, and reading and checking the two example files of `docs/src/assets/` |
| `outliers` | `find_outliers` over a standard set of points |

The data are synthetic and the same for every revision (`benchmark/synthetic.jl`, built only with the public functions of the package and a fixed seed), so a difference is a difference of the code. `TDB_BENCH_SCALE` sets the size: `small` (20 thousand points), `medium` (200 thousand, the default) or `full` (2.8 million, as many as the archive); `full` is run by hand (Actions, Benchmark, Run workflow). The file of the database is stored between runs by `TDB_BENCH_CACHE`, in a folder whose name is a hash of the files of the schema, of `src/store/serialize.jl` and of the generator: a revision with another structure writes its own file and never reads one that another structure wrote. The synthetic database has no sample, purity, condition or extra-field tables, because `add_reference_data!` does not store them yet; the memory of those tables is not in the report until it does.

Besides the benchmarks, `benchmark/memory_report.jl` loads the database in a process of its own for each revision and reports what stays in memory, table by table (`Base.summarysize`) and for the process. The allocations that AirspeedVelocity compares are what a call allocates; this is what remains, which is where the structures of the data are judged.

To run it on your machine, from the repository folder:

```bash
# the benchmarks of this working copy against the latest release (needs AirspeedVelocity: pkg> add AirspeedVelocity)
TDB_BENCH_SCALE=small benchpkg --rev=v0.1.0,dirty --output-dir=benchmark-results
benchpkgtable --rev=v0.1.0,dirty --input-dir=benchmark-results --mode=time,memory --ratio

# the retained memory of two checkouts
julia benchmark/memory_report.jl base=/path/to/release head=.
```

To add a benchmark, define it in `benchmark/benchmarks.jl` with `register!(group, name, @benchmarkable(...))`. A benchmark that writes or loads starts from a clean state in `setup` with `evals = 1`. `register!` runs it once, so a benchmark that cannot run on an older revision (the function did not exist yet) is left out with a warning instead of stopping the others. The script is the one of the pull request for both revisions, so use only the public functions in the generator and in the setup. Change `benchmark/synthetic.jl` only when needed: it changes the data of every comparison.

## Making a new release

To create a new release, you can follow these simple steps:

- Create a branch `release-x.y.z`
- Update `version` in `Project.toml` and, in `CITATION.cff`, `version`, `date-released` and (once Zenodo has issued it) the `doi` of the release; when the article of the package is published, add it as `preferred-citation`
- Run `ThermophysicalDB.check_references()`
- Update the `CHANGELOG.md`:
  - Rename the section "Unreleased" to "[x.y.z] - yyyy-mm-dd" (i.e., version under brackets, dash, and date in ISO format)
  - Add a new section on top of it named "Unreleased"
  - Add a new link in the bottom for version "x.y.z"
  - Change the "[unreleased]" link to use the latest version - end of line, `vx.y.z ... HEAD`.
- Create a commit "Release vx.y.z", push, create a PR, wait for it to pass, merge the PR.
- Go back to main screen and click on the latest commit (link: <https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/commit/main>)
- At the bottom, write `@JuliaRegistrator register`

After that, you only need to wait and verify:

- Wait for the bot to comment (should take < 1m) with a link to a PR to the registry
- Follow the link and wait for a comment on the auto-merge
- The comment should said all is well and auto-merge should occur shortly
- After the merge happens, TagBot will trigger and create a new GitHub tag. Check on <https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/releases>
- After the release is create, a "docs" GitHub action will start for the tag.
- After it passes, a deploy action will run.
- After that runs, the [stable docs](https://eduardo-bdmalves.github.io/ThermophysicalDB.jl/stable) should be updated. Check them and look for the version number.
