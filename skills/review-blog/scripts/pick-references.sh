#!/bin/sh
# レビューで参考にする過去記事の候補を、ジャンル別に新しい順で並べる。
#
# 使い方:
#   pick-references.sh <published ディレクトリ> [--limit N]
#
# 5KB（5,120 バイト）以上の .md（レビューレポートの .review.md は除く）を対象に、
# ファイル名で次の 3 つのジャンルに振り分け、それぞれ更新日時の新しい順に N 本
# （既定 5 本）まで出す。1 つのファイルが複数のジャンルに出ることもある。
# 最後に、ジャンルを問わず新しい順の 3 本を出す（ジャンルを決めにくいとき用）。
#
#   トラブルシュート系: しない / できない / 表示されない
#   実装・手順系:       してみた / を作る / する
#   解説系:             とは / について
#
# どのジャンルを使い、どの記事を読むかは呼び出し側が決める。
# 終了コード: 0 成功 / 1 対象の記事が無い / 2 使い方の誤り

set -u

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

die() {
	printf '%s\n' "$1" >&2
	exit 2
}

dir="" limit=5
while [ $# -gt 0 ]; do
	case $1 in
	--limit)
		[ $# -ge 2 ] || die "--limit に値がありません"
		limit=$2
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*) die "不明なオプションです: ${1}" ;;
	*)
		[ -z "$dir" ] || die "ディレクトリは 1 つだけ指定してください"
		dir=$1
		shift
		;;
	esac
done

[ -n "$dir" ] || die "published ディレクトリを指定してください（--help で使い方）"
[ -d "$dir" ] || die "ディレクトリがありません: ${dir}"
case $limit in
'' | *[!0-9]* | 0) die "--limit は 1 以上の整数で指定してください: ${limit}" ;;
esac

# 5,120 バイト未満（! -size -5120c）を除き、ls -t で更新日時の新しい順に並べる
list=$(find "$dir" -type f -name '*.md' ! -name '*.review.md' ! -size -5120c -exec ls -1t {} +)
if [ -z "$list" ]; then
	printf '5KB 以上の記事がありません: %s\n' "$dir" >&2
	exit 1
fi

total=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
printf '対象: %s 本（%s の下、5KB 以上、新しい順）\n' "$total" "$dir"

show_file() {
	bytes=$(wc -c <"$1" | tr -d ' ')
	printf '  %4sKB  %s\n' "$(((bytes + 512) / 1024))" "$1"
}

# 見出しと、ファイル名に含まれていれば該当とみなす文字列を受け取る
show_genre() {
	title=$1
	shift
	printf '\n== %s\n' "$title"
	count=0
	while IFS= read -r file; do
		name=${file##*/}
		for pat do
			case $name in
			*"$pat"*)
				show_file "$file"
				count=$((count + 1))
				break
				;;
			esac
		done
		[ "$count" -lt "$limit" ] || break
	done <<EOF
$list
EOF
	[ "$count" -gt 0 ] || printf '  （なし）\n'
}

show_genre "トラブルシュート系（しない / できない / 表示されない）" しない できない 表示されない
show_genre "実装・手順系（してみた / を作る / する）" してみた を作る する
show_genre "解説系（とは / について）" とは について

printf '\n== 新しい順（ジャンルを決めにくいとき）\n'
count=0
while IFS= read -r file; do
	show_file "$file"
	count=$((count + 1))
	[ "$count" -lt 3 ] || break
done <<EOF
$list
EOF
