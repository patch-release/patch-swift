#!/usr/bin/env python3
"""Port docs-site/index.html into Starlight MDX pages.

The legacy docs are ONE 1,872-line index.html. This splits it on <h2>, converts
each section to Markdown, and writes one page per section. Run once for the
migration; after that the MDX files are the source of truth.
"""
import re, html, pathlib, sys

SRC = pathlib.Path('docs-site/index.html')
OUT = pathlib.Path('docs-v2/src/content/docs')

# section slug -> (filename, sidebar order, short description)
PAGES = {
    'introduction':      ('index.mdx',            0,  'What Patch is and how it fits your app.'),
    'quickstart':        ('quickstart.mdx',       1,  'Install the CLI and ship your first patch.'),
    'ai-setup':          ('ai-setup.mdx',         2,  'Prompts for setting Patch up with an AI assistant.'),
    'how-it-works':      ('how-it-works.mdx',     3,  'The Swift-to-WebAssembly pipeline and on-device runtime.'),
    'can-cant':          ('coverage.mdx',         4,  'What an OTA patch can and cannot change.'),
    'cli':               ('cli.mdx',              5,  'Every patchcli command.'),
    'sdk':               ('sdk.mdx',              6,  'Configuring PatchSDK and the update lifecycle.'),
    'channels':          ('channels.mdx',         7,  'Separate release streams.'),
    'rollouts':          ('rollouts.mdx',         8,  'Percentage rollouts and A/B.'),
    'targeting':         ('targeting.mdx',        9,  'Target releases by version, cohort, and device.'),
    'force-updates':     ('force-updates.mdx',   10,  'Require a patch before the app continues.'),
    'cicd':              ('cicd.mdx',            11,  'Release from GitHub Actions and other CI.'),
    'teams':             ('team.mdx',            12,  'Members, roles, and permissions.'),
    'plans':             ('billing.mdx',         13,  'Plans, limits, and what is gated.'),
    'usage':             ('usage.mdx',           14,  'Device and adoption metrics.'),
    'audit':             ('audit.mdx',           15,  'The activity trail.'),
    'webhooks':          ('webhooks.mdx',        16,  'Events and error-spike alerts.'),
    'troubleshooting':   ('troubleshooting.mdx', 17,  'Common failures and how to fix them.'),
}

def unescape_code(t):
    return html.unescape(t)

def to_md(frag: str) -> str:
    """HTML fragment -> Markdown. Deliberately small and explicit: the legacy
    markup is hand-written and regular, so a targeted converter produces cleaner
    output than a generic one (and never silently drops a table)."""
    s = frag

    # strip script/style/svg outright
    s = re.sub(r'<(script|style|svg)\b.*?</\1>', '', s, flags=re.S)

    # code blocks: <pre><code>…</code></pre>
    def pre(m):
        body = re.sub(r'<[^>]+>', '', m.group(1))
        body = unescape_code(body).strip('\n')
        lang = 'swift' if re.search(r'\b(func|struct|import|var|let)\b', body) else ''
        if re.match(r'^\s*(patchcli|brew|\$|git|npm|curl)', body): lang = 'bash'
        if body.lstrip().startswith('{'): lang = 'json'
        if 'name:' in body and 'on:' in body: lang = 'yaml'
        return f'\n\n```{lang}\n{body}\n```\n\n'
    s = re.sub(r'<pre[^>]*>(.*?)</pre>', pre, s, flags=re.S)

    # tables
    def table(m):
        t = m.group(0)
        rows = re.findall(r'<tr[^>]*>(.*?)</tr>', t, re.S)
        out, header_done = [], False
        for r in rows:
            cells = re.findall(r'<t[hd][^>]*>(.*?)</t[hd]>', r, re.S)
            cells = [re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', '', c)).strip() for c in cells]
            cells = [html.unescape(c).replace('|', '\\|') for c in cells]
            if not cells: continue
            out.append('| ' + ' | '.join(cells) + ' |')
            if not header_done:
                out.append('|' + '|'.join([' --- '] * len(cells)) + '|')
                header_done = True
        return '\n\n' + '\n'.join(out) + '\n\n'
    s = re.sub(r'<table[^>]*>.*?</table>', table, s, flags=re.S)

    # headings h3/h4 -> ##/###  (page title is the h2, so demote one level)
    s = re.sub(r'<h3[^>]*>(.*?)</h3>', lambda m: f'\n\n## {re.sub(r"<[^>]+>","",m.group(1)).strip()}\n\n', s, flags=re.S)
    s = re.sub(r'<h4[^>]*>(.*?)</h4>', lambda m: f'\n\n### {re.sub(r"<[^>]+>","",m.group(1)).strip()}\n\n', s, flags=re.S)

    # lists
    s = re.sub(r'<li[^>]*>(.*?)</li>', lambda m: f'- {re.sub(r"<[^>]+>","",m.group(1)).strip()}\n', s, flags=re.S)
    s = re.sub(r'</?(ul|ol)[^>]*>', '\n', s)

    # inline
    s = re.sub(r'<code[^>]*>(.*?)</code>', lambda m: f'`{html.unescape(re.sub(r"<[^>]+>","",m.group(1))).strip()}`', s, flags=re.S)
    s = re.sub(r'<(b|strong)[^>]*>(.*?)</\1>', r'**\2**', s, flags=re.S)
    s = re.sub(r'<(i|em)[^>]*>(.*?)</\1>', r'*\2*', s, flags=re.S)
    s = re.sub(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
               lambda m: f'[{re.sub(r"<[^>]+>","",m.group(2)).strip()}]({m.group(1)})', s, flags=re.S)

    # paragraphs / breaks
    s = re.sub(r'</p>', '\n\n', s)
    s = re.sub(r'<br\s*/?>', '\n', s)

    # anything left
    s = re.sub(r'<[^>]+>', '', s)
    s = html.unescape(s)

    # tidy — dedent prose (leading spaces would render as a code block) while
    # leaving fenced code untouched
    lines, fence, out = s.split('\n'), False, []
    for ln in lines:
        if ln.lstrip().startswith('```'):
            fence = not fence; out.append(ln.lstrip()); continue
        out.append(ln if fence else ln.lstrip())
    s = '\n'.join(out)
    s = re.sub(r'[ \t]+\n', '\n', s)
    s = re.sub(r'\n{3,}', '\n\n', s)
    return s.strip()

def main():
    if not SRC.exists():
        sys.exit(f'missing {SRC}')
    doc = SRC.read_text()

    # split on <section id="…"> … containing an <h2>
    sections = re.findall(r'<section[^>]*id="([^"]+)"[^>]*>(.*?)</section>', doc, re.S)
    found = {}
    for sid, body in sections:
        m = re.search(r'<h2[^>]*>(.*?)</h2>', body, re.S)
        if not m: continue
        title = html.unescape(re.sub(r'<[^>]+>', '', m.group(1))).strip()
        rest = body[m.end():]
        found[sid] = (title, rest)

    OUT.mkdir(parents=True, exist_ok=True)
    written = []
    for sid, (fname, order, desc) in PAGES.items():
        if sid not in found:
            print(f'  !! no source section for "{sid}"')
            continue
        title, body = found[sid]
        md = to_md(body)
        fm = (f'---\ntitle: {title}\ndescription: {desc}\nsidebar:\n  order: {order}\n---\n\n')
        (OUT/fname).write_text(fm + md + '\n')
        written.append((fname, len(md)))
    for f, n in written:
        print(f'  {f:24} {n:6} chars')
    print(f'\n{len(written)}/{len(PAGES)} pages written')
    missing = set(found) - set(PAGES)
    if missing: print('unmapped source sections:', ', '.join(sorted(missing)))

main()
