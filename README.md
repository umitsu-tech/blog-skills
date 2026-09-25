# blog-skills

私が普段のブログ執筆で使っている Claude Code のスキル4本を、プラグインとして配布しています。記事執筆方法の共有会で配ったものが元です。

| スキル | 役割 |
|---|---|
| review-blog | 投稿前レビュー。自分の過去記事と文体ルールを基準に、文体・構成・技術的正確性をチェック |
| qiita-publish-prep | Qiita 投稿準備。Python スクリプトが下書きを Qiita CLI 用に変換し、画像を S3 + CloudFront へ同期。スキル側は slug・画像名・組織の3つを判断するだけ |
| qiita-archive | 投稿後の後片付け。Python スクリプトが frontmatter 更新とアーカイブ移動を行い、スキル側は完了ログの文面を書くだけ（ステータスボードの書き換えはシェルスクリプト） |
| export-drawio | drawio の図を高解像度 PNG（3倍・白背景。`--transparent` で透過）に書き出し |

記事は「記事リポジトリの `drafts/` で書く → review-blog でレビュー → qiita-publish-prep で変換して限定共有 → 本公開 → qiita-archive で片付け」の順に流れます。全体の流れと各スキルの仕組みは [docs/](docs/) にまとめています。

## 導入方法

Claude Code のプラグインとしてインストールします。

```
claude plugin marketplace add umitsu-tech/claude-plugins
claude plugin install blog-skills@ryuki-plugins \
  --config articles_dir=~/work/articles \
  --config qiita_dir=~/work/qiita \
  --config style_file=~/work/articles/my-style.md
```

Claude Code のセッション内なら `/plugin marketplace add umitsu-tech/claude-plugins` と `/plugin install blog-skills@ryuki-plugins` でも同じです。

インストール時に `--config` で自分の環境の値を渡せます（あとから変えるときはセッション内で `/plugin configure blog-skills@ryuki-plugins`）。記事リポジトリのパス以外は、使うスキルに応じて必要なものだけで構いません。

| 設定値 | 使うスキル |
|---|---|
| 記事リポジトリ | review-blog / qiita-publish-prep / qiita-archive |
| Qiita CLI ワークスペース | qiita-publish-prep / qiita-archive |
| S3 バケット名、CDN ドメイン | qiita-publish-prep |
| 文体ルールのファイル | review-blog |
| 旧置き場（任意） | qiita-publish-prep / qiita-archive |

各設定値の意味と、スクリプトを手で動かすときの引数は [docs/configuration.md](docs/configuration.md) を見てください。

## 使い方

```
/review-blog <下書きの md ファイル>
/qiita-publish-prep <下書きの md ファイル>
/qiita-archive <下書きの md ファイル または slug>
/export-drawio [drawio ファイル] [--transparent]
```

同名のスキルが他にあるときは `/blog-skills:review-blog` のようにプラグイン名を付けて呼びます。

## そのまま使えるか

- review-blog … 文体ルールのファイルを自分で用意すれば使えます。[skills/review-blog/references/my-style.md](skills/review-blog/references/my-style.md) が私のものなので、書き方の参考にしてください。まず自分の文体ルールを言語化するところから始めるのがおすすめです
- qiita-publish-prep … S3 + CloudFront の画像配信基盤が前提なので、バケットと CDN を先に用意する必要があります。変換ルールや「どこで人間に確認を取るか」の設計の参考にもなります
- qiita-archive … 記事リポジトリと Qiita CLI ワークスペースがあれば使えます
- export-drawio … draw.io デスクトップアプリ（`brew install --cask drawio`）があればそのまま動きます。PATH 上の `drawio` も探します

## ドキュメント

- [docs/workflow.md](docs/workflow.md) … 記事執筆の全体の流れと、前提にしている記事リポジトリの構成
- [docs/review-blog.md](docs/review-blog.md) / [docs/qiita-publish-prep.md](docs/qiita-publish-prep.md) / [docs/qiita-archive.md](docs/qiita-archive.md) / [docs/export-drawio.md](docs/export-drawio.md) … 各スキルの仕組み
- [docs/configuration.md](docs/configuration.md) … 設定値の意味、スクリプトの手動実行、開発中の試し方

## 取り扱いについて

スキルの手順書には、私の運用ルールや「ユーザーに確認する」といった書きぶりが、実物の雰囲気が伝わるようそのまま残っています。環境固有の値はプラグインの設定から渡すので、手順書やスクリプトを書き換える必要はありません。ライセンスは MIT です。
