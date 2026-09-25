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
# 書き出しは作業用の一時ファイルに行い、次の確認がすべて通ったときだけ既存の PNG を
# 置き換える。どれかが通らなければ既存の PNG には触らず、NG として報告する。
#   - draw.io の終了コードが 0
#   - PNG が空でなく、最後まで書けている（先頭の署名と末尾の IEND チャンク）
#   - PNG のカラータイプ（アルファの有無）が、指定した背景（白 / 透過）と合っている
# draw.io の場所は環境変数 DRAWIO_BIN で差し替えられる。
#
# 終了コード: 0 すべて成功 / 1 置き換えなかったファイルがある / 2 使い方の誤り・draw.io が無い

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

# PNG として最後まで書けているか。先頭の署名と、末尾の IEND チャンク（長さ 0 + "IEND" + CRC）を見る
png_complete() {
	[ "$(od -An -tx1 -N8 "$1" 2>/dev/null | tr -d ' \n')" = "89504e470d0a1a0a" ] &&
		[ "$(tail -c 12 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "0000000049454e44ae426082" ]
}

# 書き出し用の作業ディレクトリ。終了時や中断時に消す
workdir=""
cleanup() {
	if [ -n "$workdir" ]; then
		rm -f "${workdir}/out.png"
		rmdir "$workdir" 2>/dev/null
		workdir=""
	fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

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
	# 出力と同じディレクトリに mktemp で作業ディレクトリを作り、そこへ書き出してから置き換える。
	# draw.io は書き出しに失敗しても終了コード 0 を返すことがあるので、終了コード・PNG の中身・
	# 背景をすべて確かめ、どれかがだめなら既存の PNG には触らない
	if ! workdir=$(mktemp -d "$(dirname "$out")/.export-drawio.XXXXXX"); then
		workdir=""
		printf 'NG  %s  作業用のディレクトリを作れません\n' "$src"
		status=1
		continue
	fi
	tmp="${workdir}/out.png"
	if [ "$transparent" -eq 1 ]; then
		log=$("$bin" --export --format png --scale 3 --transparent --output "$tmp" "$src" </dev/null 2>&1)
	else
		log=$("$bin" --export --format png --scale 3 --border 20 --output "$tmp" "$src" </dev/null 2>&1)
	fi
	rc=$?
	if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ] || ! png_complete "$tmp"; then
		cleanup
		printf 'NG  %s  書き出しに失敗しました（終了コード %s。既存の PNG は置き換えていません）\n' "$src" "$rc"
		printf '%s\n' "$log" | sed -n '1,5s/^/    /p'
		status=1
		continue
	fi
	# 背景（アルファの有無）も置き換える前に一時ファイルで確かめる
	ctype=$(png_color_type "$tmp")
	case $ctype in
	4 | 6) bg="透過（アルファあり）" alpha=1 ;;
	0 | 2 | 3) bg="白背景（アルファなし）" alpha=0 ;;
	*) bg="不明（PNG として読めません）" alpha="" ;;
	esac
	if [ -z "$alpha" ] || [ "$alpha" -ne "$transparent" ]; then
		cleanup
		printf 'NG  %s  書き出した PNG が%sで、指定した背景と違います（既存の PNG は置き換えていません）\n' "$src" "$bg"
		status=1
		continue
	fi
	if ! mv -f "$tmp" "$out"; then
		cleanup
		printf 'NG  %s  %s を置き換えられません\n' "$src" "$out"
		status=1
		continue
	fi
	cleanup
	printf 'OK  %s  %s\n' "$out" "$bg"
done

exit "$status"
