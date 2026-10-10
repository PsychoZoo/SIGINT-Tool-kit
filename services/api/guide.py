"""The guide (docs/GUIDE.md) as a page of the dashboard, so it's readable on the
master with no internet. The same file is the online version on GitHub."""

import os
from pathlib import Path

import markdown


def guide_path() -> Path | None:
    """docs/GUIDE.md: next to this file in the API image, or up in the repository."""
    if os.environ.get("SIGINT_GUIDE"):
        return Path(os.environ["SIGINT_GUIDE"])
    for folder in Path(__file__).resolve().parents:
        candidate = folder / "docs" / "GUIDE.md"
        if candidate.is_file():
            return candidate
    return None


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Guide - SIGINT Tool-kit</title>
<style>
  :root {{ --bg:#0f1216; --panel:#171b21; --line:#262c35; --text:#d7dde4; --dim:#7d8794; --accent:#58a6ff; }}
  body {{ margin:0; background:var(--bg); color:var(--text); font:15px/1.6 system-ui,sans-serif; }}
  header {{ display:flex; gap:16px; align-items:center; padding:12px 16px; border-bottom:1px solid var(--line);
           font:14px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }}
  header a {{ color:var(--accent); text-decoration:none; }}
  article {{ max-width:860px; margin:0 auto; padding:16px; }}
  h1, h2, h3 {{ line-height:1.25; }} h2 {{ border-bottom:1px solid var(--line); padding-bottom:4px; margin-top:2em; }}
  a {{ color:var(--accent); }}
  code {{ font:13px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; background:var(--panel);
         padding:1px 4px; border-radius:4px; }}
  pre {{ background:var(--panel); border:1px solid var(--line); border-radius:6px; padding:12px; overflow:auto; }}
  pre code {{ padding:0; background:none; }}
  table {{ border-collapse:collapse; display:block; overflow:auto; }}
  td, th {{ border:1px solid var(--line); padding:6px 10px; text-align:left; vertical-align:top; }}
  blockquote {{ margin:0; padding:4px 12px; border-left:3px solid var(--accent); color:var(--dim); }}
</style>
</head>
<body>
<header><strong>SIGINT Tool-kit</strong><a href="/">Dashboard</a><a href="/guide">Guide</a><a href="/docs">API docs</a></header>
<article>
{body}
</article>
</body>
</html>
"""


def _markdown() -> markdown.Markdown:
    md = markdown.Markdown(extensions=["fenced_code", "tables", "toc"])
    # Treat raw HTML in the guide as text: the page never runs markup from a file.
    md.preprocessors.deregister("html_block")
    md.inlinePatterns.deregister("html")
    return md


def render_guide(text: str) -> str:
    return _markdown().convert(text)


def guide_page() -> str:
    path = guide_path()
    if path is None or not path.is_file():
        body = "<h1>Guide not found</h1><p>docs/GUIDE.md is missing from this installation.</p>"
    else:
        body = render_guide(path.read_text(encoding="utf-8"))
    return PAGE.format(body=body)

