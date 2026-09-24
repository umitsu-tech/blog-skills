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
# 書き換えは、board.md の実体と同じディレクトリに mktemp で作った一時ファイルへ書いてから
# mv で置き換える。board.md がシンボリックリンクなら、リンクは残してリンク先を置き換える。
# 読み込みから置き換えまでは、実体の隣に作るロック（.<ファイル名>.lock ディレクトリ）で
# 直列にする。ロックがあれば何もせずに止まる（--dry-run はロックを取らない）。
# 終了コード: 0 成功 / 1 対象の行や見出しが見つからない・曖昧、書き込みの失敗
#             2 使い方の誤り / 3 ほかの処理が更新中（ロックがある）

set -u

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

die() {
	printf '%s\n' "$1" >&2
	exit 2
}

fail() {
	printf '%s\n' "$1" >&2
	exit 1
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

# board.md がシンボリックリンクなら、書き換える先はリンク先の実体
target=$board
hops=0
while [ -L "$target" ]; do
	hops=$((hops + 1))
	[ "$hops" -le 20 ] || fail "シンボリックリンクをたどりきれません: ${board}"
	link=$(readlink "$target") || fail "シンボリックリンクを読めません: ${target}"
	case $link in
	/*) target=$link ;;
	*) target="$(dirname "$target")/${link}" ;;
	esac
done

dir=$(dirname "$target")
base=$(basename "$target")
lock="${dir}/.${base}.lock"

# 終了時と中断時の片付け。途中で割り込まれないようシグナルを無視し、ロックは 1 回だけ外す
tmp="" locked=0
cleanup() {
	trap '' HUP INT TERM
	[ -z "$tmp" ] || rm -f "$tmp"
	tmp=""
	if [ "$locked" -eq 1 ]; then
		locked=0
		rmdir "$lock" 2>/dev/null
	fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

# 読み込みから置き換えまでをロックで直列にする（同時に動くと、後の mv が先の変更を消すため）。
# mkdir の成功と locked=1 の間で中断されてロックが残らないよう、その間だけシグナルを無視する
if [ "$dry" -eq 0 ]; then
	trap '' HUP INT TERM
	if mkdir "$lock" 2>/dev/null; then
		locked=1
	fi
	trap 'exit 1' HUP INT TERM
	if [ "$locked" -eq 0 ]; then
		if [ -d "$lock" ]; then
			printf '%s\n' "ほかの処理が board.md を更新中です（${lock} があります）。終わってからやり直してください。" \
				"更新中の処理が無いのに残っている場合は、前の実行が強制終了した跡なので、中身を確かめてから rmdir で消してください。" >&2
			exit 3
		fi
		fail "ロックを作れません: ${lock}"
	fi
fi

# 一時ファイルは mktemp で実体と同じディレクトリに作る（同じファイルシステム内の mv で置き換えるため）
tmp=$(mktemp "${dir}/.${base}.XXXXXX") || fail "一時ファイルを作れません: ${dir}"
# 権限を引き継ぐため、元のファイルを写してから中身を書き直す
cp -p "$target" "$tmp" || fail "一時ファイルに写せません: ${tmp}"

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
	if (close(out) != 0) fail("一時ファイルに書き込めません: " out)

	if (row) print "削除した行 (L" row "): " line[row]
	if (entry != "") print "完了ログに追加: " entry
	if (hdr) print "書き換えた行 (L" hdr "): " header
}
' "$target" || exit 1
[ -s "$tmp" ] || fail "書き換えた結果が空になったため、board.md を置き換えません"

if [ "$dry" -eq 1 ]; then
	diff -u "$board" "$tmp"
	echo "（--dry-run のため書き換えていません）"
	exit 0
fi

# 同じディレクトリ内の mv で置き換えるので、途中で失敗しても board.md は元のまま残る
mv -f "$tmp" "$target" || fail "board.md を置き換えられません: ${target}"
tmp=""
