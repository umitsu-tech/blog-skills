# export-drawio（drawio 図の PNG 書き出し）

プロジェクト内の `.drawio` ファイルを draw.io デスクトップアプリの CLI で高解像度 PNG に変換します。記事や README に貼る図を作るときに単発で呼ぶ小物で、他のスキルとは独立しています。

## 動き

書き出しは `scripts/export.sh`（POSIX sh）が行い、スキルは結果の PNG を目で確かめて報告します。

- 引数にファイルを指定すればそのファイルだけ、省略すればカレントディレクトリ以下の全 `.drawio` を対象にします（`.git` と `node_modules` の中は除く）
- 3倍スケールで、入力ファイルと同じディレクトリに `.png` を書き出します。mktemp で作った作業ディレクトリに書き出し、draw.io の終了コードと PNG が最後まで書けているか（先頭の署名と末尾の IEND チャンク）を確かめてから置き換えるので、失敗しても前の PNG は残ります。draw.io は書き出しに失敗しても終了コード 0 を返すことがあるため、中身も見ています
- 既定は白背景（余白 20px）で、`--transparent` を付けたときだけ透過にします。透過 PNG は Discord や暗いテーマのビューアで読めないことがあるので、貼る先が決まっていなければ白背景にしておく方が無難です
- スクリプトは書き出した PNG のカラータイプ（アルファの有無）を読み、背景が指定どおりかを1行ずつ報告します
- スキルは書き出した PNG を開いて、はみ出しや重なりが無いか目視してから報告します

スクリプトは単体でも動きます。

```
sh skills/export-drawio/scripts/export.sh [--transparent] [ファイル.drawio ...]
```

## 必要なもの

draw.io デスクトップアプリ（`brew install --cask drawio`）。`/opt/homebrew/bin/drawio`、`/Applications/draw.io.app/Contents/MacOS/draw.io`、PATH 上の `drawio` の順に探します。別の場所にあるときは環境変数 `DRAWIO_BIN` で指定します。設定値は使いません。
