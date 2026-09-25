---
name: export-drawio
description: draw.io の図（.drawio）を、draw.io デスクトップアプリの CLI で 3 倍スケールの PNG に書き出します。既定は白背景で、--transparent を付けたときだけ透過にします。ファイルを指定しなければプロジェクト内の .drawio をすべて書き出します。
when_to_use: 記事や README に貼る図を .drawio から PNG にしたいとき。「drawio を PNG にして」「図を書き出して」「drawio をエクスポートして」など。
argument-hint: "[drawio ファイル（省略時はすべて）] [--transparent]"
allowed-tools:
  - Bash(sh *)
  - Read
---

# drawio を PNG に書き出す

## 手順

1. 同梱のスクリプトで書き出します。ファイルと `--transparent` は、指定されたものだけを渡します。

   ```bash
   sh "${CLAUDE_PLUGIN_ROOT}/skills/export-drawio/scripts/export.sh" [--transparent] [ファイル.drawio ...]
   ```

   - ファイルを省略すると、カレントディレクトリ以下の .drawio をすべて書き出します（.git と node_modules の中は除く）
   - 出力は入力と同じディレクトリに、拡張子を .png に替えた名前で置きます。倍率は 3 倍です
   - 既定は白背景（余白 20px）です。README や Discord に貼る図は白背景にします。透過 PNG は暗い背景で読めないことがあるので、`--transparent` は指定されたときだけ付けます
   - スクリプトは 1 ファイル 1 行で `OK` / `NG` と背景の種類（PNG のアルファの有無）を出します。書き出しの失敗や背景の不一致は `NG` になり、そのときは既存の PNG を置き換えません
   - draw.io が見つからないと止まります。デスクトップアプリのインストール（macOS なら `brew install --cask drawio`）を案内してください

2. 書き出した PNG を Read で開き、文字のはみ出しや図形の重なりが無いかを見ます。

3. 書き出したファイル、背景の種類、成否を報告します。見た目に問題があれば、どの図のどこかを添えます。
