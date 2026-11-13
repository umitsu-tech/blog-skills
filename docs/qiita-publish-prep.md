# qiita-publish-prep（Qiita 投稿準備）

記事リポジトリで書いた下書きを Qiita CLI が読める形に変換しつつ、画像を S3 へ同期して Markdown 内の参照を CDN の URL に置き換えます。

![qiita-publish-prepの仕組み](../images/qiita-publish-prep-flow.png)

## スクリプトとスキルの分担

変換・検証・ファイル操作は `scripts/qiita_prep.py` に切り出してあり、決定論的に動きます。`inspect` で下書きを解析して frontmatter・画像の所在・変換対象・警告を出し、`apply` で slug の書き戻し → 画像の集約 → S3 同期 → 本文変換 → 出力までを一度に行います。

スキル（SKILL.md）に残した仕事は、スクリプトが自力で決められない2つの判断だけです。

- S3 のプレフィックスになる slug
- 日本語や記号を含む画像ファイルの英語名

ここは記事を読んで候補を出し、人間に選んでもらいます。

Qiita の organization は人間が Qiita の画面で付けるので、スキルでは聞きません。投稿済みの記事を出力し直す前に `npx qiita pull` で Qiita 側の値を取り込んでおくと、organization と `private` は既存の出力から引き継がれます。

## スクリプトが行う変換

| 処理 | 内容 |
|---|---|
| frontmatter 検証 | slug の形式、title、タグ 1〜5個・`/` 不可 |
| 画像の所在解決 | 記事リポジトリの images/ → 旧置き場の順に探索。相対・絶対・Wikilink 記法すべて |
| 画像の集約 | 記事リポジトリの `images/<slug>/` へコピー（既存は上書きしない） |
| S3 同期 | `aws s3 sync --size-only`、直後に CDN の応答コードを1件確認 |
| 画像パス | ローカル参照を `https://<CDN ドメイン>/<slug>/<file>` に置換 |
| Wikilink | `[[a]]` → `a`、`[[a\|b]]` → `b`（削除ではなくテキスト化） |
| Callout | `> [!note\|info\|tip]` → `:::note info`、`warning\|caution` → `warn`、`danger\|error\|failure` → `alert` |
| コメント | Obsidian の `%% ... %%` と HTML の `<!-- ... -->` を除去。行をまたいでもよく、開始や終了と同じ行にある文は残す。コードブロックとインラインコードの中は対象外。執筆メモを Qiita に漏らさない |
| コードブロック | コメントを含む ` ```json ` を ` ```js ` に変更（Qiita のハイライトが壊れるため） |
| H1 削除 | frontmatter の title が記事タイトルになるため先頭の `# ` 行を削除 |
| フェンス保護 | コードブロックの中身は一切変換しない |
| Qiita frontmatter | 生成。`updated_at` などは既存の出力から引き継ぐ |

## 安全側に倒している点

- `npx qiita publish` はスクリプトもスキルも実行しません。人間が行います
- `private` は既存の出力ファイルの値を引き継ぎ、無ければ `true`（限定共有）です。公開済みの記事を作り直しても勝手に限定共有へ戻らず、逆に `--public` は明示的に指定したときだけ効きます
- S3 上のファイルは削除しません（過去記事の画像 URL が死ぬため）
- 下書きの本文は書き換えません。触るのは frontmatter の slug 追記と、変名に伴う画像参照の更新だけです
