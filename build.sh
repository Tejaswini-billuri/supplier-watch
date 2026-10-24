#!/bin/zsh
# Rebuild the submission outputs from the part files.
#   SUBMISSION.md / .pdf / .docx   main document (~20 pages): decision log, Parts A–D, assumptions
#   APPENDIX.md / .pdf             reference: data dictionary, full DDL, sample data, query output
set -e
cd "$(dirname "$0")"
V=/private/tmp/claude-502/-Users-tejaswinibilluri-Downloads/2266640c-2340-4a71-9201-d742dc0d69ac/scratchpad/venv
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

$V/bin/python - <<'PY'
import pathlib, re, base64, markdown
def md(p): return pathlib.Path(p).read_text()
def code(p, lang): return f"```{lang}\n{pathlib.Path(p).read_text().rstrip()}\n```\n"

# ---------------------------------------------------------------- main document
main = ["# Supplier Watch — Senior Data Engineer take-home\n\n"
        "Submission document. Reference material (full data dictionary, full DDL, sample data, query output) is in the separate appendix; "
        "every file is also in the repository (`README.md`).\n\n"
        "## Contents\n\n1. Part A — Data model\n2. Part B — Model rationale\n3. Part C — Pipeline architecture\n"
        "4. Part D — Pipeline rationale\n5. Assumptions, AI usage, time spent\n\n---\n\n"]
a = md("01_entity_model.md").replace("# Part A.1 — Data model", "# Part A — Data model\n\n## A.1 Entity diagram\n\n![Entity model](diagrams/entity_model.png)\n")
main.append(a + "\n\n## A.2 Schema definitions: the five core tables\n\nFull schema (35 statements, executed on PostgreSQL 17) in appendix B.\n\n" + code("02_ddl_core.sql", "sql")
            + "\n## A.4 Queries for U2, U3, U4\n\nExecuted against the brief's sample data; actual output in appendix D.\n\n" + code("04_queries.sql", "sql") + "\n---\n\n")
main.append(md("07_part_b_model_rationale.md") + "\n\n---\n\n")
c = md("08_part_c_pipeline_architecture.md").replace("## Diagram\n", "## Diagram\n\n![Pipeline](diagrams/pipeline.png)\n", 1)
main.append(c + "\n\n---\n\n")
main.append(md("09_part_d_pipeline_rationale.md") + "\n\n---\n\n")
main.append(md("10_assumptions_and_notes.md"))
pathlib.Path("SUBMISSION.md").write_text("".join(main))

# ---------------------------------------------------------------- appendix
app = ["# Supplier Watch — Appendix\n\nReference material for the submission document.\n\n"
       "- A. Data dictionary\n- B. Full DDL (PostgreSQL)\n- C. Sample data as loaded\n- D. Query results (PostgreSQL 17)\n\n---\n\n",
       md("A1_data_dictionary.md"), "\n\n---\n\n# Appendix B — Full DDL\n\n", code("02_ddl.sql", "sql"),
       "\n---\n\n# Appendix C — Sample data as loaded\n\n", code("05_sample_data.sql", "sql"),
       "\n---\n\n# Appendix D — Query results (PostgreSQL 17)\n\n", code("06_query_results.txt", "text")]
pathlib.Path("APPENDIX.md").write_text("".join(app))

# ---------------------------------------------------------------- html for both
css = """body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:10.5pt;line-height:1.45;max-width:980px;margin:28px auto;color:#1a1a1a}
h1{font-size:20pt;border-bottom:2px solid #333;padding-bottom:4px;margin-top:36px;page-break-before:always} h1:first-of-type{page-break-before:avoid}
h2{font-size:14pt;margin-top:26px} h3{font-size:12pt;margin-top:18px}
table{border-collapse:collapse;width:100%;margin:10px 0;font-size:9.5pt;page-break-inside:avoid}
th,td{border:1px solid #bbb;padding:4px 7px;vertical-align:top;text-align:left} th{background:#f0f0f0}
pre{background:#f6f6f6;border:1px solid #ddd;padding:8px;font-size:8.2pt;line-height:1.3;white-space:pre-wrap;word-wrap:break-word}
code{font-family:Menlo,Consolas,monospace;font-size:8.8pt}
img{max-width:100%;height:auto;display:block;margin:12px auto;page-break-inside:avoid}
hr{border:0;border-top:1px solid #ccc;margin:24px 0}
@page { size: A4; margin: 14mm 12mm; }
@page landscape { size: A4 landscape; margin: 8mm; }
.landscape{page:landscape;page-break-before:always;page-break-after:always;display:flex;align-items:center;justify-content:center;height:180mm}
.landscape img{max-width:100%;max-height:180mm;width:auto;height:auto;margin:0}"""
def embed(m):
    b = base64.b64encode(pathlib.Path(m.group(2)).read_bytes()).decode()
    return f'<div class="landscape"><img alt="{m.group(1)}" src="data:image/png;base64,{b}"></div>'
for name, title in (("SUBMISSION", "Supplier Watch — Senior Data Engineer take-home"), ("APPENDIX", "Supplier Watch — Appendix")):
    src = re.sub(r'!\[([^\]]*)\]\((diagrams/[^)]+\.png)\)', embed, pathlib.Path(f"{name}.md").read_text())
    body = markdown.markdown(src, extensions=["tables", "fenced_code", "toc", "pymdownx.superfences"])
    pathlib.Path(f"{name}.html").write_text(f"<!doctype html><html><head><meta charset='utf-8'><title>{title}</title><style>{css}</style></head><body>{body}</body></html>")
print("SUBMISSION.md, APPENDIX.md and HTML written")
PY

for name in SUBMISSION APPENDIX; do
  "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="$PWD/$name.pdf" --virtual-time-budget=5000 "file://$PWD/$name.html" 2>/dev/null
  echo "$name.pdf: $(pdfinfo $name.pdf | awk '/^Pages/{print $2}') pages"
  rm -f "$name.html"
done
python3 build_docx.py
