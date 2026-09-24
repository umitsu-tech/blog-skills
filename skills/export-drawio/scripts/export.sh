#!/bin/sh
# .drawio を draw.io デスクトップアプリの CLI で 3 倍スケールの PNG に書き出す。
#
# 使い方:
#   export.sh [--transparent] [ファイル.drawio ...]
#
# ファイルを省略すると、カレントディレクトリ以下の .drawio をすべて書き出す
# （.git と node_modules の中は除く）。出力は入力と同じ場所に拡張子を .png に
# 替えた名前で置く。既定は白背景（余白 20px）で、--transparent のときだけ透過。
#
# 書き出したあと PNG のカラータイプ（アルファの有無）を読み、背景が指定どおりかを
# 1 行ずつ報告する。draw.io の場所は環境変数 DRAWIO_BIN で差し替えられる。
#
# 終了コード: 0 すべて成功 / 1 失敗または背景の不一致あり / 2 使い方の誤り・draw.io が無い

set -u

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

transparent=0
for arg do
	shift
	case $arg in
	--transparent) transparent=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		printf '不明なオプションです: %s\n' "$arg" >&2
		exit 2
		;;
	*) set -- "$@" "$arg" ;;
	esac
done

find_drawio() {
	if [ -n "${DRAWIO_BIN:-}" ]; then
		[ -x "$DRAWIO_BIN" ] || return 1
		printf '%s\n' "$DRAWIO_BIN"
		return 0
	fi
	for cand in /opt/homebrew/bin/drawio /Applications/draw.io.app/Contents/MacOS/draw.io; do
		if [ -x "$cand" ]; then
			printf '%s\n' "$cand"
			return 0
		fi
	done
	command -v drawio 2>/dev/null
}

bin=$(find_drawio) || bin=""
if [ -z "$bin" ]; then
	echo "draw.io が見つかりません。デスクトップアプリを入れてください（macOS: brew install --cask drawio）" >&2
	exit 2
fi

if [ $# -eq 0 ]; then
	files=$(find . -type f -name '*.drawio' ! -path '*/.git/*' ! -path '*/node_modules/*' | sort)
	if [ -z "$files" ]; then
		printf '.drawio ファイルが見つかりません: %s\n' "$(pwd)" >&2
		exit 2
	fi
	old_ifs=$IFS
	IFS='
'
	set -f
	# 改行区切りの一覧を位置パラメータに入れ直す（ファイル名の空白は保たれる）
	# shellcheck disable=SC2086
	set -- $files
	set +f
	IFS=$old_ifs
fi

# PNG の IHDR にあるカラータイプ（先頭から 25 バイト目）。4 と 6 がアルファ付き
png_color_type() {
	od -An -tu1 -j25 -N1 "$1" 2>/dev/null | tr -d ' \n'
}

status=0
for src do
	case $src in
	*.drawio) ;;
	*)
		printf 'NG  %s  .drawio ではありません\n' "$src"
		status=1
		continue
		;;
	esac
	if [ ! -f "$src" ]; then
		printf 'NG  %s  ファイルがありません\n' "$src"
		status=1
		continue
	fi

	out="${src%.drawio}.png"
	# 一時ファイルに書き出してから置き換える。失敗しても前の PNG は残る
	tmp="${src%.drawio}.export-$$.png"
	if [ "$transparent" -eq 1 ]; then
		log=$("$bin" --export --format png --scale 3 --transparent --output "$tmp" "$src" </dev/null 2>&1)
	else
		log=$("$bin" --export --format png --scale 3 --border 20 --output "$tmp" "$src" </dev/null 2>&1)
	fi
	if [ ! -s "$tmp" ]; then
		rm -f "$tmp"
		printf 'NG  %s  書き出しに失敗しました\n' "$src"
		printf '%s\n' "$log" | sed -n '1,5s/^/    /p'
		status=1
		continue
	fi
	mv -f "$tmp" "$out"

	ctype=$(png_color_type "$out")
	case $ctype in
	4 | 6) bg="透過（アルファあり）" alpha=1 ;;
	0 | 2 | 3) bg="白背景（アルファなし）" alpha=0 ;;
	*) bg="不明（PNG として読めません）" alpha="" ;;
	esac
	if [ -n "$alpha" ] && [ "$alpha" -eq "$transparent" ]; then
		printf 'OK  %s  %s\n' "$out" "$bg"
	else
		printf 'OK  %s  %s  ⚠ 指定した背景と違います\n' "$out" "$bg"
		status=1
	fi
done

exit "$status"
