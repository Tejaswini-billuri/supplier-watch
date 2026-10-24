#!/usr/bin/env python3
"""Build SUBMISSION.docx from SUBMISSION.md with pandoc.

- styled reference.docx (A4, 1.5 cm margins, 7 pt monospace code so ASCII diagrams keep alignment)
- each top-level part starts on a new page
- the two wide diagrams sit on their own landscape pages
Run build.sh first so SUBMISSION.md is current.
"""
import pathlib, re, subprocess, shutil, zipfile, tempfile, os

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "SUBMISSION.md"
OUT = ROOT / "SUBMISSION.docx"
TMP = pathlib.Path(tempfile.mkdtemp(prefix="sw-docx-"))

# ---------------------------------------------------------------- reference.docx
ref = TMP / "reference.docx"
subprocess.run(["pandoc", "-o", str(ref), "--print-default-data-file", "reference.docx"], check=True)
unp = TMP / "ref"
with zipfile.ZipFile(ref) as z: z.extractall(unp)

styles = (unp / "word/styles.xml").read_text()
# base font and size
styles = styles.replace(
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">\n    <w:name w:val="Normal" />\n    <w:qFormat />\n  </w:style>',
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">\n    <w:name w:val="Normal" />\n    <w:qFormat />\n'
    '    <w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr>\n  </w:style>')
styles = styles.replace('<w:spacing w:before="180" w:after="180" />', '<w:spacing w:before="100" w:after="100" />')
# inline code
styles = re.sub(r'(<w:style w:type="character" w:customStyle="1" w:styleId="VerbatimChar">.*?)<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" />(\s*<w:sz w:val=")22(" />)',
                r'\g<1><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" />\g<2>18\3', styles, flags=re.S)
# headings: explicit sans font instead of theme fonts (which LibreOffice renders as serif)
styles = re.sub(r'<w:rFonts w:asciiTheme="majorHAnsi"\s+w:eastAsiaTheme="majorEastAsia" w:hAnsiTheme="majorHAnsi"\s+w:cstheme="majorBidi" />',
                '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" />', styles)
styles = re.sub(r'<w:rFonts w:eastAsiaTheme="majorEastAsia"\s+w:cstheme="majorBidi" />',
                '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" />', styles)
# code blocks: add a Source Code paragraph style (pandoc uses it when present)
source_code = '''
  <w:style w:type="paragraph" w:customStyle="1" w:styleId="SourceCode">
    <w:name w:val="Source Code" />
    <w:basedOn w:val="Normal" />
    <w:qFormat />
    <w:pPr>
      <w:spacing w:before="0" w:after="0" w:line="220" w:lineRule="auto" />
      <w:shd w:val="clear" w:color="auto" w:fill="F3F4F6" />
      <w:ind w:left="113" w:right="113" />
    </w:pPr>
    <w:rPr>
      <w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New" />
      <w:sz w:val="14" /><w:szCs w:val="14" />
    </w:rPr>
  </w:style>
</w:styles>'''
styles = styles.replace('</w:styles>', source_code)
(unp / "word/styles.xml").write_text(styles)

# page setup: A4 portrait, 1.5 cm margins
doc = (unp / "word/document.xml").read_text()
doc = re.sub(r'<w:pgSz[^>]*/>', '<w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/>', doc)
doc = re.sub(r'<w:pgMar[^>]*/>', '<w:pgMar w:top="567" w:right="567" w:bottom="567" w:left="567" w:header="567" w:footer="567" w:gutter="0"/>', doc)
(unp / "word/document.xml").write_text(doc)

ref2 = TMP / "reference2.docx"
with zipfile.ZipFile(ref2, "w", zipfile.ZIP_DEFLATED) as z:
    for p in unp.rglob("*"):
        if p.is_file(): z.write(p, p.relative_to(unp).as_posix())

# ---------------------------------------------------------------- markdown transform
PORTRAIT_END = ('\n```{=openxml}\n<w:p><w:pPr><w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
                '<w:pgMar w:top="850" w:right="850" w:bottom="850" w:left="850" w:header="567" w:footer="567" w:gutter="0"/>'
                '</w:sectPr></w:pPr></w:p>\n```\n')
LANDSCAPE_END = ('\n```{=openxml}\n<w:p><w:pPr><w:sectPr><w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/>'
                 '<w:pgMar w:top="567" w:right="567" w:bottom="567" w:left="567" w:header="567" w:footer="567" w:gutter="0"/>'
                 '</w:sectPr></w:pPr></w:p>\n```\n')
PAGE_BREAK = '\n```{=openxml}\n<w:p><w:r><w:br w:type="page"/></w:r></w:p>\n```\n'

md = SRC.read_text()

def landscape(m):
    heads, alt, path = m.group(1) or "", m.group(2), m.group(3)
    return f'{PORTRAIT_END}\n{heads}\n![{alt}]({path}){{width=27cm}}\n{LANDSCAPE_END}'
md = re.sub(r'((?:^#{1,3} [^\n]*\n+)*)^!\[([^\]]*)\]\((diagrams/[^)]+\.png)\)[ \t]*$', landscape, md, flags=re.M)

# new page before every top-level heading except the first
parts = re.split(r'(?m)^(?=# )', md)
md = parts[0] + "".join((PAGE_BREAK if i > 0 else "") + p for i, p in enumerate(parts[1:]))
# the first "---" rules are noise in Word
md = re.sub(r'(?m)^---\s*$', '', md)

mdfile = TMP / "SUBMISSION_docx.md"
mdfile.write_text(md)

# ---------------------------------------------------------------- pandoc
subprocess.run([
    "pandoc", str(mdfile), "-f", "markdown+pipe_tables+raw_attribute+link_attributes-implicit_figures",
    "-t", "docx", "--reference-doc", str(ref2), "--resource-path", str(ROOT),
    "--metadata", "title=Supplier Watch — Senior Data Engineer take-home",
    "-o", str(OUT)], check=True, cwd=ROOT)
# the body-level sectPr (last in document.xml) came from the landscape reference; make it portrait
fix = TMP / "fix"
with zipfile.ZipFile(OUT) as z: z.extractall(fix)
dx = (fix / "word/document.xml").read_text()
i = dx.rfind("<w:sectPr")
tail = dx[i:]
tail = re.sub(r'<w:pgSz[^>]*/>', '<w:pgSz w:w="11906" w:h="16838"/>', tail, count=1)
tail = re.sub(r'<w:pgMar[^>]*/>', '<w:pgMar w:top="850" w:right="850" w:bottom="850" w:left="850" w:header="567" w:footer="567" w:gutter="0"/>', tail, count=1)
dx = dx[:i] + tail
# pandoc ignores the requested image width; set the two diagram extents directly (27 cm wide, aspect kept, height-capped)
import struct
def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24])
sizes = [png_size(ROOT / "diagrams/entity_model.png"), png_size(ROOT / "diagrams/pipeline.png")]
MAX_W, MAX_H = 9720000, 6000000          # EMU: 27 cm wide, ~16.7 cm tall (landscape page minus headings)
dims = []
for w, h in sizes:
    cx = MAX_W; cy = int(cx * h / w)
    if cy > MAX_H: cy = MAX_H; cx = int(cy * w / h)
    dims.append((cx, cy))
n = [0]
def ext(m):
    cx, cy = dims[min(n[0] // 2, len(dims) - 1)]; n[0] += 1
    return f'{m.group(1)} cx="{cx}" cy="{cy}"'
dx = re.sub(r'(<wp:extent|<a:ext) cx="\d+" cy="\d+"', ext, dx)
(fix / "word/document.xml").write_text(dx)
OUT.unlink()
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    for p in fix.rglob("*"):
        if p.is_file(): z.write(p, p.relative_to(fix).as_posix())
print(f"wrote {OUT} ({OUT.stat().st_size//1024} KB)")
shutil.rmtree(TMP, ignore_errors=True)
