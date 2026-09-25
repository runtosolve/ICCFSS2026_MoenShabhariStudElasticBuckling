### A Pluto.jl notebook ###
# v1.0.3

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    #! format: off
    return quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
    #! format: on
end

# ╔═╡ 501935d5-34ad-4155-bd78-ef318824f962
begin
	import Pkg
	Pkg.activate(joinpath(@__DIR__, "..", "analysis"))
	using PlutoUI, WGLMakie, Ferrite, Serialization, Statistics, LinearAlgebra, Printf
	WGLMakie.activate!()
	# the module must live in Main so that deserialize() can resolve the StudModel / ModeMetrics types in results/*.jls
	Base.include(Main, joinpath(@__DIR__, "..", "analysis", "stud_buckling_tools.jl"))
	SBT = Main.StudBucklingTools
	resdir = joinpath(@__DIR__, "..", "analysis", "results")
	meshdir = joinpath(@__DIR__, "..", "analysis", "meshes")
	nothing
end

# ╔═╡ 4387e145-6ce2-40c2-8d43-f248af75d3c5
md"""
# Elastic buckling of a cold-formed steel stud column with service holes
### An open-source shell finite element walk-through (Ferrite.jl + QuadShellFiniteElement.jl + TriShellFiniteElement.jl)

Companion notebook to *Moen and Shabhari (2026), Elastic buckling analysis of a cold-formed steel stud column with open-source shell finite element software*, Wei-Wen Yu International Specialty Conference on Cold-Formed Steel Structures.

**Problem.** A 362S162-33 stud (web 92.1 mm, flanges 41.3 mm, lips 12.7 mm, t = 0.879 mm, E = 200 000 MPa, ν = 0.3), 96 in (2438 mm) long, with 1.5 × 4 in SFIA service holes at 24 in on centre, braced at midheight so that Lx = Ly = Lt = 48 in, pinned warping-free ends, uniform compression.  We compute the elastic local, distortional, and global buckling loads and look at the mode shapes.

Cells that run the finite element analysis are opt-in (checkboxes) so the notebook opens quickly; saved results from the paper are shown by default.
"""

# ╔═╡ 77f7334c-4536-479e-93db-9baff8526cb5
md"""
## 1. Cross-section
The centerline polyline of the section comes from `CrossSectionGeometry.jl`: flats subdivided `k × [2, 10, 10, 10, 2]` times, rounded corners with 4 elements each.  Nodes are shared with the finite strip (CUFSM) model so that the shell and strip analyses use exactly the same geometry.
"""

# ╔═╡ 3123ad9c-5f28-4218-854f-6e5b42975797
sec = SBT.section_362S162_33(; k = 2)

# ╔═╡ 407a990f-c5f8-4fa5-a52a-087df05cc7cb
let
	fig = Figure(size = (420, 420))
	ax = Axis(fig[1, 1]; aspect = DataAspect(), xlabel = "x [mm]", ylabel = "y [mm]", title = "362S162-33 centerline, $(length(sec.X)) nodes, A = $(round(sec.A; digits = 1)) mm²")
	lines!(ax, sec.X, sec.Y; color = :black)
	scatter!(ax, sec.X, sec.Y; markersize = 6, color = :steelblue)
	scatter!(ax, [sec.X[sec.web_center]], [sec.Y[sec.web_center]]; markersize = 12, color = :red, label = "web centre (brace datum)")
	scatter!(ax, sec.X[collect(sec.wf_corners)], sec.Y[collect(sec.wf_corners)]; markersize = 12, color = :orange, label = "web-flange corners (brace ux = 0)")
	axislegend(ax; position = :rt)
	fig
end

# ╔═╡ 0368d442-b1a2-4387-a1b0-3b1ec968edbc
md"""
## 2. Finite strip and closed-form baselines
`03_baselines.jl` computed these with `CUFSM.jl`, `CeeSectionBuckling.jl` (net-section local buckling and AISI S100 reduced-web-thickness distortional buckling, the procedure used in RunToSolve's SFIA product evaluations), and the classical flexural-torsional buckling equations.
"""

# ╔═╡ 98ce2c38-b689-4037-b6e0-9101da1a508c
baselines = deserialize(joinpath(resdir, "baselines.jls"))

# ╔═╡ 9bdba767-51c4-4319-9c61-6163ca8bb170
let b = baselines, c = b["csb_FE-matched"]
	rows = [("CUFSM gross local minimum", b["cufsm_local"].Pcr, b["cufsm_local"].Lcr),
	        ("CUFSM gross distortional minimum", b["cufsm_dist"].Pcr, b["cufsm_dist"].Lcr),
	        ("Net-section local (hole)", c.Pcrl_hole, c.Lcrl_hole),
	        ("Reduced-thickness distortional (hole)", c.Pcrd_hole, c.Lcrd_hole),
	        ("Analytical flexural-torsional, KL = 48 in", b["global_gross"].PFT, 1219.2),
	        ("Flexural-torsional, weighted-average net", b["global_hole"].PFT, 1219.2),
	        ("Analytical weak-axis flexure, KL = 48 in", b["global_gross"].Pey, 1219.2)]
	lines = ["| quantity | P_cr [kN] | P_cr [kips] | half-wavelength [mm] |", "|---|---|---|---|"]
	for r in rows
		push!(lines, "| $(r[1]) | $(round(r[2]/1000; digits = 2)) | $(round(r[2]/SBT.N_PER_KIP; digits = 2)) | $(round(Int, r[3])) |")
	end
	Markdown.parse(join(lines, "\n"))
end

# ╔═╡ ca7999cf-d29c-459c-a7e8-44fd2bb3be5e
let b = baselines
	fig = Figure(size = (700, 380))
	ax = Axis(fig[1, 1]; xscale = log10, xlabel = "half-wavelength [mm]", ylabel = "P_cr [kN]", title = "CUFSM signature curve, gross section")
	lines!(ax, b["sig_L"], b["sig_fcr"] .* b["A"] ./ 1000; color = :black)
	c = b["csb_FE-matched"]
	scatter!(ax, [c.Lcrl, c.Lcrd], [c.Pcrl, c.Pcrd] ./ 1000; color = :black, markersize = 12, label = "gross local / distortional")
	scatter!(ax, [c.Lcrl_hole, c.Lcrd_hole], [c.Pcrl_hole, c.Pcrd_hole] ./ 1000; color = :red, markersize = 12, label = "with hole (net section / reduced thickness)")
	scatter!(ax, [1219.2], [b["global_gross"].PFT / 1000]; color = :black, marker = :diamond, markersize = 14, label = "flexural-torsional, KL = 48 in")
	ylims!(ax, 0, 80); axislegend(ax; position = :lt)
	fig
end

# ╔═╡ ab6dbcf8-2325-4161-8e03-d6dac0e8e231
md"""
## 3. Shell finite element mesh
The stud is extruded as a structured grid of quadrilateral shell elements (85 section nodes × 489 planes, 5 mm longitudinally); the web region around each hole is cut out and re-meshed with Gmsh triangles around a true stadium-shaped hole, then stitched back. Quadrilaterals (`QuadShellFiniteElement.jl`) and triangles (`TriShellFiniteElement.jl`) share their nodes through two Ferrite `SubDofHandler`s.
"""

# ╔═╡ 0774a0de-960f-4508-a383-27f471ab85bb
element_choice = "mixed"

# ╔═╡ 94705e4a-6ee3-48a8-994e-45e13ef451fd
model = SBT.load_model(joinpath(meshdir, "stud96_M1_$(element_choice).jls"))

# ╔═╡ 5378357c-976e-41a6-93bf-f18e9411128b
let m = model
	xs, ys, zs = SBT.nodes_xyz(m); zc = m.hole.zc[1]
	segs = Point2f[]
	for (a, b) in SBT.edge_list(m)
		(xs[a] < 0.5 && xs[b] < 0.5 && zc - 100 <= zs[a] <= zc + 100 && zc - 100 <= zs[b] <= zc + 100) || continue
		push!(segs, Point2f(zs[a], ys[a])); push!(segs, Point2f(zs[b], ys[b]))
	end
	fig = Figure(size = (800, 420))
	ax = Axis(fig[1, 1]; aspect = DataAspect(), xlabel = "z [mm]", ylabel = "y [mm]", title = "$(getnnodes(m.grid)) nodes, $(getncells(m.grid)) shells (quadrilaterals + triangles) — web face at the first hole")
	linesegments!(ax, segs; color = :black, linewidth = 0.5)
	fig
end

# ╔═╡ a5986847-b35c-4af5-9009-c76fe53445b6
md"""
## 4. Eigenbuckling analysis
The steps (all in `stud_buckling_tools.jl`): Ferrite `DofHandler` with 6 dofs per node → elastic stiffness `K` from the shell package → unit end compression distributed by tributary length → linear static solve → element membrane stresses → geometric stiffness `Kg` → ARPACK solve of `K φ = P_cr (−Kg) φ` for the lowest modes, plus shift-and-invert windows to find the distortional and global modes among the many local ones.

Run the lowest-modes solve live (about one minute on a laptop, 250 000 dofs): $(@bind run_live CheckBox(default = false))
"""

# ╔═╡ b0deadf1-ded8-44a2-8c94-76388b45e367
live = if run_live
	let m = model, E = 200000.0, ν = 0.3, t = m.sec.t
		dh, n2d = SBT.setup_dofs(m)
		ch = SBT.constraints(m, dh, n2d)
		K = SBT.assemble_K(m, dh, ch, E, ν, t)
		F = SBT.end_loads(m, dh, n2d); apply!(K, F, ch)
		u = K \ F; apply!(u, ch)
		S = SBT.membrane_stresses(m, dh, u, E, ν, t)
		Kg = SBT.assemble_Kg(m, dh, ch, S, t)
		λ, V, tm = SBT.eigs_lowest(K, Kg; nev = 6, verbose = false)
		(; λ, V, dh, n2d, tm)
	end
else
	nothing
end

# ╔═╡ f711c801-a0cc-4304-a5c2-070e0b5e97f7
live === nothing ? md"*(live solve not run — tick the box above)*" : md"""
Lowest six buckling loads (live): $(join([@sprintf("%.2f kN", l/1000) for l in live.λ], ", ")).  LU $(round(live.tm.lu; digits = 1)) s, ARPACK $(round(live.tm.eigs; digits = 1)) s.
"""

# ╔═╡ d41164e5-1632-41c9-a3bd-2798e525098c
md"""
## 5. Characteristic buckling modes (saved results from the paper)
"""

# ╔═╡ 8c6768ba-acfe-4710-8861-85b076f95afe
modes = deserialize(joinpath(resdir, "modes_M1_$(element_choice).jls"))

# ╔═╡ 7f0f1f5d-24f5-4abe-829b-c664563d655c
@bind mode_name Select(collect(keys(modes.characteristic)))

# ╔═╡ 03afd11c-aa9c-4a1f-92e9-7ff22b2cab5d
@bind amplitude Slider(0.05:0.05:0.5; default = 0.25, show_value = true)

# ╔═╡ be4926ab-7e7b-4b7d-940a-f788e4b4d537
let m = model, d = modes
	dh, n2d = SBT.setup_dofs(m)
	k = d.characteristic[mode_name]; j = findfirst(==(k), d.scan_index)
	P = d.Pcr[j]; vec = d.Φ[:, j]; mm = d.metrics[j]
	xs, ys, zs = SBT.nodes_xyz(m); nn = length(xs)
	disp = [Point3f(vec[n2d[i][3]], vec[n2d[i][1]], vec[n2d[i][2]]) for i in 1:nn]
	mag = norm.(disp); mx = maximum(mag)
	s = Float32(amplitude * (maximum(ys) - minimum(ys)) / mx)
	pts = [Point3f(zs[i], xs[i], ys[i]) + s * disp[i] for i in 1:nn]
	fig = Figure(size = (900, 380))
	Label(fig[0, 1], @sprintf("%s: P_cr = %.2f kN (%.2f kips), f_cr = %.1f MPa — %s%s", mode_name, P/1000, P/SBT.N_PER_KIP, P/d.A, mm.class, mm.class == "global" ? " (" * mm.global_desc * ")" : ""); fontsize = 14, tellwidth = false)
	ax = LScene(fig[1, 1]; show_axis = false)
	mesh!(ax, pts, SBT.face_matrix(m); color = Float32.(mag ./ mx), colormap = :viridis, colorrange = (0, 1), shading = NoShading)
	fig
end

# ╔═╡ 30467e24-00e4-4eca-acb0-8a70be3e7146
md"""
Drag to orbit, scroll to zoom.  Colour is the normalized displacement magnitude; the deformation is scaled to `amplitude × section depth`.
"""

# ╔═╡ Cell order:
# ╠═4387e145-6ce2-40c2-8d43-f248af75d3c5
# ╠═501935d5-34ad-4155-bd78-ef318824f962
# ╠═77f7334c-4536-479e-93db-9baff8526cb5
# ╠═3123ad9c-5f28-4218-854f-6e5b42975797
# ╠═407a990f-c5f8-4fa5-a52a-087df05cc7cb
# ╠═0368d442-b1a2-4387-a1b0-3b1ec968edbc
# ╠═98ce2c38-b689-4037-b6e0-9101da1a508c
# ╠═9bdba767-51c4-4319-9c61-6163ca8bb170
# ╠═ca7999cf-d29c-459c-a7e8-44fd2bb3be5e
# ╠═ab6dbcf8-2325-4161-8e03-d6dac0e8e231
# ╠═0774a0de-960f-4508-a383-27f471ab85bb
# ╠═94705e4a-6ee3-48a8-994e-45e13ef451fd
# ╠═5378357c-976e-41a6-93bf-f18e9411128b
# ╠═a5986847-b35c-4af5-9009-c76fe53445b6
# ╠═b0deadf1-ded8-44a2-8c94-76388b45e367
# ╠═f711c801-a0cc-4304-a5c2-070e0b5e97f7
# ╠═d41164e5-1632-41c9-a3bd-2798e525098c
# ╠═8c6768ba-acfe-4710-8861-85b076f95afe
# ╠═7f0f1f5d-24f5-4abe-829b-c664563d655c
# ╠═03afd11c-aa9c-4a1f-92e9-7ff22b2cab5d
# ╠═be4926ab-7e7b-4b7d-940a-f788e4b4d537
# ╠═30467e24-00e4-4eca-acb0-8a70be3e7146
