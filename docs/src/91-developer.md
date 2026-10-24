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

The look of the site lives in `docs/src/.vitepress/theme/style.css` (colours, cards, figures), the logo and the hero picture in `docs/src/assets`, and the shared plot theme of the examples in `docs/DocsSetup.jl`. To preview the generated Markdown with live reload, build once and then call `DocumenterVitepress.dev_docs("docs/build")` from a second Julia session, as explained in the DocumenterVitepress manual.

### Conventions for pages and figures

- **Page names** follow the template: numbered prefixes (`10-`, `20-`, ...) that set the order, hyphens between words, and numbered folders for sections. A folder needs a title in the `titles` dictionary of `docs/make.jl`.
- **Units in labels** go in square brackets, never after a slash: `T [K]`, `p [MPa]`, `λ [W m⁻¹ K⁻¹]`. A quantity that is a ratio carries the unit of its scale in brackets, for example `(ρ − ρ_ref)/ρ_ref [%]`. A slash divides quantities; it does not mark a unit.
- **Pictures** use the shared theme (`Main.DocsSetup.activate!()` in a hidden `@setup` block). Colour continuous data with the default colormap and do not add emoji or icons to the text.
- **Data credit.** Every page that shows archive data should make clear that the data come from the NIST/TRC ThermoML Archive and the original articles, not from this package. See [About the data](@ref 40-about-data).

## Making a new release

To create a new release, you can follow these simple steps:

- Create a branch `release-x.y.z`
- Update `version` in `Project.toml`
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
