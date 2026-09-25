# qiita-archive（投稿後の後片付け）

本公開が済んだ記事の下書きに `status` / `qiita_id` / `published_at` を書き込み、レビューレポートごと記事リポジトリの `published/` へ移します。

![qiita-archiveの仕組み](../images/qiita-archive-flow.png)

## なぜ slug と qiita_id を下書きに残すか

記事を更新したくなったとき、slug と qiita_id を引き継いで qiita-publish-prep を再実行できるようにするためです。同じ URL、同じ画像パスのまま再投稿できます。

## スクリプトとスキルの分担

frontmatter の更新とファイル移動は `scripts/qiita_archive.py` が行います。`inspect` で対象と公開状態を確かめ（Qiita CLI ワークスペースの `public/<slug>.md` に `id` が無ければ未公開として止まる）、`apply` で frontmatter を書き込んでファイルを移動します。`published_at` は既存値があればそれを残すので、再実行しても公開日が上書きされません。

ステータスボード（記事リポジトリの `board.md`）の更新は、文面をスキル（Claude）が決め、書き換えを `scripts/board.sh`（POSIX sh）が行います。完了ログに書く内容は記事ごとに違うので、Claude が既存のログの書きぶりに合わせて1行を書きます。`board.sh` はそれを受け取って、ボードの表から該当行を消し、完了ログの先頭に `- 日付: 本文` を足し、`最終更新:` の行を今日の日付と要約に書き換えます。消す行が1つに決まらないときは何も書き換えずに止まり、`--dry-run` で差分だけを確かめることもできます。書き換えは同じディレクトリに mktemp で作った一時ファイルへ書いてから mv で置き換えるので、途中で失敗しても board.md は壊れません（board.md がシンボリックリンクなら、リンク先を置き換えます）。読み込みから置き換えまでは board.md の隣に作るロック（`.board.md.lock` ディレクトリ）で直列にしているので、2 つの実行が重なっても片方の変更が消えることはありません。後から来た方は終了コード 3 で止まります。

```
sh skills/qiita-archive/scripts/board.sh ~/work/articles/board.md \
  --row 'foo.md' --summary 'foo 記事をアーカイブ' --log '「foo」（本公開・アーカイブ済み）' --dry-run
```

## やらないこと

- 本文の書き換え（frontmatter のみ）
- `published/` 以外への移動、元ファイルの削除
- slug の変更（S3 プレフィックスが無効になり画像 URL が切れる）
- 完了ログの過去エントリの書き換え（追記のみ）
