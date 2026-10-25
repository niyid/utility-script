#!/usr/bin/env python3
"""
Add the usability-test screenshots + video to the speso repo, the article and the README.

  python3 update_speso_usability.py --repo ~/git/speso --assets ~/Downloads [--dry-run]

--assets is the folder holding speso-usability-test.mp4 and speso-screenshots.zip
(or pass --video / --zip individually).

What it does (idempotent: safe to re-run, it replaces its own blocks):
  1. usability/screens/NN-name.png   <- unzipped, renamed screenshots
     usability/speso-usability-test.mp4
  2. speso-article.html : inserts a block between
        <!-- usability:start --> ... <!-- usability:end -->
     If the markers are absent, inserts before --before REGEX, else before </article>,
     else </main>, else </body>. Move the markers later if you want it elsewhere.
  3. README.md : same, as a "## Usability test" section, before "## Verification status"
     if present, else appended.
Nothing is committed or pushed. A .bak copy of each edited file is kept unless --no-backup.
"""
import argparse, difflib, re, shutil, sys, zipfile
from pathlib import Path

CAPTIONS = {
 "title":("Title","The Speso first-run usability test: thin wallet plus one testnet node."),
 "usage":("Discoverability","Running the wallet with no arguments prints one dense usage line."),
 "new":("Create a wallet","Wallet creation warns plainly that there is no recovery."),
 "me":("Get your address","Your address needs no password."),
 "status":("Check the node","status prints raw field names and units (score: 10000, supply: 100000)."),
 "rate":("Read the rate","rate shows 1 Sm = 1.0000 GBU, the five indicators and the oracle state."),
 "balance_alice_empty":("Check balance","A new wallet starts at zero."),
 "quote":("Price in GBU","quote shows the cost now and the worst case after 1, 3 and 6 blocks."),
 "send":("Send payment","Funding Alice from the miner wallet."),
 "tx_short_id":("Track it","tx reports the funding payment confirmed, with height and confirmations."),
 "balance_alice":("Balance updated","Alice now holds Sm 5."),
 "sendgbu_auto":("GBU payment","sendgbu with the 'auto' ceiling guards against a falling score."),
 "balance_bob":("Receiver balance","Bob received Sm 2."),
 "send_while_paused":("Pending state","With mining paused, a payment waits in the mempool."),
 "tx_pending":("Pending state","tx reports 'pending'."),
 "status_mempool":("Pending state","status shows mempool: 1."),
 "tx_confirmed":("Confirmed","Mining resumed: the same payment confirms at the next block."),
 "node_console":("Node console","The node's own console: help, chain, balance."),
 "err_overspend":("Error: overspend","Rejected, but the message lists four possible causes."),
 "err_badaddr":("Error: bad address","Short and clear, though it does not say what a valid address looks like."),
 "err_fraction":("Error: fraction","The best message in the tool: it says what is wrong and the limit."),
 "err_missing":("Error: missing args","'missing argument' does not say which one, or show usage."),
 "err_nowallet":("Error: no wallet","Clear."),
 "err_wrongpw":("Error: wrong password","Clear."),
 "err_nonode":("Error: node down","'error: null' is the one genuinely unhelpful message."),
 "findings":("Findings","Summary card from the video."),
}
FINDINGS_GOOD = [
 "The whole flow worked first time: create wallet, fund, send, GBU quote, GBU payment, confirmation.",
 "Wallet creation warns plainly that there is no recovery.",
 "Errors for fractions, wrong password and a missing wallet say exactly what is wrong.",
]
FINDINGS_BAD = [
 "Node unreachable prints <code>error: null</code>, with no hint to check the RPC URL.",
 "<code>missing argument</code> does not say which argument, or show that command's usage.",
 "An overspend rejection lists four possible causes in one string.",
 "<code>status</code> mixes raw units (<code>score: 10000</code>) with formatted values; the oracle line is long and jargon-heavy.",
 "The node console exits when stdin closes, so running it in the background needs a held-open stdin.",
]
TESTED = ("Tested with JDK 21 using <code>build.sh</code>; the three test suites pass. "
          "One mining node on testnet plus the thin wallet (<code>Cli</code>), with "
          "<code>-Dspeso.initbits=10 -Dspeso.blockms=1500 -Dspeso.retarget=10</code>. "
          "The Gradle build and the live World Bank / IMF feed were not exercised.")
START, END = "usability:start", "usability:end"

def clean_name(fname):
    stem = Path(fname).stem
    m = re.match(r"^(\d+)[ab]?_(.+)$", stem)
    if not m: return None
    n, rest = int(m.group(1)), re.sub(r"^\d+[ab]?_", "", m.group(2))
    return (99 if n == 999 else n), rest

def prepare_assets(repo, zpath, vpath, dry):
    out = repo / "usability"; shots = out / "screens"
    items = []
    with zipfile.ZipFile(zpath) as z:
        for info in sorted(z.namelist()):
            if not info.lower().endswith(".png"): continue
            cn = clean_name(Path(info).name)
            if not cn: print("  skip", info); continue
            n, name = cn
            dest = f"{n:02d}-{name}.png"
            items.append((n, name, dest))
            if not dry:
                shots.mkdir(parents=True, exist_ok=True)
                (shots / dest).write_bytes(z.read(info))
    if not dry:
        out.mkdir(parents=True, exist_ok=True)
        shutil.copy2(vpath, out / "speso-usability-test.mp4")
    print(f"  {len(items)} screenshots -> usability/screens/, video -> usability/speso-usability-test.mp4")
    return sorted(items)

def article_block(items):
    figs = []
    for n, name, dest in items:
        if name in ("title", "findings"): continue
        label, cap = CAPTIONS.get(name, (name.replace("_", " ").title(), ""))
        figs.append(f'<figure><a href="usability/screens/{dest}"><img loading="lazy" src="usability/screens/{dest}" alt="{label}: {cap}"></a>'
                    f'<figcaption><b>{n}. {label}.</b> {cap}</figcaption></figure>')
    poster = next((d for _, nm, d in items if nm == "title"), None)
    poster_attr = f' poster="usability/screens/{poster}"' if poster else ""
    good = "".join(f"<li>{t}</li>" for t in FINDINGS_GOOD)
    bad = "".join(f"<li>{t}</li>" for t in FINDINGS_BAD)
    return f"""<!-- {START} -->
<section class="usability">
<style>
.usability video{{width:100%;max-width:960px;height:auto;border-radius:8px;display:block;margin:1rem 0}}
.usability .grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:1rem;margin-top:1rem}}
.usability figure{{margin:0}}
.usability figure img{{width:100%;height:auto;border-radius:6px;border:1px solid rgba(128,128,128,.35)}}
.usability figcaption{{font-size:.85em;margin-top:.3rem}}
</style>
<h2>Usability test: a first run, screen by screen</h2>
<p>{TESTED}</p>
<video controls preload="metadata"{poster_attr}>
<source src="usability/speso-usability-test.mp4" type="video/mp4">
Your browser does not play MP4. <a href="usability/speso-usability-test.mp4">Download the video</a>.
</video>
<h3>What worked</h3><ul>{good}</ul>
<h3>Rough edges</h3><ul>{bad}</ul>
<details><summary>All {len(figs)} screens</summary>
<div class="grid">
{chr(10).join(figs)}
</div></details>
</section>
<!-- {END} -->"""

def readme_block(items):
    rows = []
    for n, name, dest in items:
        if name in ("title", "findings"): continue
        label, cap = CAPTIONS.get(name, (name, ""))
        rows.append(f"| {n} | [{label}](usability/screens/{dest}) | {cap} |")
    good = "\n".join(f"- {re.sub('<[^>]+>', '`', t)}" for t in FINDINGS_GOOD)
    bad = "\n".join(f"- {re.sub('<[^>]+>', '`', t)}" for t in FINDINGS_BAD)
    tested = re.sub("<[^>]+>", "`", TESTED)
    return f"""<!-- {START} -->
## Usability test

{tested}

Video: [`usability/speso-usability-test.mp4`](usability/speso-usability-test.mp4)

**What worked**

{good}

**Rough edges**

{bad}

| # | Screen | What it shows |
|---|---|---|
{chr(10).join(rows)}
<!-- {END} -->"""

def put_block(text, block, before_regex, md=False):
    pat = re.compile(rf"<!-- {START} -->.*?<!-- {END} -->", re.S)
    if pat.search(text):
        return pat.sub(lambda m: block, text, count=1), "replaced existing block"
    anchors = [before_regex] if before_regex else []
    anchors += ([r"^## Verification status"] if md else [r"</article>", r"</main>", r"</body>"])
    for a in anchors:
        m = re.search(a, text, re.M | re.I)
        if m: return text[:m.start()] + block + "\n\n" + text[m.start():], f"inserted before {a!r}"
    return text.rstrip("\n") + "\n\n" + block + "\n", "appended at end"

def edit(path, block, before, md, dry, backup):
    old = path.read_text(encoding="utf-8")
    new, how = put_block(old, block, before, md)
    print(f"  {path.name}: {how}")
    if dry:
        d = list(difflib.unified_diff(old.splitlines(), new.splitlines(), path.name, path.name + " (new)", lineterm="", n=1))
        print("\n".join(d[:40]) + ("\n  ..." if len(d) > 40 else ""))
        return
    if backup: shutil.copy2(path, path.with_suffix(path.suffix + ".bak"))
    path.write_text(new, encoding="utf-8")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default="."); ap.add_argument("--assets", default=str(Path.home() / "Downloads"))
    ap.add_argument("--zip"); ap.add_argument("--video"); ap.add_argument("--article", default="speso-article.html")
    ap.add_argument("--before", help="regex: insert the article block before the first match")
    ap.add_argument("--dry-run", action="store_true"); ap.add_argument("--no-backup", action="store_true")
    a = ap.parse_args()
    repo = Path(a.repo).expanduser().resolve()
    z = Path(a.zip) if a.zip else Path(a.assets).expanduser() / "speso-screenshots.zip"
    v = Path(a.video) if a.video else Path(a.assets).expanduser() / "speso-usability-test.mp4"
    art, rd = repo / a.article, repo / "README.md"
    for p in (z, v, art, rd):
        if not p.exists(): sys.exit(f"missing: {p}")
    print(("DRY RUN " if a.dry_run else "") + f"repo {repo}")
    items = prepare_assets(repo, z, v, a.dry_run)
    edit(art, article_block(items), a.before, False, a.dry_run, not a.no_backup)
    edit(rd, readme_block(items), None, True, a.dry_run, not a.no_backup)
    print("done. Review with: git status && git diff")

if __name__ == "__main__":
    main()
