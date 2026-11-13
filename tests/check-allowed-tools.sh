#!/bin/sh
# スキルの allowed-tools が効いているかを、確認ダイアログを出さずに確かめる。
#
# 使い方: sh tests/check-allowed-tools.sh [モデル名]（既定は haiku）
#
# claude -p を --permission-mode dontAsk で動かすと、前もって許可されていないツールは
# 確認を出さずに断られ、結果の JSON の permission_denials に残る。これを使って、
#   1. 試験用のプラグイン（tests/permission-probe/plugin）で、許可の仕組みがドキュメント
#      どおりに動くか（許可あり・ヒアドキュメントは通る、許可なし・クォートのずれは断られる）
#   2. インストール済みの blog-skills の 4 つのスキルで、同梱スクリプトが断られないか
# を確かめる。2 は、インストール済みのプラグイン（blog-skills@ryuki-plugins）の読み込み元を
# 調べたいブランチにしてから実行する。ファイルを書き換える操作は呼ばない作りにしている
# （存在しない下書きや slug を渡す。review-blog は一時ディレクトリのダミーの下書きを使う）。
#
# 1 回の実行で claude -p を 8 回呼ぶ（haiku で合わせて数セント）。

set -u

MODEL=${1:-haiku}
HERE=$(cd "$(dirname "$0")" && pwd)
PROBE="$HERE/permission-probe/plugin"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-allowed-tools.XXXXXX")
FAIL=0

# claude -p を dontAsk で動かし、Claude が実行しようとした Bash のコマンドを
# 「RAN<TAB>コマンド」、断られたコマンドを「DENIED<TAB>コマンド」で 1 行ずつ出す
run_claude() {
	prompt=$1
	shift
	out="$WORK/out.jsonl"
	( cd "$WORK" && claude -p "$prompt" --permission-mode dontAsk --strict-mcp-config \
		--no-session-persistence --model "$MODEL" --output-format stream-json --verbose "$@" ) \
		>"$out" 2>"$WORK/err.txt"
	python3 -I -c '
import json, sys
for raw in open(sys.argv[1]):
    try:
        d = json.loads(raw)
    except ValueError:
        continue
    if d.get("type") == "assistant":
        for c in d.get("message", {}).get("content", []):
            if c.get("type") == "tool_use" and c.get("name") == "Bash":
                print("RAN\t" + c.get("input", {}).get("command", "").replace("\n", " "))
    if d.get("type") == "result":
        for x in d.get("permission_denials", []):
            cmd = (x.get("tool_input") or {}).get("command") or str(x.get("tool_input"))
            print("DENIED\t" + cmd.replace("\n", " "))
' "$out"
}

# $1=名前 $2=期待（allow / deny） $3=スキル名
probe() {
	log=$(run_claude "/probe:$3" --plugin-dir "$PROBE" --setting-sources project 2>/dev/null)
	if printf '%s\n' "$log" | grep -q '^DENIED'; then
		got=deny
	elif printf '%s\n' "$log" | grep -q '^RAN.*probe\.sh'; then
		got=allow
	else
		got=未実行
	fi
	if [ "$got" = "$2" ]; then
		echo "ok    仕組み: $1（期待どおり $2）"
	else
		echo "NG    仕組み: $1（期待 $2、結果 $got）"
		FAIL=1
	fi
}

# $1=スキル名 $2=同梱スクリプトのファイル名 $3=プロンプト
skill() {
	log=$(run_claude "$3" --setting-sources user 2>/dev/null)
	script="/skills/$1/scripts/$2"
	bad=$(printf '%s\n' "$log" | grep '^DENIED' | grep -F "$script" || true)
	ran=$(printf '%s\n' "$log" | grep '^RAN' | grep -F "$script" || true)
	if [ -n "$bad" ]; then
		echo "NG    $1: $2 が断られた"
		printf '%s\n' "$bad" | cut -f2- | cut -c1-160 | sed 's/^/        /'
		FAIL=1
	elif [ -z "$ran" ]; then
		echo "NG    $1: $2 が実行されなかった（確かめられていない）"
		FAIL=1
	else
		echo "ok    $1: $2 を実行し、断られなかった"
	fi
	other=$(printf '%s\n' "$log" | grep '^DENIED' | grep -v -F "$script" || true)
	if [ -n "$other" ]; then
		echo "      （参考）同梱スクリプト以外で断られたコマンド。ふつうのモードでは確認が出る:"
		printf '%s\n' "$other" | cut -f2- | cut -c1-160 | sed 's/^/        /'
	fi
}

echo "作業ディレクトリ: $WORK"
echo

probe "allowed-tools あり" allow allowed
probe "allowed-tools なし" deny none
probe "ヒアドキュメント" allow heredoc
probe "本文だけクォート" deny quoted
echo

printf -- "---\ntitle: '権限の確認用のダミー'\nstatus: writing\n---\n\n# 権限の確認用のダミー\n\n## はじめに\n\nallowed-tools の確認のためのダミーの下書きです。\n\n## おわりに\n\nありがとうございました。\n" >"$WORK/dummy.md"

skill qiita-publish-prep qiita_prep.py "/blog-skills:qiita-publish-prep /nonexistent/permission-check.md"
skill qiita-archive qiita_archive.py "/blog-skills:qiita-archive permission-check-nonexistent-slug"
skill export-drawio export.sh "/blog-skills:export-drawio"
skill review-blog pick-references.sh "/blog-skills:review-blog $WORK/dummy.md"

echo
if [ "$FAIL" -eq 0 ]; then
	echo "すべて期待どおりです"
else
	echo "期待と違う結果があります。モデルが同梱スクリプトの後ろに別のコマンドをつなげていないかも見てください"
fi
exit "$FAIL"
