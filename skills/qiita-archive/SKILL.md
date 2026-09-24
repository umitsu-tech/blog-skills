---
name: qiita-archive
description: Qiita で本公開した記事の後片付けをします。下書きの frontmatter に status・qiita_id・published_at を書き込み、下書きとレビューレポートを記事リポジトリの published/ へ移し、board.md から記事の行を消して完了ログに 1 行足します。
when_to_use: npx qiita publish で本公開を済ませたあと。「アーカイブして」「公開後の後片付けをして」「published に移して」など。qiita-publish-prep の次の段階です。
argument-hint: "<下書きのパス または slug>"
allowed-tools:
  - Bash(python3 *)
  - Bash(sh *)
  - Read
---

# qiita-archive

`/qiita-publish-prep` で変換し、`npx qiita publish` で本公開した記事の後片付けです。slug と qiita_id を下書きに残しておくと、記事を更新したくなったときに `/qiita-publish-prep` を再実行でき、URL も画像のパスも変わりません。

frontmatter の更新とファイルの移動は `qiita_archive.py`、board.md の書き換えは `board.sh` が行います。完了ログの文面は記事ごとに違うので、そこだけを Claude が書きます。

## 共通オプション

スクリプトには、プラグインの設定（userConfig）の値を毎回まとめて渡します。以下では `<共通オプション>` と書きます。

```
--articles-dir "${user_config.articles_dir}" --qiita-dir "${user_config.qiita_dir}" \
--obsidian-dir "${user_config.obsidian_dir}"
```

スクリプトが「環境固有の値が未設定です」で止まったら、`/plugin configure blog-skills@ryuki-plugins` で設定するよう案内して終わります。

## 手順

### 1. 確認

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/qiita-archive/scripts/qiita_archive.py" inspect <下書きのパス | slug> <共通オプション>
```

ファイルは変更しません。slug を渡すと、記事リポジトリ（旧置き場が設定されていればそこも）から下書きを探します。候補が複数またはゼロのときは止まるので、そのことをユーザーに伝えます。

`✗` が出たら、原因を伝えて止まります。よくあるのは次の 2 つです。

- `id が null` … まだ投稿されていません。`npx qiita publish <slug>` を案内します
- `public/<slug>.md がありません` … 先に `/qiita-publish-prep` を実行してもらいます

`private: true` のままなら本公開の前です。本公開が済んだかをユーザーに確認します。限定共有のままアーカイブしたいと言われたときだけ、次の apply に `--allow-private` を付けます。

### 2. 実行

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/qiita-archive/scripts/qiita_archive.py" apply <下書きのパス | slug> <共通オプション> [--allow-private] [--dry-run]
```

下書きの frontmatter に `status: published` / `qiita_id` / `published_at` を書き、下書きとレビューレポート（`*.review.md`）を記事リポジトリの `published/` へ移します。`published_at` に値があればそのまま残すので、再実行しても公開日は変わりません。

### 3. board.md の更新

`${user_config.articles_dir}/board.md` の次の 3 か所を書き換えます。ボードは記事の進行状態の正なので、ファイルの移動とセットで更新します。

- ボードの表から、この記事の行を消す
- 「完了ログ（直近）」の先頭に 1 行足す
- 「最終更新:」の行を、今日の日付と一行の要約にする

完了ログの文面を先に決めます。既存のログを 2〜3 件読んで、粒度と書きぶりをそろえます。日付・記事タイトル・経緯を 1 行にまとめ、限定共有から本公開までの日付、qiita_id、画像の有無、ブログ（mcks.log など）への移植状況、残作業などを入れることが多いです。

文面が決まったら `board.sh` で書き換えます。

```bash
sh "${CLAUDE_PLUGIN_ROOT}/skills/qiita-archive/scripts/board.sh" "${user_config.articles_dir}/board.md" \
  --row '<下書きのファイル名>' --summary '<一行の要約>' [--date YYYY-MM-DD] --log - <<'EOF'
<完了ログの本文>
EOF
```

- `--row` には、表の行が 1 つに決まる文字列を渡します。ふつうは下書きのファイル名です。合う行が無い、または複数あるときは何も書き換えずに止まり、候補の行を出すので、タイトルやパスでキーを絞り直します
- 完了ログの本文には、日付と先頭の「- 」を付けません。日付は `--date` で渡し、省略すると今日になります。既存のログに合わせて本公開の日を使うこともあります
- 本文はシェルに解釈させないよう、クォート付きのヒアドキュメント（`<<'EOF'`）で渡します
- `--dry-run` を付けると、書き換えずに差分だけを確かめられます

board.md を Artifact として発行している場合は、更新後に同じ URL で再発行します。

## やらないこと

- 本文は書き換えません。触るのは frontmatter だけです
- `published/` 以外へは移しません。元のファイルも消しません（移動だけ）
- slug は変えません。S3 のプレフィックスが変わり、画像の URL が切れるためです
- 完了ログの過去の項目は書き換えません（先頭に足すだけ）

## 関連

- 前の段階は `qiita-publish-prep`（投稿前の変換）です
- 記事リポジトリ（`${user_config.articles_dir}`）の README に下書きの frontmatter や運用のルールがあれば、それに従います
