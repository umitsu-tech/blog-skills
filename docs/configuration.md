# 設定値と手動実行

環境固有の値（パスやバケット名）は、スキルの手順書やスクリプトに書かず、プラグインの設定（`plugin.json` の `userConfig`）から渡します。値は `~/.claude/settings.json` の `pluginConfigs` に保存され、リポジトリ側には入りません。

## 設定値

| キー | 型 | 意味 | 使うスキル |
|---|---|---|---|
| `articles_dir` | ディレクトリ | 記事リポジトリ。`drafts/` `images/<slug>/` `published/` `board.md` がある場所（[workflow.md](workflow.md) 参照） | review-blog / qiita-publish-prep / qiita-archive |
| `qiita_dir` | ディレクトリ | Qiita CLI ワークスペース（`npx qiita init` した場所）。`public/<slug>.md` を出力・参照する | qiita-publish-prep / qiita-archive |
| `bucket` | 文字列 | 画像の同期先 S3 バケット名 | qiita-publish-prep |
| `cdn_domain` | 文字列 | 上のバケットを配信する CloudFront のドメイン。`images.example.com` のようにスキーム無し | qiita-publish-prep |
| `style_file` | ファイル | review-blog が最初に読む文体ルールの Markdown。[skills/review-blog/references/my-style.md](../skills/review-blog/references/my-style.md) を参考に自分のものを書く | review-blog |
| `obsidian_dir` | ディレクトリ（任意） | 記事リポジトリへ移す前の下書きや画像が残っている場所。画像や下書きの探索先に加わる | qiita-publish-prep / qiita-archive |

設定はインストール時の `--config KEY=VALUE`（繰り返し可）か、セッション内の `/plugin configure blog-skills@ryuki-plugins` で入力・変更します。値が未設定のままスキルを呼ぶと、スクリプトが「環境固有の値が未設定です」と止まり、スキルが設定を案内します。

## 手順書からの参照のしかた

SKILL.md では `${user_config.articles_dir}` のように書くと、Claude Code が読み込むときに設定値へ置き換えます。同梱スクリプトの場所は `${CLAUDE_PLUGIN_ROOT}` で指します。プラグインは更新のたびに別のディレクトリへ展開されるので、パスを決め打ちしません。

```
python3 "${CLAUDE_PLUGIN_ROOT}/skills/qiita-archive/scripts/qiita_archive.py" inspect <slug> \
  --articles-dir "${user_config.articles_dir}" --qiita-dir "${user_config.qiita_dir}" \
  --obsidian-dir "${user_config.obsidian_dir}"
```

## スクリプトを手で動かす

`scripts/` の Python は単体でも動きます。設定値は引数で渡すか、`BLOG_SKILLS_*` 環境変数で渡します（引数が優先）。

| 引数 | 環境変数 |
|---|---|
| `--articles-dir` | `BLOG_SKILLS_ARTICLES_DIR` |
| `--qiita-dir` | `BLOG_SKILLS_QIITA_DIR` |
| `--obsidian-dir` | `BLOG_SKILLS_OBSIDIAN_DIR` |
| `--bucket` | `BLOG_SKILLS_BUCKET` |
| `--cdn-domain` | `BLOG_SKILLS_CDN_DOMAIN` |

```
export BLOG_SKILLS_ARTICLES_DIR=~/work/articles
export BLOG_SKILLS_QIITA_DIR=~/work/qiita
python3 skills/qiita-publish-prep/scripts/qiita_prep.py inspect ~/work/articles/drafts/20_執筆中/foo.md
python3 skills/qiita-publish-prep/scripts/qiita_prep.py apply ~/work/articles/drafts/20_執筆中/foo.md \
  --bucket my-bucket --cdn-domain images.example.com --dry-run
```

`--bucket` と `--cdn-domain` は `apply` で S3 同期をするときだけ必須です。`inspect` や `--skip-sync` なら省略できます。

シェルスクリプト（`export-drawio/scripts/export.sh`、`qiita-archive/scripts/board.sh`、`review-blog/scripts/pick-references.sh`）は POSIX sh で書いてあり、設定値は使わず引数だけで動きます。使い方は `--help` で出ます。

## 開発中に試す

リポジトリをそのままプラグインとして読み込めます。

```
claude --plugin-dir ~/path/to/blog-skills
```

設定値まで含めて本番と同じ形で試すなら、手元のリポジトリを指すマーケットプレイスを別ディレクトリに作って登録します。`marketplace.json` の `source` にはマーケットプレイスの直下より上（`..` を含むパス）を指定できないので、リポジトリへのシンボリックリンクを直下に置きます。

```
mkdir -p ~/claude-plugins-local/.claude-plugin
cd ~/claude-plugins-local
ln -s ../blog-skills blog-skills
curl -sL https://raw.githubusercontent.com/umitsu-tech/claude-plugins/main/.claude-plugin/marketplace.json \
  -o .claude-plugin/marketplace.json
```

`marketplace.json` の blog-skills の `source` を `"./blog-skills"` に書き換えてから登録すると、同じ名前（ryuki-plugins）の登録が置き換わり、手元のリポジトリからインストールされます。

```
claude plugin marketplace add ~/claude-plugins-local
claude plugin install blog-skills@ryuki-plugins --config articles_dir=~/work/articles
```

変更を反映するには `claude plugin update blog-skills@ryuki-plugins` を実行します。GitHub 版に戻すときは `claude plugin marketplace add umitsu-tech/claude-plugins` を再実行します。
