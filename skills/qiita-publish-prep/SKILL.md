---
name: qiita-publish-prep
description: 記事リポジトリの下書きを Qiita CLI 用に変換し、Qiita CLI ワークスペースの public/<slug>.md に出力します。画像は S3 + CloudFront に同期して Markdown 内のパスを CDN の URL に置き換え、Wikilink・Callout・Obsidian のコメント・frontmatter を Qiita の書式に直します。投稿（npx qiita publish）はしません。
when_to_use: 下書きを Qiita に限定共有で投稿する前の準備と、公開済みの記事を直して出力し直すとき。「Qiita 用に変換して」「投稿の準備をして」「Qiita に出せる形にして」など。本公開のあとの後片付けは qiita-archive が受け持ちます。
argument-hint: "<下書きのパス>"
allowed-tools:
  - Bash(python3 *)
  - Read
  - Glob
---

# qiita-publish-prep

記事リポジトリの下書きを Qiita CLI が読める形に変換し、画像を S3（`${user_config.bucket}`）へ同期して CloudFront（`${user_config.cdn_domain}`）の URL で参照させます。

変換・検証・ファイル操作は `qiita_prep.py` が行います。Claude が受け持つのは、スクリプトが自力で決められない 3 つの判断（slug、画像の英語名、organization）です。

## 前提と共通オプション

環境固有の値はプラグインの設定（userConfig）から受け取ります。

- 記事リポジトリ: `${user_config.articles_dir}`（下書きは drafts/ の下、画像の原本は images/<slug>/）
- Qiita CLI ワークスペース: `${user_config.qiita_dir}`（public/ に出力する）
- 旧置き場（任意。記事リポジトリへ移す前の画像や下書きがある場所）: `${user_config.obsidian_dir}`
- 画像の配信: S3 バケット `${user_config.bucket}` と CloudFront `${user_config.cdn_domain}`（構築済みであること）

スクリプトには毎回、次のオプションをまとめて渡します。以下では `<共通オプション>` と書きます。

```
--articles-dir "${user_config.articles_dir}" --qiita-dir "${user_config.qiita_dir}" \
--obsidian-dir "${user_config.obsidian_dir}" --bucket "${user_config.bucket}" \
--cdn-domain "${user_config.cdn_domain}"
```

スクリプトが「環境固有の値が未設定です」で止まったら、`/plugin configure blog-skills@ryuki-plugins` で設定するよう案内して終わります。AWS の認証が切れているとスクリプトが検出して止まるので、ログインし直してから再実行するよう案内します。

## 手順

### 1. 解析

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/qiita-publish-prep/scripts/qiita_prep.py" inspect <下書きのパス> <共通オプション>
```

frontmatter、画像の参照とその所在、変換の対象の件数、警告を出します。ファイルは変更しません。`--json` を付けると機械可読の出力になります。引数が無いときやファイルが無いときは、対象のパスをユーザーに聞いて終わります。

### 2. 判断

inspect の出力を見て、次の 3 つを決めます。

- slug … frontmatter に無いときだけ決めます。S3 のプレフィックスになり、投稿したあとは変えられません。記事を読んで候補を 2〜4 個出し、ユーザーに選んでもらいます。タイトルの直訳ではなく、症状や解決手段から意味が分かる名前にします。使える文字は `[a-z0-9-]` です
- 画像の変名 … inspect が `[要変名]` を付けた画像（日本語・空白・記号を含むファイル名）について、記事の文脈から意味の通る英語名を 2〜4 個提案します。スクリーンショットは撮影日ではなく、画像の内容や記事の中での役割に合った名前にします。決まった名前を `--rename 旧=新` で渡すと、原本と下書き内の参照が同時に書き換わります
- organization_url_name … 付けるかどうかをユーザーに確認します。記事ごとに気まぐれに付ける方針で、既存の出力ファイルがあればその値が引き継がれます

所在不明の画像が出たときは、外部の画像を意図して使っている場合もあるので、参照を消さずにユーザーに確認します。

### 3. 実行

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/qiita-publish-prep/scripts/qiita_prep.py" apply <下書きのパス> <共通オプション> \
  [--slug SLUG] [--rename 旧=新]... [--organization NAME] [--skip-sync] [--dry-run]
```

slug の書き戻し、画像の集約、S3 への同期、本文の変換、`public/<slug>.md` への出力までを行います。

- 上書きする前に結果を見たいときは、`--out` で出力先を差し替えます。副作用なしで変換結果だけを見るなら `--out /tmp/x.md --skip-sync --no-copy` です
- `private` は既存の出力ファイルの値を引き継ぎ、無ければ `true`（限定共有）です。公開済みの記事を作り直しても、限定共有には戻りません

### 4. 警告の扱い

apply が出す `⚠` は、変換はせずに知らせるだけの項目です。中身を見て対応を決めます。

- 言語指定の無いコードブロック … 言語を足すかをユーザーに確認します
- リンクカードの候補（単独行のインラインリンク） … 素の URL の行にするかを確認します
- 画像が見つかりません … 所在をユーザーと一緒に探します

### 5. 完了報告

出力先、S3 のプレフィックス、CDN のベース URL、apply のサマリをそのまま伝えたうえで、次の流れを案内します。

```
1. プレビュー      cd ${user_config.qiita_dir} && npx qiita preview   # localhost:8888
2. 限定共有で投稿  npx qiita publish <slug>                          # private: true のまま
3. Qiita 上で表示を確認（限定共有中の URL は https://qiita.com/<user>/private/<id> の形。
   /items/<id> は本公開後の URL なので、限定共有中は案内しない）
4. 本公開          public/<slug>.md の private を false にして npx qiita publish <slug>
5. 後片付け        /qiita-archive <下書きのパス>
```

## やらないこと

- `npx qiita publish` は実行しません。投稿はユーザーが手で行います
- `private: false` を勝手に設定しません。`--public` は、ユーザーが本公開の出力をはっきり頼んだときだけ使います
- S3 上のファイルは消しません。過去の記事の画像 URL が切れるためです（追加と更新だけ）
- slug を後から変える提案はしません。S3 のプレフィックスが変わり、画像の URL が切れるためです
- 下書きの本文は書き換えません。スクリプトが触るのは、frontmatter への slug の追記と、変名に伴う画像参照の書き換えだけです
- 画像を同じファイル名のまま差し替えません。Qiita の画像プロキシ（imgix）が差し替え前の画像をキャッシュするので、ファイル名も変えます

## スクリプトが行う変換

判断の材料として把握しておくための一覧です。ここにある変換を手で追う必要はありません。

| 処理 | 内容 |
|---|---|
| frontmatter の検証 | slug の形式、title、タグ 1〜5 個・`/` 不可 |
| 画像の所在 | 記事リポジトリの images/ → 旧置き場の順に探す。相対・絶対・Wikilink のどの記法も対象 |
| 画像の集約 | 記事リポジトリの `images/<slug>/` へコピー（既存のファイルは上書きしない） |
| S3 への同期 | `aws s3 sync --size-only`。直後に CDN の応答コードを 1 件確認 |
| 画像のパス | ローカルの参照を `https://${user_config.cdn_domain}/<slug>/<file>` に置き換え |
| Wikilink | `[[a]]` → `a`、`[[a\|b]]` → `b`（消さずにテキストにする） |
| Callout | `> [!note\|info\|tip]` → `:::note info`、`warning\|caution` → `warn`、`danger\|error\|failure` → `alert`。対応表に無い種別は普通の引用のまま |
| Obsidian のコメント | `%% ... %%`（ブロック・インライン）を除く。執筆メモを Qiita に出さないため |
| コードブロック | コメントを含む ` ```json ` を ` ```js ` にする（Qiita のハイライトが崩れるため） |
| H1 の削除 | frontmatter の title が記事のタイトルになるので、先頭の `# ` 行を消す |
| フェンスの保護 | コードブロックの中身は変換しない |
| Qiita の frontmatter | 生成する。`updated_at` / `posting_campaign_uuid` / `agreed_posting_campaign_term` は既存の出力から引き継ぐ |

## 関連

- 本公開のあとの後片付けは `qiita-archive` です
- 記事リポジトリ（`${user_config.articles_dir}`）の README に下書きの frontmatter や運用のルールがあれば、それに従います
