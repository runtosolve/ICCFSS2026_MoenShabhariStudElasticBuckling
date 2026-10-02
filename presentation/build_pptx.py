"""Build Moen_Shabhari_ICCFSS_2026.pptx from template.pptx with the same content as deck/slides.md.
    python3 build_pptx.py
Figures are read from deck/data (copied from paper/images). Layouts used: Title Slide, Title and Content, Two Content,
Picture with Caption. Fonts follow the template theme (Aptos); only sizes are set here."""
import copy, os
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "deck", "data")
OUT = os.path.join(HERE, "Moen_Shabhari_ICCFSS_2026.pptx")
ACCENT = RGBColor(0x15, 0x60, 0x82); ORANGE = RGBColor(0xE9, 0x71, 0x32); INK = RGBColor(0x0E, 0x28, 0x41); MUTED = RGBColor(0x4B, 0x56, 0x66)

prs = Presentation(os.path.join(HERE, "template.pptx"))
# drop the two sample slides of the template
sldIdLst = prs.slides._sldIdLst
for sldId in list(sldIdLst):
    prs.part.drop_rel(sldId.rId); sldIdLst.remove(sldId)
L = {l.name: l for l in prs.slide_layouts}

def ph(slide, idx):
    for p in slide.placeholders:
        if p.placeholder_format.idx == idx: return p
    return None

def set_title(slide, text, size=32):
    t = slide.shapes.title; t.text = text
    for p in t.text_frame.paragraphs:
        for r in p.runs: r.font.size = Pt(size); r.font.bold = True; r.font.color.rgb = INK

def runs(par, text, size, bold=False, color=None, mono=False):
    """text with **bold** segments and `code` segments"""
    import re
    for seg in re.split(r"(\*\*.+?\*\*|`.+?`)", text):
        if not seg: continue
        r = par.add_run()
        if seg.startswith("**"): r.text = seg[2:-2]; r.font.bold = True
        elif seg.startswith("`"): r.text = seg[1:-1]; r.font.name = "Consolas"
        else: r.text = seg; r.font.bold = bold
        r.font.size = Pt(size)
        if color is not None: r.font.color.rgb = color
        if mono: r.font.name = "Consolas"

def bullets(tf, items, size=18, sub=15, first=True):
    """items: list of str or (str, level)"""
    tf.word_wrap = True
    for k, it in enumerate(items):
        text, lvl = (it, 0) if isinstance(it, str) else it
        par = tf.paragraphs[0] if (k == 0 and first) else tf.add_paragraph()
        par.level = lvl
        runs(par, text, size if lvl == 0 else sub)
        par.space_after = Pt(4 if lvl == 0 else 2)

def textbox(slide, left, top, width, height, items, size=16, sub=14, color=None, bullet=True):
    tb = slide.shapes.add_textbox(left, top, width, height); tf = tb.text_frame; tf.word_wrap = True
    for k, it in enumerate(items):
        text, lvl = (it, 0) if isinstance(it, str) else it
        par = tf.paragraphs[0] if k == 0 else tf.add_paragraph()
        runs(par, ("•  " if bullet else "") + text, size if lvl == 0 else sub, color=color)
        par.space_after = Pt(4)
    return tb

def code(slide, left, top, width, height, title, lines, size=11):
    box = slide.shapes.add_shape(1, left, top, width, height)   # rectangle
    box.fill.solid(); box.fill.fore_color.rgb = RGBColor(0xEE, 0xF1, 0xF5); box.line.color.rgb = RGBColor(0xD9, 0xDE, 0xE6)
    box.shadow.inherit = False
    tf = box.text_frame; tf.word_wrap = False; tf.vertical_anchor = MSO_ANCHOR.TOP
    tf.margin_left = tf.margin_right = Inches(0.15); tf.margin_top = Inches(0.08)
    p = tf.paragraphs[0]; runs(p, title, size + 1, bold=True, color=INK); p.space_after = Pt(4)
    for ln in lines:
        p = tf.add_paragraph(); runs(p, ln, size, color=RGBColor(0x2B, 0x36, 0x48), mono=True); p.space_after = Pt(0)
    return box

def picture(slide, name, left, top, width, height, caption=None, csize=11):
    path = os.path.join(DATA, name); w, h = Image.open(path).size
    scale = min(width / w, height / h); pw, phh = int(w * scale), int(h * scale)
    pic = slide.shapes.add_picture(path, left + (width - pw) // 2, top, pw, phh)
    if caption:
        tb = slide.shapes.add_textbox(left, top + phh + Inches(0.05), width, Inches(0.5)); tf = tb.text_frame; tf.word_wrap = True
        runs(tf.paragraphs[0], caption, csize, color=MUTED); tf.paragraphs[0].alignment = PP_ALIGN.CENTER
    return pic

def table(slide, left, top, width, rows, col_widths=None, size=12, head_size=10, hl=None):
    nr, nc = len(rows), len(rows[0])
    shp = slide.shapes.add_table(nr, nc, left, top, width, Inches(0.3) * nr); tbl = shp.table
    if col_widths:
        tot = sum(col_widths)
        for j, cw in enumerate(col_widths): tbl.columns[j].width = int(width * cw / tot)
    for i, row in enumerate(rows):
        for j, val in enumerate(row):
            c = tbl.cell(i, j); c.text = ""; p = c.text_frame.paragraphs[0]
            runs(p, val, head_size if i == 0 else size, bold=(i == 0) or (hl == (i, j)), color=(ACCENT if hl == (i, j) else None))
            p.alignment = PP_ALIGN.LEFT if j == 0 else PP_ALIGN.CENTER
            c.margin_top = c.margin_bottom = Inches(0.03)
    return tbl

def content_slide(title, items, size=18, sub=15):
    s = prs.slides.add_slide(L["Title and Content"]); set_title(s, title)
    bullets(ph(s, 1).text_frame, items, size, sub); return s

def two_content(title):
    s = prs.slides.add_slide(L["Two Content"]); set_title(s, title)
    a, b = ph(s, 1), ph(s, 2)
    geo = [(x.left, x.top, x.width, x.height) for x in (a, b)]
    return s, a, b, geo

def remove(shape): shape._element.getparent().remove(shape._element)

# ───────────────────────────── 1 title ─────────────────────────────
s = prs.slides.add_slide(L["Title Slide"])
set_title(s, "Elastic buckling analysis of a cold-formed steel stud column with open-source shell finite element software", 34)
sub = ph(s, 1); sub.text = ""
runs(sub.text_frame.paragraphs[0], "Cristopher D. Moen and Amoke Shabhari", 22, color=INK)
p = sub.text_frame.add_paragraph(); runs(p, "RunToSolve LLC", 18, color=MUTED)
p = sub.text_frame.add_paragraph(); runs(p, "Wei-Wen Yu International Specialty Conference on Cold-Formed Steel Structures, Madison, Wisconsin", 14, color=MUTED)
s.shapes.add_picture(os.path.join(DATA, "qr.png"), Inches(11.4), Inches(5.6), Inches(1.5), Inches(1.5))
tb = s.shapes.add_textbox(Inches(8.9), Inches(7.05), Inches(4.2), Inches(0.3))
runs(tb.text_frame.paragraphs[0], "runtosolve.github.io/ICCFSS2026_MoenShabhariStudElasticBuckling", 9, color=MUTED); tb.text_frame.paragraphs[0].alignment = PP_ALIGN.RIGHT

# ───────────────────────────── 2 motivation ─────────────────────────────
s2 = content_slide("Shell finite element analysis, in the open", [
    "Few modern shell implementations are available for public inspection, and what commercial codes do under the hood is hard to know",
    "A multi-year effort built a trusted, open-source shell capability in **Julia**, connected to the general-purpose finite element framework **Ferrite.jl**",
    "Two Mindlin shell elements are now published as packages with elastic and geometric stiffness matrices",
    ("**TriShellFiniteElement.jl**, a 3-node triangle", 1), ("**QuadShellFiniteElement.jl**, a \"4+2\" quadrilateral", 1),
    "This talk walks through one eigenbuckling analysis of a common wall stud with holes"])
textbox(s2, Inches(0.9), Inches(5.0), Inches(11.5), Inches(0.5), ["Thanks to Sándor Ádány for the shell element formulations and MATLAB reference implementations"], 12, color=MUTED, bullet=False)

# ───────────────────────────── 3 elements ─────────────────────────────
s, a, b, geo = two_content("Two flat Mindlin shells, six degrees of freedom per node")
bullets(a.text_frame, ["**Triangle, TriShellFiniteElement.jl**",
    ("Constant-strain membrane; Mindlin bending with the Tessler–Hughes shear treatment (mid-side deflections condensed out)", 1),
    ("Shear relaxation 1/(1 + Cs α), Cs = 0.2, calibrated so a simply supported plate converges to k = 4.0", 1),
    ("Hughes–Brezzi drilling stiffness, so folded plates assemble without singular matrices", 1)], 18, 15)
bullets(b.text_frame, ["**Quadrilateral, QuadShellFiniteElement.jl**",
    ("The \"4+2\" element of Moen and Ádány: bilinear shape functions plus two bubble functions, condensed at the element level, which relieves in-plane bending stiffness and part of the shear locking", 1),
    ("Same shear relaxation (Cs = 0.1) and drilling term", 1),
    ("Julia matrices reproduce the MATLAB reference to machine precision (a package test)", 1)], 18, 15)
for x in (a, b): x.height = Inches(3.9)
textbox(s, Inches(0.9), Inches(5.6), Inches(11.5), Inches(1.2), [
    "Geometric stiffness from the Green–Lagrange membrane strains (Nx, Ny, Nxy and the gradients of all three translations)",
    "K φ = λ (−Kg) φ, and with a unit reference load the eigenvalue is the buckling load"], 16)

# ───────────────────────────── 5 stud ─────────────────────────────
s, a, b, geo = two_content("A 362S162-33 wall stud with SFIA service holes")
bullets(a.text_frame, ["Web 3.625 in, flange 1.625 in, lip 0.5 in, design thickness **0.0346 in**; E = 29 500 ksi, ν = 0.3",
    "Braced at midheight: Lx = Ly = Lt = 48 in; pinned, warping-free ends; uniform compression, Pref = 1 N",
    "Four 1.5 × 4 in stadium-shaped holes at 12, 36, 60, and 84 in (24 in o.c.); the brace point is 12 in from the nearest holes"], 16, 14)
bullets(b.text_frame, ["Centerline polyline from CrossSectionGeometry.jl: 85 nodes, corner radius 2t, 4 elements per lip, 20 per flange and web, 4 per corner arc",
    "The same polyline goes to CUFSM.jl, so the shell and finite strip analyses share their geometry"], 16, 14)
for x in (a, b): x.height = Inches(2.3)
picture(s, "fig_mesh_hole.png", Inches(0.9), Inches(4.0), Inches(11.5), Inches(2.6),
        "(a) 85-node centerline polyline; (b) web mesh around a hole: structured quadrilaterals outside the 150 mm patch, triangles inside it")

# ───────────────────────────── 7 dofs & BCs ─────────────────────────────
s, a, b, geo = two_content("Degrees of freedom, boundary conditions, brace")
remove(a); (l, t, w, h) = geo[0]
code(s, l, t, w, Inches(2.3), "Two element types, one DofHandler (patch-boundary nodes share dofs)", [
    "dh = DofHandler(grid)", "sq = SubDofHandler(dh, quad_cells)", "ipq = Lagrange{RefQuadrilateral, 1}()",
    "add!(sq, :u, ipq^3); add!(sq, :θ, ipq^3)", "st = SubDofHandler(dh, tri_cells)", "ipt = Lagrange{RefTriangle, 1}()",
    "add!(st, :u, ipt^3); add!(st, :θ, ipt^3)", "close!(dh)"], 11)
code(s, l, t + Inches(2.5), w, Inches(2.4), "Pinned warping-free ends and the midheight brace", [
    "ch = ConstraintHandler(dh)", "add!(ch, Dirichlet(:u, end_nodes,              # ux = uy = 0", "         (x, t) -> [0.0, 0.0], [1, 2]))",
    "add!(ch, Dirichlet(:u, brace_corner_nodes,     # ux = 0", "         (x, t) -> [0.0], [1]))",
    "add!(ch, Dirichlet(:u, Set([brace_web_center]), # uy = uz = 0", "         (x, t) -> [0.0, 0.0], [2, 3]))", "close!(ch)"], 11)
bullets(b.text_frame, ["Ends: ux = uy = 0 at every end node, uz and all rotations free",
    "Load: equal and opposite axial nodal forces by tributary centerline length, giving uniform P/A away from ends and holes",
    "Brace: ux = 0 at the two **web-flange corners** (translation perpendicular to the web and twist), uy = 0 and the axial datum uz = 0 at the web mid-depth node on the symmetry axis, so no prebuckling stress is induced"], 16, 14)

# ───────────────────────────── 8 stresses ─────────────────────────────
s, a, b, geo = two_content("Pre-buckling stresses and geometric stiffness")
remove(a); remove(b); (l, t, w, h) = geo[0]
code(s, l, t, w, Inches(2.5), "One call per package, summed", [
    "Kq = QuadShellFiniteElement.assemble_global_Ke!(", "         allocate_matrix(dh, ch), sq, qr2, qr3,", "         IP4(), IP6(), E, ν, t; Cs = 0.1)",
    "Kt = TriShellFiniteElement.assemble_global_Ke!(", "         allocate_matrix(dh, ch), st, qr1, qr3,", "         IP3(), IP6(), E, ν, t; Cs = 0.2)",
    "K = Kq + Kt;  apply!(K, F, ch)", "u = K \\ F;  apply!(u, ch)", "σ = membrane_stresses(dh, u, E, ν, t)  # element frame", "Kg = assemble_Kg(dh, ch, σ, t)         # summed, too"], 10)
textbox(s, l, t + Inches(2.7), w, Inches(2.5), [
    "Static problem solved with Julia's sparse direct solver; membrane stresses recovered element by element (one per triangle, four Gauss points per quadrilateral)",
    "Normalized by P/A: **1.0** in the bulk, about **1.9** in the web strips beside a hole, **1.25** in the flanges at the hole plane, **0.5** just above and below the hole"], 15)
(l2, t2, w2, h2) = geo[1]
picture(s, "fig_stress_hole.png", l2, t2, w2, Inches(3.6), "Pre-buckling longitudinal membrane stress on the web face around a hole, normalized by P/A")

# ───────────────────────────── 9 eigen solve ─────────────────────────────
s, a, b, geo = two_content("Solving the eigenvalue problem with ARPACK")
remove(a); (l, t, w, h) = geo[0]
code(s, l, t, w, Inches(2.0), "Lowest modes: K⁻¹(−Kg), one Cholesky factorization", [
    "Kfac = cholesky(Symmetric(K));  tmp = zeros(n)", "op!(y, x) = (mul!(tmp, Kg, x); y .= Kfac \\ -tmp)",
    "μ, Φ = eigs(LinearMap(op!, n; ismutating = true);", "            nev = 12, which = :LM)", "Pcr = 1 ./ real.(μ)      # N, because P_ref = 1 N"], 11)
code(s, l, t + Inches(2.2), w, Inches(2.0), "Shift-and-invert: modes nearest a target load σ", [
    "Mfac = ldlt(Symmetric(K + σ * Kg))      # indefinite", "op!(y, x) = (mul!(tmp, Kg, x); y .= Mfac \\ -tmp)",
    "ν, V = eigs(LinearMap(op!, n; ismutating = true);", "            nev = 40, which = :LM)", "Pcr = σ .+ 1 ./ real.(ν)"], 11)
bullets(b.text_frame, ["Implicitly restarted Arnoldi on K⁻¹(−Kg): its largest eigenvalues are the reciprocals of the smallest buckling loads",
    "A perforated member has **hundreds of local modes** below its distortional and global loads, so the bottom of the spectrum never reaches them",
    "Shift-and-invert with targets from 14 to 60 kN, 40 modes per target, one indefinite factorization and about 20 s each",
    "Every mode is **classified automatically**: displacement ratio at the hole patches (local at a hole), rigid-body energy fraction (global: weak-axis, strong-axis, torsion), flange-lip versus web-flange corner motion (distortional), else local"], 16, 14)

# ───────────────────────────── 10 reference values ─────────────────────────────
s, a, b, geo = two_content("Finite strip and closed-form reference values")
remove(a); (l, t, w, h) = geo[0]
picture(s, "fig_signature_curve.png", l, t - Inches(0.2), w, Inches(5.4))
bullets(b.text_frame, ["**CUFSM.jl, gross section:** local minimum 16.14 kN at 70 mm, distortional 37.20 kN at 460 mm",
    "**Hole approximations** (CeeSectionBuckling.jl, the RunToSolve SFIA evaluation procedure)",
    ("net section through the hole: local 24.88 kN, above the gross value, so the unperforated web governs", 1),
    ("AISI S100 reduced web thickness tr = t(1 − Lh/Lcrd)^(1/3) = 0.807 mm: distortional 37.30 → 35.35 kN", 1),
    "**Closed form, KL = 48 in:** Pex = 314.6, Pey = 56.9, Pt = 40.0, flexural-torsional **37.89 kN**; weighted-average net properties 31.63 kN",
    "**Finite strip at one 1219 mm half-wave** (section free to distort): 37.17 kN flexural-torsional, 49.58 kN weak-axis flexure"], 15, 13)

# ───────────────────────────── 11 results table ─────────────────────────────
s = prs.slides.add_slide(L["Title Only"]); set_title(s, "Shell finite element buckling loads, kN")
rows = [["Buckling mode", "5 mm mesh", "2.5 mm mesh", "5 mm, no holes", "Finite strip / analytical"],
        ["Local, lowest", "15.95", "16.00", "15.79", "16.14 (CUFSM gross)"],
        ["Local at the holes (web strips)", "20.45", "20.56", "–", "24.88 (net section)"],
        ["Distortional, 3 half-waves per segment", "36.51", "36.38", "37.37", "35.35 (reduced t), 37.30 (gross)"],
        ["Distortional–hole interaction, 5 half-waves", "32.63", "32.33", "–", "–"],
        ["Global, flexural-torsional", "35.25", "34.76", "37.15", "37.89 (closed form), 37.17 (CUFSM)"],
        ["Global, weak-axis flexure", "46.74", "47.70", "49.58", "56.93 (Euler), 49.58 (CUFSM mode 2)"]]
table(s, Inches(0.9), Inches(1.7), Inches(11.5), rows, [3.2, 1.1, 1.1, 1.2, 3.0], 14, 11, hl=(5, 1))
textbox(s, Inches(0.9), Inches(5.2), Inches(11.5), Inches(0.8), [
    "Halving the element length changes every load by less than two percent. The lowest mode is local; the governing global mode is flexural-torsional."], 14, color=MUTED, bullet=False)

# ───────────────────────────── 14 local modes ─────────────────────────────
s, a, b, geo = two_content("Local modes")
remove(a); remove(b)
picture(s, "fig_mode_local.png", geo[0][0], geo[0][1], geo[0][2], Inches(4.4), "Lowest local mode, 15.95 kN: the web buckles between the holes")
picture(s, "fig_mode_local_hole.png", geo[1][0], geo[1][1], geo[1][2], Inches(4.4), "Lowest mode at a hole, 20.45 kN: the two web strips bow in opposite directions")
textbox(s, Inches(0.9), Inches(6.5), Inches(11.5), Inches(0.4), ["5 mm mesh (top) and 2.5 mm mesh (bottom) in each figure; color is displacement magnitude"], 12, color=MUTED, bullet=False)

# ───────────────────────────── 15 distortional and global ─────────────────────────────
s = prs.slides.add_slide(L["Title Only"]); set_title(s, "Distortional and global modes, lower 48 in braced segment")
picture(s, "fig_mode_distortional.png", Inches(1.2), Inches(1.5), Inches(11.0), Inches(2.3), "Lowest distortional mode, 36.51 kN: three half-waves per braced segment, the brace plane is a node")
picture(s, "fig_mode_global.png", Inches(1.2), Inches(4.3), Inches(11.0), Inches(2.3), "Lowest global mode, 35.25 kN: lateral translation plus twist in each segment, one half-wave")

# ───────────────────────────── 16 performance ─────────────────────────────
s, a, b, geo = two_content("Six minutes on a laptop for a quarter-million dofs")
remove(a)
TIMING = __import__("json").load(open(os.path.join(HERE, "timing.json"))) if os.path.exists(os.path.join(HERE, "timing.json")) else None
rows = [["Step", "5 mm mesh", "2.5 mm mesh"], ["Degrees of freedom", "247 998", "509 286"]]
labels = [("Assemble elastic stiffness", "assemble_K"), ("Static solve", "static_solve"), ("Assemble geometric stiffness", "assemble_Kg"),
          ("Cholesky factorization of K", "factorization"), ("12 lowest modes (ARPACK)", "eigs_lowest"), ("13 shift-and-invert windows, 40 modes each", "shift_invert_total")]
for lab, key in labels:
    rows.append([lab] + [f"{TIMING[m][key]:.0f} s" if TIMING else "–" for m in ("M1", "M2")])
table(s, geo[0][0], geo[0][1], geo[0][2], rows, [3.0, 1.0, 1.0], 13, 10)
bullets(b.text_frame, ["Apple M3 Max laptop, sparse factorizations on 7 threads, less than 2 GB of memory",
    "Each shift-and-invert window is one indefinite factorization and about 27 s; the sweep yields about 190 distinct modes between 16 and 65 kN",
    "Julia compiles the packages on first use, roughly a minute per session"], 16, 14)

# ───────────────────────────── 4 validation ─────────────────────────────
content_slide("Documentation and validation live on GitHub", [
    "Each repository README documents the element mechanics, the calling sequence with Ferrite.jl, and the default parameters; docstrings cover the public functions",
    "The **test suites are the validation record**. For the triangle:",
    ("element symmetry, rigid body modes, thickness independence", 1), ("uniform compression reproducing PL/EA", 1),
    ("simply supported plate converging to k = 4.0, clamped plate to k ≈ 10.07", 1),
    ("buckling load invariant to the orientation of the plate in space", 1),
    ("torsion of flat and folded strips and of a rounded lipped channel reproducing the thin-walled torsion constant within a few percent", 1),
    "For the quadrilateral: element-by-element comparison with the MATLAB reference, plus the plate bending, membrane, and column buckling benchmarks of the earlier paper",
    "`Pkg.test()` on either package regenerates every number in this list"], 17, 14)

# ───────────────────────────── 19 closing copy of the title slide ─────────────────────────────
s = prs.slides.add_slide(L["Title Slide"])
set_title(s, "Elastic buckling analysis of a cold-formed steel stud column with open-source shell finite element software", 34)
sub = ph(s, 1); sub.text = ""
runs(sub.text_frame.paragraphs[0], "Cristopher D. Moen and Amoke Shabhari", 22, color=INK)
p = sub.text_frame.add_paragraph(); runs(p, "RunToSolve LLC", 18, color=MUTED)
p = sub.text_frame.add_paragraph(); runs(p, "Wei-Wen Yu International Specialty Conference on Cold-Formed Steel Structures, Madison, Wisconsin", 14, color=MUTED)
s.shapes.add_picture(os.path.join(DATA, "qr.png"), Inches(11.4), Inches(5.6), Inches(1.5), Inches(1.5))
tb = s.shapes.add_textbox(Inches(8.9), Inches(7.05), Inches(4.2), Inches(0.3))
runs(tb.text_frame.paragraphs[0], "runtosolve.github.io/ICCFSS2026_MoenShabhariStudElasticBuckling", 9, color=MUTED); tb.text_frame.paragraphs[0].alignment = PP_ALIGN.RIGHT

# carry the template's date and slide-number footers onto every slide (copied from each slide's layout)
from pptx.enum.shapes import PP_PLACEHOLDER
for k, s in enumerate(prs.slides, 1):
    for lp in s.slide_layout.placeholders:
        if lp.placeholder_format.type in (PP_PLACEHOLDER.DATE, PP_PLACEHOLDER.SLIDE_NUMBER):
            el = copy.deepcopy(lp._element); s.shapes._spTree.append(el)
    for sh in s.placeholders:
        if sh.placeholder_format.type == PP_PLACEHOLDER.DATE and sh.has_text_frame:
            sh.text_frame.text = "October 6–7, 2026"
prs.save(OUT); print("wrote", OUT, len(prs.slides), "slides")
