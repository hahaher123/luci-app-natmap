#!/usr/bin/env bash
#
# 生成 GitHub Release 的标题与说明（供 .github/workflows/build.yml 调用）
#
# 用法: release-notes.sh <tag> [dist-dir] [out-dir]
#   <tag>      本次发布的 tag，例如 v1.5.10
#   [dist-dir] 编译产物目录，用于列出本次附加的包，默认 dist
#   [out-dir]  写出 release-title.txt / release-body.md 的目录，默认当前目录
#
set -euo pipefail

TAG="${1:?用法: release-notes.sh <tag> [dist-dir] [out-dir]}"
DIST="${2:-dist}"
OUT="${3:-.}"

REPO="${GITHUB_REPOSITORY:-hahaher123/luci-app-natmap}"
BASE_URL="https://github.com/${REPO}"

# 上一个 tag（排除本次的）
PREV="$(git tag --sort=-v:refname | grep -vx -- "$TAG" | head -n 1 || true)"

if [ -n "${PREV}" ]; then
	CHANGES="$(git log --no-merges --pretty='- %s（%h）' "${PREV}..${TAG}" || true)"
else
	CHANGES="$(git log --no-merges --pretty='- %s（%h）' "${TAG}" || true)"
fi
[ -n "${CHANGES}" ] || CHANGES='- 无提交记录'

# 标题：tag + 首条「有内容」的提交摘要（跳过版本号提交，避免标题变成
# "v1.5.10: chore: bump version to 1.5.10" 这种没有信息量的结果）
PLAIN_CHANGES="$(printf '%s\n' "${CHANGES}" | sed -e 's/^- //' -e 's/（[0-9a-f]\{7,\}）$//')"
FIRST="$(printf '%s\n' "${PLAIN_CHANGES}" | grep -v '^chore: bump version' | head -n 1 || true)"
[ -n "${FIRST}" ] || FIRST="$(printf '%s\n' "${PLAIN_CHANGES}" | head -n 1)"
printf '%s: %s\n' "${TAG}" "${FIRST}" >"${OUT}/release-title.txt"

{
	echo "## 本次变更"
	echo
	if [ -n "${PREV}" ]; then
		echo "自 [\`${PREV}\`](${BASE_URL}/compare/${PREV}...${TAG}) 以来的提交："
	else
		echo "提交记录："
	fi
	echo
	printf '%s\n' "${CHANGES}"
	echo

	echo "## 本次产物"
	echo
	echo "使用 OpenWrt 25.12 SDK 编译，apk 包格式；本应用及翻译包均为 \`PKGARCH:=all\`，与设备架构无关。"
	echo
	echo "| 包 | 说明 |"
	echo "| --- | --- |"
	echo "| \`luci-app-natmap-*.apk\` | LuCI 界面与脚本（含默认配置、各转发/联动/通知插件） |"
	echo "| \`luci-i18n-natmap-zh-cn.apk\` | 简体中文翻译 |"
	echo
	echo "本次实际附加的文件："
	echo
	for f in "${DIST}"/*.apk; do
		[ -e "${f}" ] || continue
		printf -- '- `%s`\n' "$(basename "${f}")"
	done
	echo

	echo "## 安装"
	echo
	echo '```sh'
	echo '# 包为自行编译、未经 OpenWrt 官方签名，必须加 --allow-untrusted'
	echo 'apk add --allow-untrusted ./luci-app-natmap-<版本>.apk'
	echo
	echo '# 需要中文界面时再装翻译包（安装后自动切到对应语言）'
	echo 'apk add --allow-untrusted ./luci-i18n-natmap-zh-cn-<版本>.apk'
	echo
	echo '# 升级已安装的版本'
	echo 'apk add --allow-untrusted --upgrade ./luci-app-natmap-*.apk'
	echo '```'
	echo
	echo '> `luci-app-natmap` 依赖 `natmap` 与 `jq`、`curl`、`openssl-util`、`bash`。'
	echo '> 后四者来自 OpenWrt 官方源；`natmap` 本仓库不提供预编译包，请先通过你现有的方式安装。'
	echo
	echo "安装后刷新 LuCI 页面即可看到 NATMap 菜单。"
	if [ -n "${PREV}" ]; then
		echo
		echo "完整变更对比：${BASE_URL}/compare/${PREV}...${TAG}"
	fi
} >"${OUT}/release-body.md"

echo "已生成 ${OUT}/release-title.txt 与 ${OUT}/release-body.md"
