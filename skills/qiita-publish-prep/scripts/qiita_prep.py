#!/usr/bin/env python3
"""articles/ の下書きを Qiita CLI 用に変換する決定論パート。

使い方:
    qiita_prep.py inspect <draft.md> [--json]
    qiita_prep.py apply   <draft.md> [--slug SLUG] [--rename OLD=NEW]...
                          [--skip-sync] [--dry-run]

inspect はファイルを一切変更しない。frontmatter・画像参照・変換対象・警告を
洗い出して報告するだけ。slug の命名、画像の変名案、警告の取捨といった判断は
SKILL.md 側(Claude)が行い、結果を apply の引数として渡す。

apply は inspect と同じ解析を行ったうえで、画像の集約 → S3 同期 →
Markdown 変換 → qiita/public/<slug>.md 出力までを実行する。
"""
from __future__ import annotations

import argparse
import json
import os
from dataclasses import dataclass
import re
import shutil
import subprocess
import sys
from pathlib import Path

# ------------------------------------------------------------------- 環境

def _pick(value, env_name):
    v = value if value is not None else os.environ.get(env_name, "")
    v = v.strip()
    return v or None


def _require(pairs):
    missing = [name for name, v in pairs if not v]
    if missing:
        sys.exit("環境固有の値が未設定です: " + ", ".join(missing)
                 + "\n  プラグインの設定（/plugin configure blog-skills@ryuki-plugins）で入力するか、"
                 "引数または BLOG_SKILLS_* 環境変数で指定してください")


@dataclass(frozen=True)
class Env:
    """環境固有の値。引数（無ければ BLOG_SKILLS_* 環境変数）から組み立て、必要な関数に渡す。"""
    articles: Path            # 記事リポジトリ(drafts/ images/ published/)
    qiita_public: Path        # Qiita CLI ワークスペースの public/
    obsidian: Path | None     # 旧置き場(任意。画像の探索先に加える)
    bucket: str | None        # 画像の同期先 S3 バケット(同期するときだけ必須)
    cdn_base: str | None      # https://<cdn_domain>

    @property
    def images_root(self) -> Path:
        return self.articles / "images"

    @classmethod
    def from_args(cls, args, need_aws: bool) -> "Env":
        articles = _pick(args.articles_dir, "BLOG_SKILLS_ARTICLES_DIR")
        qiita = _pick(args.qiita_dir, "BLOG_SKILLS_QIITA_DIR")
        obsidian = _pick(args.obsidian_dir, "BLOG_SKILLS_OBSIDIAN_DIR")
        bucket = _pick(args.bucket, "BLOG_SKILLS_BUCKET")
        cdn = _pick(args.cdn_domain, "BLOG_SKILLS_CDN_DOMAIN")
        required = [("--articles-dir", articles), ("--qiita-dir", qiita)]
        if need_aws:
            required += [("--bucket", bucket), ("--cdn-domain", cdn)]
        _require(required)
        return cls(
            articles=Path(articles).expanduser().resolve(),
            qiita_public=Path(qiita).expanduser().resolve() / "public",
            obsidian=Path(obsidian).expanduser().resolve() if obsidian else None,
            bucket=bucket,
            cdn_base="https://" + re.sub(r"^https?://", "", cdn).rstrip("/") if cdn else None,
        )

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif"}
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

# Obsidian callout -> Qiita :::note の対応。表に無い種別は通常の引用のまま残す。
CALLOUT_MAP = {
    "note": "info", "info": "info", "tip": "info", "hint": "info", "todo": "info",
    "warning": "warn", "caution": "warn", "attention": "warn",
    "danger": "alert", "error": "alert", "failure": "alert", "bug": "alert",
}


# ---------------------------------------------------------------- frontmatter

def split_frontmatter(text: str):
    """(frontmatter本文, 本文, frontmatterがあったか) を返す。"""
    if not text.startswith("---\n"):
        return "", text, False
    end = text.find("\n---\n", 3)
    if end == -1:
        return "", text, False
    return text[4:end + 1], text[end + 5:], True


def parse_fm(fm: str) -> dict:
    """スカラーと文字列リストだけの最小 YAML パーサ。下書きの frontmatter は
    この2形式しか使わないため、PyYAML 依存を避けてここで完結させる。"""
    data, key = {}, None
    for line in fm.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith((" ", "\t")):
            item = line.strip()
            if item.startswith("- ") and key:
                data.setdefault(key, [])
                if isinstance(data[key], list):
                    data[key].append(unquote_scalar(item[2:].strip()))
            continue
        m = re.match(r"^([A-Za-z_][\w-]*)\s*:\s*(.*)$", line)
        if not m:
            continue
        key, raw = m.group(1), m.group(2).strip()
        data[key] = [] if raw == "" else unquote_scalar(raw)
    return data


def unquote_scalar(v: str):
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1].replace("''", "'") if v[0] == "'" else v[1:-1]
    if v in ("null", "~", ""):
        return None
    if v in ("true", "false"):
        return v == "true"
    return v


def quote_scalar(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    s = str(v)
    if s == "":
        return "''"
    if re.search(r":\s|\s#|^[-?:,\[\]{}#&*!|>'\"%@`]", s) or s.strip() != s:
        return "'" + s.replace("'", "''") + "'"
    return s


def fm_upsert(fm: str, key: str, value) -> str:
    """frontmatter の1キーだけを差し替える(無ければ末尾に追記)。
    他のキーの順序・引用形式・コメントを壊さないため全体を再生成しない。"""
    lines = fm.splitlines()
    out, replaced, i = [], False, 0
    while i < len(lines):
        m = re.match(r"^([A-Za-z_][\w-]*)\s*:", lines[i])
        if m and m.group(1) == key:
            out.append(f"{key}: {quote_scalar(value)}")
            i += 1
            while i < len(lines) and (lines[i].startswith((" ", "\t")) or not lines[i].strip()):
                i += 1  # 旧値がリストだった場合の子行を捨てる
            replaced = True
            continue
        out.append(lines[i])
        i += 1
    if not replaced:
        out.append(f"{key}: {quote_scalar(value)}")
    return "\n".join(out) + "\n"


# ------------------------------------------------------------ fence-aware 走査

def fence_mask(lines):
    """各行がコードフェンス内かどうかの真偽リスト。フェンス行自体も True。
    コードブロック内の ![[...]] や > [!note] を変換しないために必須。"""
    mask, in_fence, marker = [], False, ""
    for line in lines:
        m = re.match(r"^\s*(`{3,}|~{3,})", line)
        if m and not in_fence:
            in_fence, marker = True, m.group(1)[0] * 3
            mask.append(True)
            continue
        if m and in_fence and line.strip().startswith(marker):
            in_fence = False
            mask.append(True)
            continue
        mask.append(in_fence)
    return mask


# --------------------------------------------------------------- 画像参照検出

MD_IMG = re.compile(r"!\[([^\]]*)\]\(\s*<?([^)>\s]+)>?(?:\s+\"[^\"]*\")?\s*\)")
WIKI_IMG = re.compile(r"!\[\[([^\]|]+?)(?:\|([^\]]*))?\]\]")
WIKI_LINK = re.compile(r"(?<!!)\[\[([^\]|]+?)(?:\|([^\]]*))?\]\]")


def is_remote(target: str) -> bool:
    return target.startswith(("http://", "https://", "data:"))


def find_image_refs(body: str):
    """本文中のローカル画像参照を列挙する。外部URLは除外。"""
    lines = body.splitlines()
    mask = fence_mask(lines)
    refs = []
    for idx, line in enumerate(lines):
        if mask[idx]:
            continue
        for m in MD_IMG.finditer(line):
            alt, target = m.group(1), m.group(2)
            if is_remote(target):
                continue
            refs.append({"kind": "md", "raw": m.group(0), "alt": alt,
                         "target": target, "name": os.path.basename(unquote_path(target)),
                         "line": idx + 1})
        for m in WIKI_IMG.finditer(line):
            name = m.group(1).strip()
            if Path(name).suffix.lower() not in IMAGE_EXT:
                continue
            refs.append({"kind": "wiki", "raw": m.group(0), "alt": (m.group(2) or "").strip(),
                         "target": name, "name": os.path.basename(name), "line": idx + 1})
    return refs


def unquote_path(p: str) -> str:
    from urllib.parse import unquote
    return unquote(p)


def resolve_image(env: Env, name: str, target: str, draft_dir: Path, slug: str):
    """画像の実体を探す。SKILL.md の検索順(記事リポジトリ → 旧置き場)に従う。"""
    cand = unquote_path(target)
    probes = []
    if cand.startswith("/"):
        probes.append(Path(cand))
    else:
        probes.append((draft_dir / cand).resolve())
        probes.append((env.articles / cand).resolve())
    if slug:
        probes.append(env.images_root / slug / name)
    for p in probes:
        if p.is_file():
            return p, "direct"
    for root, label in ((env.images_root, "articles/images"), (env.obsidian, "旧置き場")):
        if root is None or not root.is_dir():
            continue
        for p in root.rglob(name):
            if any(part in (".obsidian", ".trash", ".git") for part in p.parts):
                continue
            if p.is_file():
                return p, label
    return None, None


NEEDS_RENAME = re.compile(r"[^\x00-\x7F]|[ \t]|\.{2,}|[^\w.\-]")


def needs_rename(name: str) -> bool:
    stem = Path(name).stem
    return bool(NEEDS_RENAME.search(stem))


# ------------------------------------------------------------------- 本文変換

def transform(body: str, slug: str, url_for: dict):
    """本文を Qiita 記法へ変換し、(新本文, 件数, 警告) を返す。
    url_for: 画像ファイル名 -> CDN URL。未解決の画像は書き換えない。"""
    counts = {"image": 0, "wikilink": 0, "callout": 0, "json_to_js": 0, "h1": 0,
              "comment": 0}
    warns = []
    lines = body.splitlines()

    # 0) Obsidian の %% コメントを除去(執筆メモを Qiita に漏らさない)
    lines, counts["comment"] = strip_obsidian_comments(lines, fence_mask(lines))
    mask = fence_mask(lines)

    # 1) コードフェンスの言語指定(json→js / 未指定の警告)
    out = []
    for idx, line in enumerate(lines):
        m = re.match(r"^(\s*)(`{3,})\s*(\S*)\s*$", line)
        if m and mask[idx]:
            indent, ticks, lang = m.groups()
            is_open = idx == 0 or not mask[idx - 1] or _fence_opens(lines, mask, idx)
            if is_open:
                if lang == "json" and _block_has_comment(lines, idx):
                    line = f"{indent}{ticks}js"
                    counts["json_to_js"] += 1
                elif lang == "":
                    warns.append(f"言語指定なしのコードブロック: {idx + 1}行目")
        out.append(line)
    lines = out
    mask = fence_mask(lines)

    # 2) 画像参照 → CDN URL
    def sub_md_img(m):
        alt, target = m.group(1), m.group(2)
        if is_remote(target):
            return m.group(0)
        url = url_for.get(os.path.basename(unquote_path(target)))
        if not url:
            return m.group(0)
        counts["image"] += 1
        return f"![{alt}]({url})"

    def sub_wiki_img(m):
        name = m.group(1).strip()
        if Path(name).suffix.lower() not in IMAGE_EXT:
            return m.group(0)
        url = url_for.get(os.path.basename(name))
        if not url:
            return m.group(0)
        counts["image"] += 1
        return f"![{(m.group(2) or '').strip()}]({url})"

    def sub_wiki_link(m):
        counts["wikilink"] += 1
        return (m.group(2) or m.group(1)).strip()

    lines = [ln if mask[i] else WIKI_LINK.sub(
        sub_wiki_link, WIKI_IMG.sub(sub_wiki_img, MD_IMG.sub(sub_md_img, ln)))
        for i, ln in enumerate(lines)]

    # 3) Obsidian Callout → Qiita :::note
    lines, n_callout = convert_callouts(lines, fence_mask(lines))
    counts["callout"] = n_callout

    # 4) 先頭 H1 削除(Qiita は frontmatter の title が記事タイトルになる)
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        if re.match(r"^#\s+\S", line):
            del lines[i]
            counts["h1"] = 1
            while i < len(lines) and not lines[i].strip():
                del lines[i]
        break

    # 5) リンクカード候補の警告(行全体が1つのMarkdownリンクだけの行)
    mask = fence_mask(lines)
    for i, line in enumerate(lines):
        if mask[i]:
            continue
        m = re.match(r"^\s*\[([^\]]+)\]\((https?://[^)\s]+)\)\s*$", line)
        if m:
            warns.append(f"リンクカード化候補(単独行のインラインリンク): {i + 1}行目 {m.group(2)}")

    # 6) 連続する空行を畳む(%% 除去や H1 削除の跡地。Markdown 上は等価)
    lines = collapse_blank_lines(lines, fence_mask(lines))

    text = "\n".join(lines).strip("\n")
    return (text + "\n") if text else "", counts, warns


def collapse_blank_lines(lines, mask):
    out, blanks = [], 0
    for i, line in enumerate(lines):
        if not mask[i] and not line.strip():
            blanks += 1
            if blanks > 1:
                continue
        else:
            blanks = 0
        out.append(line)
    return out


def _fence_opens(lines, mask, idx):
    """idx のフェンス行が開始側かどうか(直前まで遡って判定)。"""
    depth = 0
    for j in range(idx):
        if re.match(r"^\s*(`{3,}|~{3,})", lines[j]) and mask[j]:
            depth ^= 1
    return depth == 0


def _block_has_comment(lines, open_idx):
    for line in lines[open_idx + 1:]:
        if re.match(r"^\s*(`{3,}|~{3,})\s*$", line):
            return False
        if re.search(r"(^|\s)//", line) or "/*" in line:
            return True
    return False


def strip_obsidian_comments(lines, mask):
    """Obsidian の %% コメント(ブロック/インライン)を落とす。下書きには
    執筆メモが %% で埋め込まれているため、Qiita 出力に漏らしてはいけない。"""
    out, i, n, in_block = [], 0, 0, False
    while i < len(lines):
        line = lines[i]
        if mask[i] and not in_block:
            out.append(line)
            i += 1
            continue
        if in_block:
            if line.strip() == "%%":
                in_block = False
            i += 1
            continue
        if line.strip() == "%%":
            in_block, n = True, n + 1
            i += 1
            continue
        stripped = re.sub(r"%%.*?%%", "", line)
        if stripped != line:
            n += 1
            stripped = re.sub(r"[ \t]{2,}", " ", stripped).rstrip()
            if not stripped.strip():
                i += 1
                continue
        out.append(stripped)
        i += 1
    return out, n


CALLOUT_HEAD = re.compile(r"^\s*>\s*\[!(\w+)\][-+]?\s*(.*)$")


def convert_callouts(lines, mask):
    out, i, n = [], 0, 0
    while i < len(lines):
        m = CALLOUT_HEAD.match(lines[i]) if not mask[i] else None
        if not m:
            out.append(lines[i])
            i += 1
            continue
        kind, title = m.group(1).lower(), m.group(2).strip()
        body, i = [], i + 1
        while i < len(lines) and re.match(r"^\s*>", lines[i]):
            body.append(re.sub(r"^\s*>\s?", "", lines[i]))
            i += 1
        qiita = CALLOUT_MAP.get(kind)
        if qiita is None:
            # 対応表に無い種別は通常の引用として残す(情報を落とさない)
            if title:
                out.append(f"> **{title}**")
            out.extend(f"> {b}" if b else ">" for b in body)
        else:
            out.append(f":::note {qiita}")
            if title:
                out.append(f"**{title}**")
                out.append("")
            out.extend(body)
            out.append(":::")
            n += 1
    return out, n


# ------------------------------------------------------------ Qiita frontmatter

# Qiita CLI が自分で書き込むフィールド。既存の出力ファイルがあれば値を引き継ぐ。
CLI_MANAGED = ("updated_at", "posting_campaign_uuid", "agreed_posting_campaign_term")
CLI_DEFAULT = {"updated_at": "''", "posting_campaign_uuid": "null",
               "agreed_posting_campaign_term": "false"}


def read_existing_output(path: Path) -> dict:
    """既存の qiita/public/<slug>.md から Qiita CLI 管理フィールドを読む。"""
    if not path.is_file():
        return {}
    fm_text, _, ok = split_frontmatter(path.read_text(encoding="utf-8"))
    if not ok:
        return {}
    raw = {}
    for line in fm_text.splitlines():
        m = re.match(r"^([A-Za-z_][\w-]*)\s*:\s*(.*)$", line)
        if m:
            raw[m.group(1)] = m.group(2).strip()
    return raw


def build_qiita_fm(title, tags, qiita_id, private, organization, existing=None):
    existing = existing or {}
    lines = [f"title: {quote_scalar(title)}", "tags:"]
    lines += [f"  - {quote_scalar(t)}" for t in tags]
    lines += [
        f"private: {'true' if private else 'false'}",
        f"updated_at: {existing.get('updated_at', CLI_DEFAULT['updated_at'])}",
        f"id: {quote_scalar(qiita_id) if qiita_id else 'null'}",
        f"organization_url_name: {quote_scalar(organization) if organization else 'null'}",
        "slide: false",
        "ignorePublish: false",
    ]
    for k in ("posting_campaign_uuid", "agreed_posting_campaign_term"):
        lines.append(f"{k}: {existing.get(k, CLI_DEFAULT[k])}")
    return "---\n" + "\n".join(lines) + "\n---\n"


# ------------------------------------------------------------------- 解析まとめ

def analyze(env: Env, draft: Path, slug_override=None):
    text = draft.read_text(encoding="utf-8")
    fm_text, body, has_fm = split_frontmatter(text)
    fm = parse_fm(fm_text)
    slug = slug_override or fm.get("slug")
    tags = fm.get("tags") or []
    if isinstance(tags, str):
        tags = [t.strip() for t in tags.split(",") if t.strip()]

    issues = []
    if not has_fm:
        issues.append("frontmatter がありません")
    if not slug:
        issues.append("slug がありません → 記事から命名して apply の --slug で渡す")
    elif not SLUG_RE.match(slug):
        issues.append(f"slug が [a-z0-9-] 以外を含みます: {slug}")
    if not fm.get("title"):
        issues.append("title がありません(本文 H1 からの自動採用はしない。frontmatter に書く)")
    if not tags:
        issues.append("tags が空です(Qiita は1個以上必須)")
    if len(tags) > 5:
        issues.append(f"tags が {len(tags)} 個あります(Qiita は最大5個)")
    for t in tags:
        if "/" in str(t):
            issues.append(f"タグに / が含まれます: {t}")

    refs, seen = [], {}
    for r in find_image_refs(body):
        path, where = resolve_image(env, r["name"], r["target"], draft.parent, slug or "")
        r["resolved"] = str(path) if path else None
        r["found_in"] = where
        r["needs_rename"] = needs_rename(r["name"])
        refs.append(r)
        if path:
            seen[r["name"]] = path
    # 同じファイル名を複数の記法で参照している場合、どれか1つ解決できれば足りる
    # (置換は basename をキーに行うため)。所在不明の二重計上を防ぐ。
    for r in refs:
        if not r["resolved"] and r["name"] in seen:
            r["resolved"] = str(seen[r["name"]])
            r["found_in"] = "同名の別参照から解決"
    return {"draft": str(draft), "frontmatter": fm, "slug": slug, "tags": tags,
            "title": fm.get("title"), "qiita_id": fm.get("qiita_id"),
            "status": fm.get("status"), "issues": issues, "images": refs,
            "fm_text": fm_text, "body": body, "resolved": seen}


# ---------------------------------------------------------------------- 出力

def cmd_inspect(env: Env, args):
    a = analyze(env, Path(args.draft).expanduser().resolve(), args.slug)
    if args.json:
        payload = {k: v for k, v in a.items() if k not in ("fm_text", "body", "resolved")}
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0
    print(f"下書き : {a['draft']}")
    print(f"title  : {a['title']}")
    print(f"slug   : {a['slug'] or '(なし)'}")
    print(f"status : {a['status']}   qiita_id: {a['qiita_id'] or '(なし=新規)'}")
    print(f"tags   : {', '.join(map(str, a['tags'])) or '(なし)'}")
    print()
    if a["issues"]:
        print("■ 要対応")
        for s in a["issues"]:
            print(f"  - {s}")
        print()
    print(f"■ 画像参照 {len(a['images'])} 件")
    for r in a["images"]:
        state = f"OK  {r['found_in']}" if r["resolved"] else "MISSING"
        flag = "  [要変名]" if r["needs_rename"] else ""
        print(f"  L{r['line']:>4} {r['name']:<40} {state}{flag}")
        if r["resolved"]:
            print(f"        {r['resolved']}")
    missing = [r for r in a["images"] if not r["resolved"]]
    rename = [r for r in a["images"] if r["needs_rename"]]
    print()
    _, counts, warns = transform(a["body"], a["slug"] or "slug", {})
    print("■ 変換対象(件数)")
    print(f"  Wikilink テキスト化: {counts['wikilink']} / Callout: {counts['callout']} "
          f"/ json→js: {counts['json_to_js']} / H1削除: {counts['h1']} "
          f"/ %%コメント除去: {counts['comment']}")
    if warns:
        print()
        print("■ 警告")
        for w in warns:
            print(f"  - {w}")
    print()
    print("■ 次のアクション(判断が要るもの)")
    if not a["slug"]:
        print("  - slug を命名して apply --slug で渡す")
    if rename:
        print(f"  - 変名提案が必要な画像 {len(rename)} 件 → apply --rename OLD=NEW で渡す")
        for r in rename:
            print(f"      {r['name']}")
    if missing:
        print(f"  - 所在不明の画像 {len(missing)} 件 → ユーザー確認")
    if not (a["issues"] or rename or missing):
        print("  - なし。そのまま apply して良い")
    return 0


def run(cmd, dry, check=True):
    print(f"  $ {' '.join(cmd)}")
    if dry:
        return 0, ""
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.stdout.strip():
        print("\n".join("    " + l for l in p.stdout.strip().splitlines()[:20]))
    if check and p.returncode != 0:
        print(f"    ! 失敗: {p.stderr.strip()[:400]}", file=sys.stderr)
    return p.returncode, p.stdout


def cmd_apply(env: Env, args):
    draft = Path(args.draft).expanduser().resolve()
    dry = args.dry_run
    renames = dict(r.split("=", 1) for r in args.rename)

    a = analyze(env, draft, args.slug)
    slug = a["slug"]
    if not slug:
        print("ERROR: slug がありません。--slug で渡してください。", file=sys.stderr)
        return 1
    if not SLUG_RE.match(slug):
        print(f"ERROR: slug が不正です: {slug}", file=sys.stderr)
        return 1
    blocking = [s for s in a["issues"] if not s.startswith("slug ")]
    if blocking and not args.force:
        print("ERROR: 先に解消してください(--force で強行可):", file=sys.stderr)
        for s in blocking:
            print(f"  - {s}", file=sys.stderr)
        return 1

    print(f"■ slug: {slug}")
    dest_dir = env.images_root / slug

    # 1) 変名(原本 + 下書き本文の参照を同時に書き換える)
    body, fm_text = a["body"], a["fm_text"]
    if renames:
        print("■ 画像の変名")
        for old, new in renames.items():
            src = a["resolved"].get(old)
            if not src:
                print(f"  ! 原本が見つからないためスキップ: {old}", file=sys.stderr)
                continue
            src = Path(src)
            tgt = src.with_name(new)
            print(f"  {src} -> {tgt.name}")
            if not dry:
                if tgt.exists() and tgt != src:
                    print(f"  ! 変名先が既に存在: {tgt}", file=sys.stderr)
                    return 1
                src.rename(tgt)
            body = body.replace(old, new)
            a["resolved"][new] = tgt
            a["resolved"].pop(old, None)
        if not dry:
            draft.write_text("---\n" + fm_text + "---\n" + body, encoding="utf-8")

    # 2) slug を下書き frontmatter に書き戻す
    if a["frontmatter"].get("slug") != slug:
        print(f"■ 下書きの frontmatter に slug を追記: {slug}")
        fm_text = fm_upsert(fm_text, "slug", slug)
        if not dry:
            draft.write_text("---\n" + fm_text + "---\n" + body, encoding="utf-8")

    # 3) 画像を articles/images/<slug>/ へ集約
    copied = skipped = 0
    if args.no_copy:
        print("■ 画像の集約: --no-copy のためスキップ")
    elif a["resolved"]:
        print(f"■ 画像を {dest_dir} へ集約")
        if not dry:
            dest_dir.mkdir(parents=True, exist_ok=True)
        for name, src in sorted(a["resolved"].items()):
            src, tgt = Path(src), dest_dir / name
            if src.resolve() == tgt.resolve():
                skipped += 1
                continue
            if tgt.exists():
                print(f"  = 既存のため上書きしない: {name}")
                skipped += 1
                continue
            print(f"  + {src} -> {tgt}")
            if not dry:
                shutil.copy2(src, tgt)
            copied += 1

    # 4) S3 同期
    synced = False
    if args.skip_sync:
        print("■ S3 同期: --skip-sync のためスキップ")
    elif not dest_dir.is_dir() and not dry:
        print("■ S3 同期: 画像が無いためスキップ")
    else:
        print("■ S3 同期")
        rc, _ = run(["aws", "sts", "get-caller-identity"], dry, check=False)
        if rc != 0:
            print("  ! AWS 認証が切れています。`aws login` の後に再実行してください。", file=sys.stderr)
            return 2
        rc, _ = run(["aws", "s3", "sync", str(dest_dir) + "/",
                     f"s3://{env.bucket}/{slug}/", "--exclude", ".DS_Store", "--size-only"], dry)
        if rc != 0:
            return 2
        synced = True
        first = next(iter(sorted(a["resolved"])), None)
        if first and not dry:
            url = f"{env.cdn_base}/{slug}/{first}"
            rc, out = run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                           "-I", url], dry, check=False)
            print(f"    CDN 応答 {out.strip()} : {url}")

    # 5) 本文変換
    url_for = {n: f"{env.cdn_base}/{slug}/{n}" for n in a["resolved"]}
    new_body, counts, warns = transform(body, slug, url_for)

    # 6) 出力
    out_path = Path(args.out).expanduser() if args.out else env.qiita_public / f"{slug}.md"
    # 引き継ぎ元は常に本来の出力先(--out はプレビュー用の書き出し先にすぎない)
    existing = read_existing_output(env.qiita_public / f"{slug}.md")
    qiita_id = args.id or a["qiita_id"] or unquote_scalar(existing.get("id", ""))
    # private は既存の出力があればその値を引き継ぐ(公開済み記事を勝手に限定共有へ
    # 戻さないため)。新規は true。--public / --private で明示上書きできる。
    if args.public:
        private = False
    elif args.private:
        private = True
    elif "private" in existing:
        private = existing["private"] != "false"
    else:
        private = True
    organization = args.organization
    if organization is None and existing.get("organization_url_name") not in (None, "null"):
        organization = unquote_scalar(existing["organization_url_name"])
    fm_out = build_qiita_fm(a["title"], a["tags"], qiita_id,
                            private, organization, existing)
    print(f"■ 出力: {out_path}{' (既存を上書き)' if out_path.exists() else ''}")
    if not dry:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        # Qiita CLI が書き出すファイルに合わせ、frontmatter の直後から本文を始める
        out_path.write_text(fm_out + new_body, encoding="utf-8")

    missing = [r["name"] for r in a["images"] if not r["resolved"]]
    print()
    print("■ サマリ")
    print(f"  画像: 集約 {copied} / 既存スキップ {skipped} / 所在不明 {len(missing)}"
          f" / S3同期 {'済' if synced else '未'}")
    print(f"  変換: CDN URL置換 {counts['image']} / Wikilink {counts['wikilink']}"
          f" / Callout {counts['callout']} / json→js {counts['json_to_js']}"
          f" / H1削除 {counts['h1']}")
    print(f"  frontmatter: private={'true' if private else 'false'}, "
          f"id={qiita_id or 'null'}, organization={organization or 'null'}")
    if counts["comment"]:
        print(f"  %% コメント除去: {counts['comment']} 箇所")
    if not private:
        print("  ⚠ private: false で出力しています(本公開扱い)")
    for w in warns:
        print(f"  ⚠ {w}")
    for m in missing:
        print(f"  ⚠ 画像が見つかりません: {m}")
    if dry:
        print("\n  (--dry-run のため実際の書き込みは行っていません)")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    g = common.add_argument_group("環境固有の値(未指定なら BLOG_SKILLS_* 環境変数を使う)")
    g.add_argument("--articles-dir", help="記事リポジトリ(drafts/ images/ published/ がある場所)")
    g.add_argument("--qiita-dir", help="Qiita CLI ワークスペース(public/ に出力する)")
    g.add_argument("--obsidian-dir", help="旧置き場(任意。画像の探索先に加える)")
    g.add_argument("--bucket", help="画像の同期先 S3 バケット名(apply で必須)")
    g.add_argument("--cdn-domain", help="CloudFront のドメイン(apply で必須。例 images.example.com)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    i = sub.add_parser("inspect", parents=[common], help="解析のみ(ファイルを変更しない)")
    i.add_argument("draft")
    i.add_argument("--slug", help="frontmatter に slug が無い場合の仮指定")
    i.add_argument("--json", action="store_true")
    i.set_defaults(func=cmd_inspect)

    p = sub.add_parser("apply", parents=[common], help="集約・S3同期・変換・出力を実行")
    p.add_argument("draft")
    p.add_argument("--slug", help="slug(下書きの frontmatter にも書き戻す)")
    p.add_argument("--rename", action="append", default=[], metavar="OLD=NEW",
                   help="画像の変名(原本と下書きの参照を同時に書き換える)")
    p.add_argument("--id", help="既存記事の qiita_id(未指定なら下書きの値)")
    p.add_argument("--organization", help="organization_url_name")
    p.add_argument("--public", action="store_true",
                   help="private: false で出力(本公開。ユーザー確認必須)")
    p.add_argument("--private", action="store_true",
                   help="private: true を強制(既定は既存出力の値を引き継ぐ、無ければ true)")
    p.add_argument("--skip-sync", action="store_true", help="S3 同期をスキップ")
    p.add_argument("--no-copy", action="store_true",
                   help="画像の集約をスキップ(--out と併せて副作用なしのプレビューに使う)")
    p.add_argument("--force", action="store_true", help="frontmatter の不備を無視して続行")
    p.add_argument("--out", help="出力先を差し替える(既定は qiita/public/<slug>.md)")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_apply)

    args = ap.parse_args()
    env = Env.from_args(args, need_aws=(args.cmd == "apply" and not args.skip_sync))
    return args.func(env, args)


if __name__ == "__main__":
    sys.exit(main())
