# ICCFSS 2026 talk — Moen & Shabhari

Two versions of the same 14-slide talk, built from the paper:

| File | What it is |
|---|---|
| `deck/slides.md` | the talk in [deckmd](https://github.com/KristofferC/deckmd) Markdown — edit this |
| `index.html` | the deck as one self-contained page (open in a browser; `→`/`←` navigate, `f` fullscreen, `t` light/dark); served on GitHub Pages |
| `Moen_Shabhari_ICCFSS_2026_slides.pdf` | one slide per page (handout) |
| `Moen_Shabhari_ICCFSS_2026.pptx` | PowerPoint version built from `template.pptx` with the same content |
| `build_pptx.py` | builds the .pptx (python-pptx); `timing.json` holds the wall-clock times for the performance slide |
| `template.pptx` | the conference PowerPoint template (CCFSS logo, Aptos theme, date footer) |

The deckmd theme (`deck/template.html`) uses the template's palette (navy 0E2841, blue 156082, orange E97132), the
conference logo on the title slide, and a logo + conference line footer on every other slide.

## Rebuild
```
cd deck
julia serve.jl                 # live preview at http://localhost:8383 while editing slides.md
julia build.jl --single --pdf  # deck.html, deck-single.html (= ../index.html), deck.pdf (needs Google Chrome)
cd ..
python3 build_pptx.py          # Moen_Shabhari_ICCFSS_2026.pptx
```
Figures in `deck/data/` are copies of `../paper/images/`; `deck/data/viewer.png` is a screenshot of the browser mode
viewer, `qr.svg`/`qr.png` encode the GitHub Pages URL (`julia deck/scripts/qr.jl <url>` regenerates the SVG).
