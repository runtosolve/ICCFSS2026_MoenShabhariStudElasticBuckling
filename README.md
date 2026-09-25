# Elastic buckling analysis of a cold-formed steel stud column with open-source shell finite element software

Companion repository for the paper by Cristopher D. Moen and Amoke Shabhari (RunToSolve LLC), Wei-Wen Yu International
Specialty Conference on Cold-Formed Steel Structures, Madison, WI, 6–7 October 2026.

A 362S162-33 stud, 96 in (2438 mm) long with 1.5 × 4 in SFIA service holes at 24 in on center, braced at midheight
(Lx = Ly = Lt = 48 in), pinned warping-free ends, uniform compression. Elastic local, distortional, and global buckling
loads and mode shapes are computed with [Ferrite.jl](https://github.com/Ferrite-FEM/Ferrite.jl) and one shell model that
combines the open-source Mindlin elements [QuadShellFiniteElement.jl](https://github.com/runtosolve/QuadShellFiniteElement.jl)
(structured flats) and [TriShellFiniteElement.jl](https://github.com/runtosolve/TriShellFiniteElement.jl) (patches around the
holes), and compared with
[CUFSM.jl](https://github.com/runtosolve/CUFSM.jl) and [CeeSectionBuckling.jl](https://github.com/runtosolve/CeeSectionBuckling.jl).

## Contents
| Path | What it is |
|---|---|
| `main.typ`, `references.bib`, `images/` | the paper (Typst); `typst compile main.typ` |
| `analysis/stud_buckling_tools.jl` | shared module: section, hybrid structured-quad + Gmsh triangular hole-patch mesh, mixed-grid dofs (two `SubDofHandler`s), loads, constraints, K / Kg assembly per element type, ARPACK solves, mode classification |
| `analysis/01_make_meshes.jl` | builds the mixed quadrilateral/triangle grid (`meshes/*.jls`); `--elements=tri` or `quad` give single-element grids |
| `analysis/02_run_fe.jl` | eigenbuckling: lowest modes + shift-and-invert windows, classification, `results/modes_*.csv/jls`, `summary_*.txt` |
| `analysis/03_baselines.jl` | CUFSM signature curve; gross, net-section, and reduced-thickness values; analytical global buckling |
| `analysis/04_figures.jl`, `05_results_table.jl` | paper figures and the results table |
| `analysis/06_viewer_export.jl` | exports the standalone browser mode viewer (`viewer/index.html`, Bonito + WGLMakie) |
| `notebook/stud_buckling_notebook.jl` | Pluto notebook that walks through the example |
| `viewer/index.html` | interactive buckling mode viewer (open in a browser, or via GitHub Pages) |

## Running
Julia ≥ 1.10. The shell element packages and the RunToSolve section/buckling packages are unregistered; the environment
in `analysis/` was created with `analysis/setup_env.jl` (`Pkg.develop` of the packages below, then `Pkg.add` of Ferrite,
Arpack, LinearMaps, Gmsh, CairoMakie, WGLMakie, Bonito).

```
git clone https://github.com/runtosolve/TriShellFiniteElement.jl   # and QuadShellFiniteElement.jl, CUFSM.jl,
                                                                     # CeeSectionBuckling.jl, CrossSectionGeometry.jl,
                                                                     # SectionProperties.jl, BucklingModeIdentification.jl,
                                                                     # AISIS100.jl, LinesCurvesNodes.jl
cd analysis
julia --project=. 01_make_meshes.jl                    # M1: dz = 5 mm  (add --dz=2.5 --tag=M2 for the refined grids)
julia --project=. 02_run_fe.jl --model=meshes/stud96_M1_mixed.jls   # and stud96_M2_mixed.jls for the refined check
julia --project=. 03_baselines.jl
julia --project=. 04_figures.jl --stress
julia --project=. 05_results_table.jl
julia --project=. 06_viewer_export.jl
```
Notebook: `julia -e 'using Pluto; Pluto.run()'` and open `notebook/stud_buckling_notebook.jl`.

Units are N and mm throughout; kips and inches appear only in reported tables.
