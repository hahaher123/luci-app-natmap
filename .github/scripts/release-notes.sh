#!/usr/bin/env bash
#
# 生成 GitHub Release 的标题与说明（供 .github/workflows/build.yml 调用）
#
# 用法: release-notes.sh <tag> [dist-dir] [out-dir]
#   <tag>      本次发布的 tag，例如 v1.5.10-r2
#   [dist-dir] 编译产物目录。正文不罗列产物（附件在 Release 页面直接可见），
#              该参数仅为兼容既有调用而保留
#   [out-dir]  写出 release-title.txt / release-body.md 的目录，默认当前目录
#
# 正文只有「## 本次变更」一节，且只列 feat / fix —— 产物清单与安装步骤不写入正文。
#
set -euo pipefail

TAG="${1:?用法: release-notes.sh <tag> [dist-dir] [out-dir]}"
DIST="${2:-dist}"
OUT="${3:-.}"

REPO="${GITHUB_REPOSITORY:-hahaher123/luci-app-natmap}"
BASE_URL="https://github.com/${REPO}"

# 上一个 tag（排除本次的）
PREV="$(git tag --sort=-v:refname | grep -vx -- "$TAG" | head -n 1 || true)"

# 只保留面向用户的改动：feat 与 fix。
#
# chore / ci / build / docs / refactor / style / test 等属维护性提交，整条不进发布说明 ——
# 否则一旦两次发版之间夹了若干维护提交（改 README、调工作流、挪目录），发布说明就会退化成
# 一份与本次发布无关的提交流水账。
if [ -n "${PREV}" ]; then
	LOG_RANGE="${PREV}..${TAG}"
else
	LOG_RANGE="${TAG}"
fi
CHANGES="$(git log --no-merges --pretty='- %s（%h）' "${LOG_RANGE}" 2>/dev/null \
	| grep -E '^- (feat|fix)(\(|:|!)' || true)"

# 标题：tag + 首条 feat/fix 摘要。过滤后可能一条不剩（整段都是维护性提交），
# 此时标题退化为纯 tag，避免出现 "v1.5.10: " 这种空尾巴。
PLAIN_CHANGES="$(printf '%s' "${CHANGES}" | sed -e 's/^- //' -e 's/（[0-9a-f]\{7,\}）$//')"
FIRST="$(printf '%s\n' "${PLAIN_CHANGES}" | head -n 1 || true)"
if [ -n "${FIRST}" ]; then
	printf '%s: %s\n' "${TAG}" "${FIRST}" >"${OUT}/release-title.txt"
else
	printf '%s\n' "${TAG}" >"${OUT}/release-title.txt"
fi

{
	echo "## 本次变更"
	echo
	if [ -n "${CHANGES}" ]; then
		if [ -n "${PREV}" ]; then
			echo "自 [\`${PREV}\`](${BASE_URL}/compare/${PREV}...${TAG}) 以来的改动（只列 feat / fix，维护性提交不列）："
		else
			echo "本次改动（只列 feat / fix，维护性提交不列）："
		fi
		echo
		printf '%s\n' "${CHANGES}"
	else
		# 兜底：过滤后一条不剩时不能留空章节
		echo "本次发布没有面向用户的改动（仅版本号或维护性提交）。"
	fi
	echo

} >"${OUT}/release-body.md"

echo "已生成 ${OUT}/release-title.txt 与 ${OUT}/release-body.md"
