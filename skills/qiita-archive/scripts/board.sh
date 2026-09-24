#!/bin/sh
# board.md（記事のステータスボード）の定型の書き換えをまとめて行う。
#
# 使い方:
#   board.sh <board.md> [--row キー] [--log 本文 | --log -] [--date YYYY-MM-DD]
#            [--summary 要約] [--dry-run]
#
#   --row キー     キーを含む表の行（| で始まる行）を 1 行だけ消す。完了ログの中は見ない。
#                  該当が 0 行または 2 行以上なら何も書き換えずに止まる
#   --log 本文     「## 完了ログ」の見出しの下、既存の先頭の項目の前に「- 日付: 本文」を足す。
#                  「-」を渡すと本文を標準入力から 1 行読む
#   --date 日付    完了ログに付ける日付（既定は今日）
#   --summary 要約 「最終更新:」で始まる行を「最終更新: 今日の日付（要約）」に書き換える
#   --dry-run      書き換えず、差分だけを表示する
#
# 完了ログの文面（何をどう書くか）は決めない。呼び出し側が決めて渡す。
# 終了コード: 0 成功 / 1 対象の行や見出しが見つからない・曖昧 / 2 使い方の誤り

set -u

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

die() {
	printf '%s\n' "$1" >&2
	exit 2
}

board="" row="" row_set=0 log_text="" log_set=0 log_date="" summary="" summary_set=0 dry=0
while [ $# -gt 0 ]; do
	case $1 in
	--row | --log | --date | --summary)
		[ $# -ge 2 ] || die "${1} に値がありません"
		case $1 in
		--row) row=$2 row_set=1 ;;
		--log) log_text=$2 log_set=1 ;;
		--date) log_date=$2 ;;
		--summary) summary=$2 summary_set=1 ;;
		esac
		shift 2
		;;
	--dry-run)
		dry=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*) die "不明なオプションです: ${1}" ;;
	*)
		[ -z "$board" ] || die "board.md のパスは 1 つだけ指定してください"
		board=$1
		shift
		;;
	esac
done

[ -n "$board" ] || die "board.md のパスを指定してください（--help で使い方）"
[ -f "$board" ] || die "board.md がありません: ${board}"
[ "$row_set" -eq 1 ] || [ "$log_set" -eq 1 ] || [ "$summary_set" -eq 1 ] ||
	die "--row / --log / --summary のどれかを指定してください"
if [ "$row_set" -eq 1 ] && [ -z "$row" ]; then
	die "--row のキーが空です"
fi

today=$(date +%Y-%m-%d)
[ -n "$log_date" ] || log_date=$today
case $log_date in
[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
*) die "--date は YYYY-MM-DD の形で指定してください: ${log_date}" ;;
esac

entry=""
if [ "$log_set" -eq 1 ]; then
	if [ "$log_text" = "-" ]; then
		log_text=$(cat)
	fi
	case $log_text in
	"") die "完了ログの本文が空です" ;;
	*'
'*) die "完了ログの本文は 1 行で渡してください" ;;
	"- "* | [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
		die "完了ログの本文には「- 」や日付を付けずに渡してください（日付は --date）"
		;;
	esac
	entry="- ${log_date}: ${log_text}"
fi

header=""
if [ "$summary_set" -eq 1 ]; then
	if [ -n "$summary" ]; then
		header="最終更新: ${today}（${summary}）"
	else
		header="最終更新: ${today}"
	fi
fi

tmp="${TMPDIR:-/tmp}/board-sh.$$"
trap 'rm -f "$tmp"' 0
trap 'exit 1' HUP INT TERM

BOARD_ROW=$row BOARD_ENTRY=$entry BOARD_HEADER=$header BOARD_OUT=$tmp awk '
function fail(msg) { print msg | "cat 1>&2"; exit 1 }
{ line[NR] = $0 }
END {
	n = NR
	key = ENVIRON["BOARD_ROW"]; entry = ENVIRON["BOARD_ENTRY"]
	header = ENVIRON["BOARD_HEADER"]; out = ENVIRON["BOARD_OUT"]

	# 完了ログの範囲（見出しの次の行から、次の ## 見出しの手前まで）
	loghead = 0; logend = n + 1
	for (i = 1; i <= n; i++) if (index(line[i], "## 完了ログ") == 1) { loghead = i; break }
	if (loghead) for (i = loghead + 1; i <= n; i++) if (line[i] ~ /^## /) { logend = i; break }

	row = 0
	if (key != "") {
		hits = 0
		for (i = 1; i <= n; i++) {
			if (loghead && i > loghead && i < logend) continue
			if (substr(line[i], 1, 1) != "|" || index(line[i], key) == 0) continue
			hits++; cand[hits] = i
		}
		if (hits == 0) fail("キーを含む表の行がありません: " key)
		if (hits > 1) {
			msg = "キーを含む表の行が " hits " 行あります。行が 1 つに決まるキーを渡してください:"
			for (h = 1; h <= hits; h++) msg = msg "\n  L" cand[h] ": " line[cand[h]]
			fail(msg)
		}
		row = cand[1]
	}

	ins = 0; emptylog = 0
	if (entry != "") {
		if (!loghead) fail("「## 完了ログ」で始まる見出しがありません")
		for (i = loghead + 1; i < logend; i++) if (substr(line[i], 1, 2) == "- ") { ins = i; break }
		if (!ins) emptylog = 1
	}

	hdr = 0
	if (header != "") {
		for (i = 1; i <= n; i++) if (index(line[i], "最終更新:") == 1) { hdr = i; break }
		if (!hdr) fail("「最終更新:」で始まる行がありません")
	}

	for (i = 1; i <= n; i++) {
		if (i == row) continue
		if (i == ins) print entry > out
		if (i == hdr) { print header > out; continue }
		print line[i] > out
		if (i == loghead && emptylog) {
			print "" > out
			print entry > out
			if (i + 1 <= n && line[i + 1] != "") print "" > out
		}
	}
	close(out)

	if (row) print "削除した行 (L" row "): " line[row]
	if (entry != "") print "完了ログに追加: " entry
	if (hdr) print "書き換えた行 (L" hdr "): " header
}
' "$board" || exit 1

if [ "$dry" -eq 1 ]; then
	diff -u "$board" "$tmp"
	echo "（--dry-run のため書き換えていません）"
else
	# mv ではなく上書きにする。シンボリックリンクや権限をそのまま保つため
	cat "$tmp" >"$board"
fi
