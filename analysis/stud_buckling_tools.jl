# StudBucklingTools — shared code for the ICCFSS 2026 paper
# "Elastic buckling analysis of a cold-formed steel stud column with open-source shell finite element software"
# Moen and Shabhari (2026), RunToSolve LLC
#
# Shell finite elements: TriShellFiniteElement.jl (3-node Mindlin triangle) and QuadShellFiniteElement.jl
# (4-node Mindlin quadrilateral), assembled with Ferrite.jl.  Eigenbuckling: K φ = λ (-Kg) φ, ARPACK.
# Units: N, mm, MPa.  Conversions to kips/in only for reporting.
module StudBucklingTools

using Ferrite, Tensors, LinearAlgebra, SparseArrays, Statistics, Serialization, Printf
using LinearMaps, Arpack
using CrossSectionGeometry
import TriShellFiniteElement
import QuadShellFiniteElement
import Gmsh: gmsh

const TSFE = TriShellFiniteElement
const QSFE = QuadShellFiniteElement

export Section, section_362S162_33, build_stud_grid, load_model, StudModel
export setup_dofs, end_loads, constraints, assemble_K, membrane_stresses, assemble_Kg, sigma_zz_normalized, subhandlers
export eigs_lowest, eigs_shift, classify_modes, ModeMetrics, rigid_body_description
export N_PER_KIP, MPA_PER_KSI, kN, kips, MPa, ksi

const N_PER_KIP   = 4448.2216152605
const MPA_PER_KSI = 6.894757
kN(P)   = P / 1000
kips(P) = P / N_PER_KIP
MPa(f)  = f
ksi(f)  = f / MPA_PER_KSI

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Cross-section polyline
# ═══════════════════════════════════════════════════════════════════════════════
"""
Centerline polyline of a lipped channel built from CrossSectionGeometry.jl.
Node 1 is the tip of the first lip; the polyline runs lip → corner → flange → corner → web → corner → flange → corner → lip.
The web lies in the plane x = 0 (min x); the lips are at max x; z is the member axis.
"""
struct Section
    X::Vector{Float64}
    Y::Vector{Float64}
    t::Float64
    k::Int                        # subdivision factor of the base discretization n = k*[2,10,10,10,2]
    web_range::UnitRange{Int}     # node indices of the web flat (tangent point to tangent point)
    web_center::Int               # node at web mid-depth
    wf_corners::Tuple{Int,Int}    # web-flange corner arc mid-nodes
    fl_corners::Tuple{Int,Int}    # flange-lip corner arc mid-nodes
    tips::Tuple{Int,Int}          # lip tip nodes (free ends)
    A::Float64                    # centerline area = t × perimeter
    seg_len::Vector{Float64}      # polyline segment lengths
end

"""
    section_362S162_33(; k = 2, t = 0.0346*25.4, r_center = 2t)

362S162-33 stud: lip 12.7, flange 41.3, web 92.1 mm (out-to-out centerline flats as in the prior runs),
t = 0.87884 mm, centerline corner radius 2t with 4 elements per arc; k*[2,10,10,10,2] elements on the flats.
"""
function section_362S162_33(; k::Int = 2, t::Float64 = 0.0346 * 25.4, r_center::Float64 = 2 * 0.0346 * 25.4,
                              L = [12.7, 41.3, 92.1, 41.3, 12.7], n_r = 4)
    θ = [-π/2, π, π/2, 0.0, -π/2]
    n = k .* [2, 10, 10, 10, 2]
    cs = CrossSectionGeometry.create_thin_walled_cross_section_geometry(L, θ, n, fill(r_center, 4), fill(n_r, 4), t;
                                                                        centerline = "to right", offset = (0.0, 0.0))
    X = Float64[p[1] for p in cs.centerline_node_XY]
    Y = Float64[p[2] for p in cs.centerline_node_XY]
    X .-= minimum(X); Y .-= minimum(Y)
    nn_expected = sum(n) + 4n_r + 1
    @assert length(X) == nn_expected "section has $(length(X)) nodes, expected $(nn_expected)"
    # index bookkeeping along the polyline
    i = 1
    lip1_end   = i + n[1];        arc1_mid = lip1_end + n_r ÷ 2;  arc1_end = lip1_end + n_r
    fl1_end    = arc1_end + n[2]; arc2_mid = fl1_end + n_r ÷ 2;   arc2_end = fl1_end + n_r
    web_start  = arc2_end;        web_end  = web_start + n[3];    arc3_mid = web_end + n_r ÷ 2; arc3_end = web_end + n_r
    fl2_end    = arc3_end + n[4]; arc4_mid = fl2_end + n_r ÷ 2;   arc4_end = fl2_end + n_r
    lip2_end   = arc4_end + n[5]
    @assert lip2_end == length(X)
    @assert all(abs.(X[web_start:web_end]) .< 0.01) "web flat is not at x = 0 (max |x| = $(maximum(abs.(X[web_start:web_end]))))"
    X[web_start:web_end] .= 0.0                       # snap the web flat exactly onto x = 0 (CrossSectionGeometry leaves a ~0.002 mm offset)
    Y[web_start:web_end] .= range(Y[web_start], Y[web_end]; length = n[3] + 1)   # uniform web nodes so Gmsh transfinite patch edges coincide
    web_center = web_start + n[3] ÷ 2
    seg_len = [hypot(X[j+1] - X[j], Y[j+1] - Y[j]) for j in 1:length(X)-1]
    A = t * sum(seg_len)
    return Section(X, Y, t, k, web_start:web_end, web_center, (arc2_mid, arc3_mid), (arc1_mid, arc4_mid), (1, lip2_end), A, seg_len)
end

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Stud grid: structured extrusion + Gmsh hole patches on the web
# ═══════════════════════════════════════════════════════════════════════════════
"""
Everything needed downstream, serialized to meshes/*.jls.
`sid[s, p+1]` is the grid node id of section node s on plane p (0 = removed inside a hole patch).
"""
struct StudModel
    grid::Ferrite.Grid
    sec::Section
    element::Symbol               # :tri, :quad, or :mixed (quadrilaterals in the structured flats, triangles in the hole patches)
    L::Float64
    dz::Float64
    nz::Int
    planes_z::Vector{Float64}     # z of every structured plane (length nz+1)
    sid::Matrix{Int}              # ns × (nz+1)
    full_plane::Vector{Bool}      # plane has all section nodes present
    hole::NamedTuple              # (w, ℓ, spacing, zc = [...])
    patch_nodes::Vector{Int}      # grid node ids inside the hole patches (unstructured region)
    patch_zrange::Vector{Tuple{Float64,Float64}}
    tag::String
end

nodes_xyz(m::StudModel) = ([n.x[1] for n in m.grid.nodes], [n.x[2] for n in m.grid.nodes], [n.x[3] for n in m.grid.nodes])

"""
    build_stud_grid(sec; L = 2438.4, dz = 5.0, element = :tri, hole = (w = 38.1, ℓ = 101.6, spacing = 609.6),
                    patch_half = 75.0, tag = "M1")

Structured extrusion of the section polyline with nz planes (nz a multiple of 8 so that nodal planes fall on the
hole centres L/8, 3L/8, 5L/8, 7L/8 and on the brace plane L/2), then each web region within ±patch_half of a hole
centre is removed and re-meshed by Gmsh in 2D (rectangle with a true stadium hole) and stitched back.
Set `hole = nothing` for an unperforated stud.
"""
function build_stud_grid(sec::Section; L = 2438.4, dz = 5.0, element::Symbol = :tri,
                         hole = (w = 38.1, ℓ = 101.6, spacing = 609.6), patch_half = 75.0, tag = "M1",
                         quad_algorithm = 11, verbose = true)
    @assert element in (:tri, :quad, :mixed)
    patch_element = element == :mixed ? :tri : element          # unstructured hole patches are triangles in the mixed model
    ns = length(sec.X)
    nz = 8 * max(1, round(Int, L / (8dz)))
    dz_act = L / nz
    planes_z = [L * p / nz for p in 0:nz]
    # structured nodes
    sid = zeros(Int, ns, nz + 1)
    nodes = Ferrite.Node{3,Float64}[]
    for p in 0:nz, s in 1:ns
        push!(nodes, Ferrite.Node(Ferrite.Vec(sec.X[s], sec.Y[s], planes_z[p+1])))
        sid[s, p+1] = length(nodes)
    end
    # hole centres and patch planes
    zc = Float64[]
    if hole !== nothing
        nh = max(1, round(Int, L / hole.spacing))
        z_first = (L - (nh - 1) * hole.spacing) / 2
        zc = [z_first + (i - 1) * hole.spacing for i in 1:nh]
    end
    np = round(Int, patch_half / dz_act)
    pc = [round(Int, z / dz_act) for z in zc]
    for (i, z) in enumerate(zc)
        @assert abs(planes_z[pc[i]+1] - z) < 1e-6 "hole centre $(z) is not on a nodal plane (dz = $(dz_act))"
    end
    ws, we = first(sec.web_range), last(sec.web_range)
    in_patch(s, p) = any(abs(p - pci) <= np for pci in pc) && ws <= s < we      # cell column s (nodes s, s+1) on plane interval p
    patch_zrange = [(planes_z[pci-np+1], planes_z[pci+np+1]) for pci in pc]
    # structured cells
    cells = element == :tri ? Ferrite.Triangle[] : element == :quad ? Ferrite.Quadrilateral[] : Union{Ferrite.Triangle,Ferrite.Quadrilateral}[]
    for p in 0:nz-1, s in 1:ns-1
        (hole !== nothing && any(-np <= p - pci < np for pci in pc) && ws <= s < we) && continue   # cell row between planes p and p+1 lies inside the patch [pci-np, pci+np]
        n1, n2, n3, n4 = sid[s, p+1], sid[s+1, p+1], sid[s+1, p+2], sid[s, p+2]
        if element == :tri
            push!(cells, Ferrite.Triangle((n1, n2, n3))); push!(cells, Ferrite.Triangle((n1, n3, n4)))
        else
            push!(cells, Ferrite.Quadrilateral((n1, n2, n3, n4)))
        end
    end
    # hole patches
    patch_nodes = Int[]
    pn_rel = Tuple{Float64,Float64}[]; pc_cells = Vector{Vector{Int}}()
    if hole !== nothing
        for (i, pci) in enumerate(pc)
            p_lo, p_hi = pci - np, pci + np
            u_lo, u_hi = sec.Y[ws], sec.Y[we]
            v_lo, v_hi = planes_z[p_lo+1], planes_z[p_hi+1]
            key = Dict{Tuple{Float64,Float64},Int}()
            for p in p_lo:p_hi, s in ws:we
                key[(round(sec.Y[s]; digits = 2), round(planes_z[p+1]; digits = 2))] = sid[s, p+1]
            end
            function lookup(u, v)   # tolerant match (structured nodes are ≥ 2 mm apart)
                for du in (0.0, 0.01, -0.01), dv in (0.0, 0.01, -0.01)
                    k = (round(u + du; digits = 2), round(v + dv; digits = 2))
                    if haskey(key, k)
                        q = key[k]
                        abs(nodes[q].x[2] - u) < 1e-3 && abs(nodes[q].x[3] - v) < 1e-3 && return q
                    end
                end
                return 0
            end
            # mesh the patch once (relative to the hole centre) and replicate it at every hole so all holes are identical
            if i == 1
                pn_rel, pc_cells = gmsh_patch(u_lo, u_hi, v_lo - zc[1], v_hi - zc[1], (u_lo + u_hi) / 2, 0.0, hole.w, hole.ℓ,
                                              we - ws, p_hi - p_lo, dz_act, patch_element; quad_algorithm, verbose)
            end
            pn = [(u, v + zc[i]) for (u, v) in pn_rel]
            # map patch nodes → grid node ids (boundary nodes coincide with structured nodes)
            local_to_grid = zeros(Int, length(pn))
            nb = 0
            for (j, (u, v)) in enumerate(pn)
                q = lookup(u, v)
                if q > 0
                    local_to_grid[j] = q; nb += 1
                else
                    push!(nodes, Ferrite.Node(Ferrite.Vec(0.0, u, v)))
                    local_to_grid[j] = length(nodes)
                    push!(patch_nodes, length(nodes))
                end
            end
            for c in pc_cells
                ids = local_to_grid[collect(c)]
                # orientation: normal must point to +x (u × v = y × z = x)
                P = [nodes[q].x for q in ids]
                nrm = cross(P[2] - P[1], P[3] - P[1])
                nrm[1] < 0 && reverse!(ids)
                push!(cells, patch_element == :tri ? Ferrite.Triangle(Tuple(ids)) : Ferrite.Quadrilateral(Tuple(ids)))
            end
            # structured web nodes strictly inside the patch are now orphaned; mark removed
            for p in p_lo+1:p_hi-1, s in ws+1:we-1
                sid[s, p+1] = 0
            end
            nb_expected = 2 * (we - ws + 1) + 2 * (p_hi - p_lo + 1) - 4
            @assert nb == nb_expected "hole $(i): $(nb) patch boundary nodes matched the structured grid, expected $(nb_expected)"
            verbose && println("  hole $(i) at z = $(zc[i]) mm: patch z ∈ [$(v_lo), $(v_hi)], $(length(pn)) patch nodes ($(nb) shared), $(length(pc_cells)) $(patch_element) cells")
        end
    end
    # compact node numbering (drop orphaned nodes)
    used = falses(length(nodes))
    for c in cells, q in c.nodes; used[q] = true; end
    newid = cumsum(used)
    nodes2 = nodes[used]
    remap(c::Ferrite.Triangle) = Ferrite.Triangle(Tuple(newid[q] for q in c.nodes))
    remap(c::Ferrite.Quadrilateral) = Ferrite.Quadrilateral(Tuple(newid[q] for q in c.nodes))
    cells2 = element == :mixed ? Union{Ferrite.Triangle,Ferrite.Quadrilateral}[remap(c) for c in cells] : [remap(c) for c in cells]
    sid2 = [ (v == 0 || !used[v]) ? 0 : newid[v] for v in sid ]
    patch_nodes2 = [newid[v] for v in patch_nodes if used[v]]
    # also count the structured web nodes that sit on patch interiors as patch nodes (none remain by construction)
    full_plane = [all(sid2[:, p] .> 0) for p in 1:nz+1]
    grid = Ferrite.Grid(cells2, nodes2)
    model = StudModel(grid, sec, element, L, dz_act, nz, planes_z, sid2, full_plane,
                      (w = hole === nothing ? 0.0 : hole.w, ℓ = hole === nothing ? 0.0 : hole.ℓ,
                       spacing = hole === nothing ? 0.0 : hole.spacing, zc = zc),
                      patch_nodes2, patch_zrange, tag)
    ntri = count(c -> c isa Ferrite.Triangle, cells2); nquad = length(cells2) - ntri
    verbose && println("Grid $(tag) ($(element)): $(length(nodes2)) nodes, $(length(cells2)) cells ($(nquad) quadrilaterals, $(ntri) triangles), $(ns) section nodes × $(nz+1) planes, dz = $(round(dz_act; digits = 4)) mm, $(count(full_plane)) full planes")
    return model
end

"""
2D Gmsh mesh of the web patch rectangle [u_lo,u_hi]×[v_lo,v_hi] with a stadium hole (width w across u,
length ℓ along v) centred at (uc, vc).  Returns node (u,v) list and cell connectivity (1-based, local).
Transfinite node counts on the outer edges equal the structured grid (n_u, n_v elements).
"""
function gmsh_patch(u_lo, u_hi, v_lo, v_hi, uc, vc, w, ℓ, n_u, n_v, h, element; quad_algorithm = 11, verbose = true)
    gmsh.initialize()
    gmsh.option.setNumber("General.Terminal", 0)
    gmsh.model.add("patch")
    occ = gmsh.model.occ
    p1 = occ.addPoint(u_lo, v_lo, 0); p2 = occ.addPoint(u_hi, v_lo, 0); p3 = occ.addPoint(u_hi, v_hi, 0); p4 = occ.addPoint(u_lo, v_hi, 0)
    l1 = occ.addLine(p1, p2); l2 = occ.addLine(p2, p3); l3 = occ.addLine(p3, p4); l4 = occ.addLine(p4, p1)
    outer = occ.addCurveLoop([l1, l2, l3, l4])
    r = w / 2; a = ℓ / 2 - r                       # half-length of the straight part
    q1 = occ.addPoint(uc + r, vc - a, 0); q2 = occ.addPoint(uc + r, vc + a, 0)
    q3 = occ.addPoint(uc - r, vc + a, 0); q4 = occ.addPoint(uc - r, vc - a, 0)
    c_top = occ.addPoint(uc, vc + a, 0); c_bot = occ.addPoint(uc, vc - a, 0)
    ap_top = occ.addPoint(uc, vc + a + r, 0); ap_bot = occ.addPoint(uc, vc - a - r, 0)   # arc apexes
    h1 = occ.addLine(q1, q2)                       # straight edge at u = uc + r
    h2a = occ.addCircleArc(q2, c_top, ap_top)      # semicircle at v = vc + a as two 90° arcs (a single 180° arc is ambiguous in OCC)
    h2b = occ.addCircleArc(ap_top, c_top, q3)
    h3 = occ.addLine(q3, q4)                       # straight edge at u = uc - r
    h4a = occ.addCircleArc(q4, c_bot, ap_bot)
    h4b = occ.addCircleArc(ap_bot, c_bot, q1)
    inner = occ.addCurveLoop([h1, h2a, h2b, h3, h4a, h4b])
    surf = occ.addPlaneSurface([outer, inner])
    occ.synchronize()
    mesh = gmsh.model.mesh
    mesh.setTransfiniteCurve(l1, n_u + 1); mesh.setTransfiniteCurve(l3, n_u + 1)
    mesh.setTransfiniteCurve(l2, n_v + 1); mesh.setTransfiniteCurve(l4, n_v + 1)
    n_straight = max(2, round(Int, 2a / h)); n_quarter = max(2, round(Int, π * r / 2 / h))
    isodd(n_straight) && (n_straight += 1)        # even boundary edge count on the hole loop (all-quad recombination)
    mesh.setTransfiniteCurve(h1, n_straight + 1); mesh.setTransfiniteCurve(h3, n_straight + 1)
    for c in (h2a, h2b, h4a, h4b); mesh.setTransfiniteCurve(c, n_quarter + 1); end
    gmsh.option.setNumber("Mesh.MeshSizeMin", 0.8h)
    gmsh.option.setNumber("Mesh.MeshSizeMax", 1.2h)
    gmsh.option.setNumber("Mesh.MeshSizeFromCurvature", 0)
    gmsh.option.setNumber("Mesh.MeshSizeExtendFromBoundary", 1)
    if element == :quad
        gmsh.option.setNumber("Mesh.Algorithm", quad_algorithm)
        gmsh.option.setNumber("Mesh.RecombineAll", 1)
        gmsh.option.setNumber("Mesh.RecombinationAlgorithm", 1)
        mesh.setRecombine(2, surf)
    else
        gmsh.option.setNumber("Mesh.Algorithm", 6)
        gmsh.option.setNumber("Mesh.RecombineAll", 0)
    end
    mesh.generate(2)
    if element == :quad
        types, _, _ = mesh.getElements(2)
        if !(length(types) == 1 && types[1] == 3)
            verbose && println("  quad algorithm $(quad_algorithm) left non-quad elements; retrying with Frontal-Delaunay for quads + Blossom")
            mesh.clear()
            gmsh.option.setNumber("Mesh.Algorithm", 8)
            gmsh.option.setNumber("Mesh.RecombinationAlgorithm", 1)
            mesh.generate(2)
        end
    end
    tags, coords, _ = mesh.getNodes()
    t2i = Dict(tg => i for (i, tg) in enumerate(tags))
    pn = [(coords[3i-2], coords[3i-1]) for i in 1:length(tags)]
    types, _, conns = mesh.getElements(2)
    cells = Vector{Vector{Int}}()
    want = element == :tri ? 2 : 3
    nper = element == :tri ? 3 : 4
    for (ty, cn) in zip(types, conns)
        ty == want || error("gmsh produced element type $(ty) in the $(element) patch (want $(want)); use the mixed-grid fallback")
        for q in 1:div(length(cn), nper)
            push!(cells, [t2i[cn[nper*(q-1)+j]] for j in 1:nper])
        end
    end
    gmsh.finalize()
    return pn, cells
end

save_model(m::StudModel, path) = serialize(path, m)
load_model(path) = deserialize(path)::StudModel

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Dofs, loads, constraints
# ═══════════════════════════════════════════════════════════════════════════════
"""
    setup_dofs(m) -> (dh, node_to_dofs)

Ferrite DofHandler with a translation field :u and a rotation field :θ (3 components each) on every node.  A mixed grid
gets one SubDofHandler per element type (Lagrange{RefQuadrilateral,1} / Lagrange{RefTriangle,1}); nodes shared by the
two element types share their dofs.  `node_to_dofs[n]` lists [ux uy uz θx θy θz] of node n.
"""
function setup_dofs(m::StudModel)
    dh = DofHandler(m.grid)
    tri_ids  = Set(i for (i, c) in enumerate(m.grid.cells) if c isa Ferrite.Triangle)
    quad_ids = Set(i for (i, c) in enumerate(m.grid.cells) if c isa Ferrite.Quadrilateral)
    if !isempty(quad_ids)
        sdh = SubDofHandler(dh, quad_ids); ip = Lagrange{RefQuadrilateral,1}()
        add!(sdh, :u, ip^3); add!(sdh, :θ, ip^3)
    end
    if !isempty(tri_ids)
        sdh = SubDofHandler(dh, tri_ids); ip = Lagrange{RefTriangle,1}()
        add!(sdh, :u, ip^3); add!(sdh, :θ, ip^3)
    end
    close!(dh)
    node_to_dofs = Dict{Int,Vector{Int}}()
    for (sdh, ty) in subhandlers(dh)
        nn_cell = ty == :tri ? 3 : 4
        for cell in CellIterator(sdh)
            cd = celldofs(cell)
            for (i, node) in enumerate(cell.nodes)
                haskey(node_to_dofs, node) && continue
                node_to_dofs[node] = [cd[3(i-1)+1], cd[3(i-1)+2], cd[3(i-1)+3],
                                      cd[3nn_cell+3(i-1)+1], cd[3nn_cell+3(i-1)+2], cd[3nn_cell+3(i-1)+3]]
            end
        end
    end
    return dh, node_to_dofs
end

"The (SubDofHandler, :tri | :quad) pairs of a DofHandler."
function subhandlers(dh)
    out = Tuple{Any,Symbol}[]
    for sdh in dh.subdofhandlers
        c = getcells(dh.grid, first(sdh.cellset))
        push!(out, (sdh, c isa Ferrite.Triangle ? :tri : :quad))
    end
    return out
end

"Tributary centerline lengths of the section nodes (for uniform end compression)."
function tributary(sec::Section)
    ns = length(sec.X)
    trib = zeros(ns)
    for j in 1:ns-1
        trib[j] += sec.seg_len[j] / 2; trib[j+1] += sec.seg_len[j] / 2
    end
    return trib
end

"Reference load: P_ref = 1 N uniform compression at both ends, distributed by tributary length. Eigenvalue = P_cr [N]."
function end_loads(m::StudModel, dh, node_to_dofs)
    trib = tributary(m.sec); tot = sum(trib)
    F = zeros(ndofs(dh))
    for s in 1:length(m.sec.X)
        F[node_to_dofs[m.sid[s, 1]][3]]      += trib[s] / tot       # bottom end pushes +z
        F[node_to_dofs[m.sid[s, end]][3]]    -= trib[s] / tot       # top end pushes -z
    end
    return F
end

"""
    constraints(m, dh, node_to_dofs; brace = :affine)

Pinned, warping-free ends: ux = uy = 0 at every end node, uz free.
Midheight brace (z = L/2), default `brace = :corners_x`: ux = 0 at both web-flange corner nodes (translation
perpendicular to the web and twist restrained through the stiff corners), uy = 0 at the web-centre node (translation
along the web; the web is stiff in its plane and the node lies on the symmetry axis so no prebuckling stress is induced),
uz = 0 at the web-centre node (axial datum).  Restraining only the web-centre node (`brace = :affine`: ux = uy = 0 there
plus equal ux at the corners) does NOT brace the section: the thin web simply dimples around the point restraint and the
section translates as a whole (found in the first M1 runs).  `brace = :corners` fixes ux = uy at both corners;
`brace = :none` applies only the axial datum.
"""
function constraints(m::StudModel, dh, node_to_dofs; brace::Symbol = :corners_x)
    ns = length(m.sec.X)
    bottom = Set(m.sid[:, 1]); top = Set(m.sid[:, end])
    p_mid = m.nz ÷ 2 + 1
    @assert m.full_plane[p_mid] "brace plane is not a full structured plane"
    wc = m.sid[m.sec.web_center, p_mid]
    c1, c2 = m.sid[m.sec.wf_corners[1], p_mid], m.sid[m.sec.wf_corners[2], p_mid]
    ch = ConstraintHandler(dh)
    add!(ch, Dirichlet(:u, bottom, (x, t) -> [0.0, 0.0], [1, 2]))
    add!(ch, Dirichlet(:u, top,    (x, t) -> [0.0, 0.0], [1, 2]))
    if brace == :none
        add!(ch, Dirichlet(:u, Set([wc]), (x, t) -> [0.0], [3]))
    elseif brace == :affine
        add!(ch, Dirichlet(:u, Set([wc]), (x, t) -> [0.0, 0.0, 0.0], [1, 2, 3]))
        add!(ch, AffineConstraint(node_to_dofs[c2][1], [node_to_dofs[c1][1] => 1.0], 0.0))
    elseif brace == :corners_x
        add!(ch, Dirichlet(:u, Set([wc]), (x, t) -> [0.0, 0.0], [2, 3]))
        add!(ch, Dirichlet(:u, Set([c1, c2]), (x, t) -> [0.0], [1]))
    elseif brace == :corners
        add!(ch, Dirichlet(:u, Set([wc]), (x, t) -> [0.0], [3]))
        add!(ch, Dirichlet(:u, Set([c1, c2]), (x, t) -> [0.0, 0.0], [1, 2]))
    else
        error("unknown brace option $(brace)")
    end
    close!(ch)
    return ch
end

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Assembly: elastic stiffness, membrane stresses, geometric stiffness
# ═══════════════════════════════════════════════════════════════════════════════
const QR_TRI1 = QuadratureRule{RefTriangle}(1)
const QR_TRI3 = QuadratureRule{RefTriangle}(2)
const QR_Q2   = QuadratureRule{RefQuadrilateral}(2)
const QR_Q3   = QuadratureRule{RefQuadrilateral}(3)

default_Cs(ty::Symbol) = ty == :tri ? TSFE.DEFAULT_SHEAR_RELAXATION : QSFE.DEFAULT_SHEAR_RELAXATION
Cs_string(m::StudModel) = m.element == :mixed ? "tri $(TSFE.DEFAULT_SHEAR_RELAXATION), quad $(QSFE.DEFAULT_SHEAR_RELAXATION)" : string(default_Cs(m.element))

"""
    assemble_K(m, dh, ch, E, ν, t; Cs_tri, Cs_quad)

Elastic stiffness.  Each element type is assembled by its own package through its SubDofHandler into a matrix with the
full sparsity pattern (`start_assemble` zeroes the target), and the matrices are summed.
"""
function assemble_K(m::StudModel, dh, ch, E, ν, t; Cs_tri = TSFE.DEFAULT_SHEAR_RELAXATION, Cs_quad = QSFE.DEFAULT_SHEAR_RELAXATION)
    K = allocate_matrix(dh, ch)
    for (sdh, ty) in subhandlers(dh)
        Ks = allocate_matrix(dh, ch)
        if ty == :tri
            Ks = TSFE.assemble_global_Ke!(Ks, sdh, QR_TRI1, QR_TRI3, TSFE.IP3(), TSFE.IP6(), E, ν, t; Cs = Cs_tri)
        else
            Ks = QSFE.assemble_global_Ke!(Ks, sdh, QR_Q2, QR_Q3, QSFE.IP4(), QSFE.IP6(), E, ν, t; Cs = Cs_quad)
        end
        K.nzval .+= Ks.nzval
    end
    return K
end

"""
    membrane_stresses(m, dh, u, E, ν, t) -> Vector of (sdh, ty, cellids, σXX, σYY, τXY)

Element membrane stresses (MPa) in the element local frame, one entry per SubDofHandler in its iteration order
(the order the packages' `assemble_global_Kg!` expect).  Triangles: constant per element (1-point rule);
quadrilaterals: per Gauss point (2×2).
"""
function membrane_stresses(m::StudModel, dh, u, E, ν, t)
    out = Any[]
    for (sdh, ty) in subhandlers(dh)
        cellids = Int[]
        if ty == :tri
            D = TSFE.calculate_membrane_constitutive_matrix(E, ν, t) / t
            cv = CellValues(QR_TRI1, TSFE.IP3(), TSFE.IP3())
            σXX = Float64[]; σYY = Float64[]; τXY = Float64[]
            B = zeros(3, 6); ul = zeros(6)
            for cell in CellIterator(sdh)
                xg = getcoordinates(cell)
                T = TSFE.calculation_rotation_matrix(xg)
                xl = TSFE.global_nodal_coords_to_planar_coords(xg, T)
                reinit!(cv, xl)
                cd = celldofs(cell)
                for i in 1:3
                    dN = shape_gradient(cv, 1, i)
                    B[1, 2i-1] = dN[1]; B[2, 2i] = dN[2]; B[3, 2i-1] = dN[2]; B[3, 2i] = dN[1]
                    uloc = T' * [u[cd[3(i-1)+k]] for k in 1:3]
                    ul[2i-1] = uloc[1]; ul[2i] = uloc[2]
                end
                σ = D * B * ul
                push!(σXX, σ[1]); push!(σYY, σ[2]); push!(τXY, σ[3]); push!(cellids, cellid(cell))
            end
            push!(out, (sdh = sdh, ty = ty, cellids = cellids, σXX = σXX, σYY = σYY, τXY = τXY))
        else
            D = QSFE.calculate_membrane_constitutive_matrix(E, ν, t) ./ t
            cv = CellValues(QR_Q2, QSFE.IP4(), QSFE.IP4())
            nq = getnquadpoints(cv)
            σXX = Vector{Float64}[]; σYY = Vector{Float64}[]; τXY = Vector{Float64}[]
            B = zeros(3, 8); ul = zeros(8)
            for cell in CellIterator(sdh)
                xg = getcoordinates(cell)
                T = QSFE.calculation_rotation_matrix(xg)
                xl = QSFE.global_nodal_coords_to_planar_coords(xg, T)
                reinit!(cv, xl)
                cd = celldofs(cell)
                for i in 1:4
                    uloc = T' * [u[cd[3(i-1)+k]] for k in 1:3]
                    ul[2i-1] = uloc[1]; ul[2i] = uloc[2]
                end
                sx = zeros(nq); sy = zeros(nq); sxy = zeros(nq)
                for q in 1:nq
                    for i in 1:4
                        dN = shape_gradient(cv, q, i)
                        B[1, 2i-1] = dN[1]; B[2, 2i] = dN[2]; B[3, 2i-1] = dN[2]; B[3, 2i] = dN[1]
                    end
                    σ = D * B * ul
                    sx[q] = σ[1]; sy[q] = σ[2]; sxy[q] = σ[3]
                end
                push!(σXX, sx); push!(σYY, sy); push!(τXY, sxy); push!(cellids, cellid(cell))
            end
            push!(out, (sdh = sdh, ty = ty, cellids = cellids, σXX = σXX, σYY = σYY, τXY = τXY))
        end
    end
    return out
end

"Geometric stiffness from stress resultants σ·t (summed over element types); constrained rows/cols zeroed."
function assemble_Kg(m::StudModel, dh, ch, S, t)
    Kg = allocate_matrix(dh, ch)
    st(x) = x isa AbstractVector ? x .* t : x * t
    for e in S
        Kgs = allocate_matrix(dh, ch)
        NXX = [st(v) for v in e.σXX]; NYY = [st(v) for v in e.σYY]; NXY = [st(v) for v in e.τXY]
        if e.ty == :tri
            Kgs = TSFE.assemble_global_Kg!(Kgs, e.sdh, QR_TRI1, TSFE.IP3(), NXX, NYY, NXY)
        else
            Kgs = QSFE.assemble_global_Kg!(Kgs, e.sdh, QR_Q2, QSFE.IP4(), NXX, NYY, NXY)
        end
        Kg.nzval .+= Kgs.nzval
    end
    apply!(Kg, ch)
    for d in ch.prescribed_dofs; Kg[d, d] = 0.0; end
    return Kg
end

"Longitudinal membrane stress σ_zz of every element (by global cell id) normalized by P/A (uniform compression → -1)."
function sigma_zz_normalized(m::StudModel, dh, S, P_over_A)
    nc = getncells(m.grid)
    σzz = zeros(nc); zc = zeros(nc); xc = zeros(nc); yc = zeros(nc)
    avg(x) = x isa AbstractVector ? mean(x) : x
    for e in S
        rot = e.ty == :tri ? TSFE.calculation_rotation_matrix : QSFE.calculation_rotation_matrix
        for (i, cell) in enumerate(CellIterator(e.sdh))
            xg = getcoordinates(cell); T = rot(xg); c = e.cellids[i]
            sl = [avg(e.σXX[i]) avg(e.τXY[i]) 0.0; avg(e.τXY[i]) avg(e.σYY[i]) 0.0; 0.0 0.0 0.0]
            σzz[c] = (T * sl * T')[3, 3] / P_over_A
            zc[c] = mean(p[3] for p in xg); xc[c] = mean(p[1] for p in xg); yc[c] = mean(p[2] for p in xg)
        end
    end
    return σzz, xc, yc, zc
end

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Eigenvalue solves  K φ = λ (-Kg) φ
# ═══════════════════════════════════════════════════════════════════════════════
"Sparse symmetric factorization: Cholesky (CHOLMOD) for the positive definite K, LDLᵀ for the indefinite shifted matrix."
function factorize_spd(K)
    S = Symmetric(K)
    try
        return cholesky(S)
    catch
        return ldlt(S)
    end
end

"Lowest `nev` buckling loads via ARPACK on the operator K⁻¹(-Kg) (one CHOLMOD factorization of K serves all iterations)."
function eigs_lowest(K, Kg; nev = 12, tol = 1e-8, maxiter = 3000, verbose = true)
    t0 = time()
    Kfac = factorize_spd(K)
    verbose && println("  Factorization of K: $(round(time() - t0; digits = 1)) s")
    tmp = zeros(size(K, 1))
    op!(y, x) = (mul!(tmp, Kg, x); @. tmp = -tmp; y .= Kfac \ tmp)
    A = LinearMap(op!, size(K, 1); ismutating = true)
    t1 = time()
    μ, V, nconv, niter, nmult = eigs(A; nev, ncv = max(20, 4nev), which = :LM, tol, maxiter)
    λ = real.(1.0 ./ μ)
    o = sortperm(λ)
    verbose && println("  ARPACK: $(nconv) converged in $(niter) iterations, $(nmult) operator applications, $(round(time() - t1; digits = 1)) s")
    return λ[o], real.(V[:, o]), (lu = time() - t0, eigs = time() - t1)
end

"Buckling loads near a target load σ [N] via shift-and-invert: (K + σKg)⁻¹(-Kg), LDLᵀ factorization of the shifted matrix."
function eigs_shift(K, Kg, σ; nev = 40, ncv = max(60, 2nev + 10), tol = 1e-8, maxiter = 3000, verbose = true)
    t0 = time()
    Mfac = ldlt(Symmetric(K + σ * Kg))
    tmp = zeros(size(K, 1))
    op!(y, x) = (mul!(tmp, Kg, x); @. tmp = -tmp; y .= Mfac \ tmp)
    A = LinearMap(op!, size(K, 1); ismutating = true)
    ν, V, nconv = eigs(A; nev, ncv, which = :LM, tol, maxiter)
    λ = σ .+ 1.0 ./ real.(ν)
    o = sortperm(λ)
    verbose && println("  shift $(round(σ/1000; digits = 1)) kN: $(nconv) modes in [$(round(minimum(λ)/1000; digits = 2)), $(round(maximum(λ)/1000; digits = 2))] kN  ($(round(time() - t0; digits = 1)) s)")
    return λ[o], real.(V[:, o])
end

"Merge eigenpairs from several solves, dropping duplicates (relative tolerance 1e-6)."
function merge_modes(pairs...)
    λ_all = Float64[]; Φ_all = Vector{Vector{Float64}}()
    for (λ, V) in pairs, k in eachindex(λ)
        any(abs.(λ_all .- λ[k]) .< 1e-6 * λ[k]) && continue
        push!(λ_all, λ[k]); push!(Φ_all, V[:, k])
    end
    o = sortperm(λ_all)
    return λ_all[o], Φ_all[o]
end

# ═══════════════════════════════════════════════════════════════════════════════
# 6. Mode classification (local / distortional / global) on the structured planes
# ═══════════════════════════════════════════════════════════════════════════════
struct ModeMetrics
    class::String
    rb_frac::Float64          # rigid-body energy fraction of the in-plane section displacements
    wf::Float64               # web-flange corner displacement ratio (max over planes / max in-plane displacement)
    fl::Float64               # flange-lip corner ratio
    tip::Float64              # lip tip ratio
    hole_frac::Float64        # fraction of translational energy inside the hole patches
    hole_ratio::Float64       # max |u| inside the hole patches / max |u| on the structured planes
    hw_web::Int               # half-waves along the web centre line (full planes only)
    hw_tip::Int               # half-waves along the lip tip line
    hw_tip_seg::Tuple{Int,Int}   # lip-tip half-waves in the bottom / top 48 in segments
    global_desc::String
end

"""
    classify_modes(m, dh, node_to_dofs, Φ; rb_global = 0.6, fl_dist = 0.35, wf_dist = 0.25)

"local-hole" if the largest displacement inside the hole patches exceeds `hole_local` (2.0) times the largest
displacement on the structured planes (the web strips beside the holes buckle in these modes); otherwise global if the
rigid-body fraction on the structured planes > 0.6; distortional if the flange-lip corners move (> 0.5 of the maximum
in-plane displacement) while the web-flange corners stay (< 0.25); local otherwise.  (The prior 48 in study used 0.35
for the flange-lip ratio; 0.5 excludes the many higher web-local modes with some flange participation.)
"""
function classify_modes(m::StudModel, dh, node_to_dofs, Φ::AbstractVector; rb_global = 0.6, fl_dist = 0.5, wf_dist = 0.25, hole_local = 2.0)
    xs, ys, zs = nodes_xyz(m)
    nn = length(xs); ns = length(m.sec.X)
    full = findall(m.full_plane)
    sec_nodes = m.sid[:, 1]
    xc, yc = mean(xs[sec_nodes]), mean(ys[sec_nodes])
    Arb = zeros(2ns, 3)
    for (k, i) in enumerate(sec_nodes)
        Arb[2k-1, 1] = 1.0; Arb[2k-1, 3] = -(ys[i] - yc)
        Arb[2k,   2] = 1.0; Arb[2k,   3] =  (xs[i] - xc)
    end
    Prb = pinv(Arb)
    patch = Set(m.patch_nodes)
    max_dim = max(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys))
    function halfwaves(w)
        mx = maximum(abs, w); mx == 0 && return 0
        w = w[abs.(w) .> 0.05mx]
        isempty(w) && return 0
        1 + count(k -> sign(w[k]) != sign(w[k+1]), 1:length(w)-1)
    end
    metrics = ModeMetrics[]
    for vec in Φ
        ux = [vec[node_to_dofs[i][1]] for i in 1:nn]; uy = [vec[node_to_dofs[i][2]] for i in 1:nn]; uz = [vec[node_to_dofs[i][3]] for i in 1:nn]
        d_in = hypot.(ux, uy); dmax = maximum(d_in)
        e_tot = 0.0; e_res = 0.0
        best = (0.0, 0.0, 0.0, 0.0)
        for p in full
            idx = m.sid[:, p]
            d = Vector{Float64}(undef, 2ns)
            for (k, i) in enumerate(idx); d[2k-1] = ux[i]; d[2k] = uy[i]; end
            c = Prb * d
            r = d - Arb * c
            e_tot += sum(abs2, d); e_res += sum(abs2, r)
            mag = hypot(c[1], c[2], c[3] * max_dim / 2)
            mag > best[1] && (best = (mag, abs(c[1]), abs(c[2]), abs(c[3]) * max_dim / 2))
        end
        rb_frac = e_tot > 0 ? 1 - e_res / e_tot : 0.0
        ratio(secnodes) = maximum(d_in[m.sid[s, p]] for s in secnodes, p in full) / dmax
        wf, fl, tip = ratio(m.sec.wf_corners), ratio(m.sec.fl_corners), ratio(m.sec.tips)
        e_all = sum(ux .^ 2 .+ uy .^ 2 .+ uz .^ 2)
        e_patch = sum(ux[i]^2 + uy[i]^2 + uz[i]^2 for i in m.patch_nodes; init = 0.0)
        hole_frac = e_all > 0 ? e_patch / e_all : 0.0
        d3 = hypot.(ux, uy, uz)
        d_full = maximum(d3[m.sid[s, p]] for s in 1:ns, p in full)
        hole_ratio = isempty(m.patch_nodes) ? 0.0 : maximum(d3[m.patch_nodes]) / d_full
        hw_web = halfwaves([ux[m.sid[m.sec.web_center, p]] for p in full])
        tipline = [m.sid[m.sec.tips[1], p] for p in 1:m.nz+1]
        wtip = ux[tipline]
        hw_tip = halfwaves(wtip)
        pm = m.nz ÷ 2 + 1
        hw_seg = (halfwaves(wtip[1:pm]), halfwaves(wtip[pm:end]))
        class = hole_ratio > hole_local ? "local-hole" : rb_frac > rb_global ? "global" : (fl > fl_dist && wf < wf_dist ? "distortional" : "local")
        parts = String[]
        best[2] > 0.3best[1] && push!(parts, "weak-axis flexure")
        best[3] > 0.3best[1] && push!(parts, "strong-axis flexure")
        best[4] > 0.3best[1] && push!(parts, "torsion")
        desc = class == "global" ? join(parts, " + ") : ""
        push!(metrics, ModeMetrics(class, rb_frac, wf, fl, tip, hole_frac, hole_ratio, hw_web, hw_tip, hw_seg, desc))
    end
    return metrics
end

rigid_body_description(mm::ModeMetrics) = mm.global_desc

"Write a CSV of modes and metrics."
function write_modes_csv(path, λ, metrics, A)
    open(path, "w") do io
        println(io, "mode, Pcr_kN, Pcr_kips, fcr_MPa, fcr_ksi, class, rigid_body_fraction, webflange_corner_ratio, flangelip_corner_ratio, liptip_ratio, hole_energy_fraction, hole_displacement_ratio, web_halfwaves, liptip_halfwaves, liptip_halfwaves_seg1, liptip_halfwaves_seg2, global_description")
        for (k, (l, mm)) in enumerate(zip(λ, metrics))
            @printf(io, "%d, %.4f, %.4f, %.3f, %.4f, %s, %.3f, %.3f, %.3f, %.3f, %.3f, %.2f, %d, %d, %d, %d, %s\n",
                    k, l/1000, l/N_PER_KIP, l/A, l/A/MPA_PER_KSI, mm.class, mm.rb_frac, mm.wf, mm.fl, mm.tip, mm.hole_frac, mm.hole_ratio,
                    mm.hw_web, mm.hw_tip, mm.hw_tip_seg[1], mm.hw_tip_seg[2], mm.global_desc)
        end
    end
end

function print_modes(λ, metrics; max_local = 8)
    println("\n  #    P_cr[kN]  P_cr[kips]  class         rb_frac  wf     fl     tip    hole   ratio  hw_web hw_tip (seg)  global")
    nloc = 0
    for (k, (l, mm)) in enumerate(zip(λ, metrics))
        if mm.class == "local"
            nloc += 1; nloc > max_local && continue
        end
        @printf("%4d  %9.3f  %9.3f   %-13s %6.3f  %5.3f  %5.3f  %5.3f  %5.3f  %5.2f  %4d   %4d (%d,%d)  %s\n", k, l/1000, l/N_PER_KIP, mm.class,
                mm.rb_frac, mm.wf, mm.fl, mm.tip, mm.hole_frac, mm.hole_ratio, mm.hw_web, mm.hw_tip, mm.hw_tip_seg[1], mm.hw_tip_seg[2], mm.global_desc)
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# 7. Geometry helpers for plotting (faces as triangles)
# ═══════════════════════════════════════════════════════════════════════════════
"Triangular face matrix for Makie `mesh!` (quads split along a diagonal)."
function face_matrix(m::StudModel)
    rows = Vector{NTuple{3,Int}}()
    for c in m.grid.cells
        if c isa Ferrite.Triangle
            push!(rows, c.nodes)
        else
            n1, n2, n3, n4 = c.nodes
            push!(rows, (n1, n2, n3)); push!(rows, (n1, n3, n4))
        end
    end
    return [rows[i][j] for i in eachindex(rows), j in 1:3]
end

"Unique element edges as pairs of node ids."
function edge_list(m::StudModel)
    E = Set{Tuple{Int,Int}}()
    for c in m.grid.cells
        nn = c.nodes; k = length(nn)
        for j in 1:k
            push!(E, minmax(nn[j], nn[mod1(j+1, k)]))
        end
    end
    return collect(E)
end

end # module
