#!/bin/bash

set -e

# SwallowNotePlugins 插件发布脚本
# 用法:
#   ./release.sh                    # 交互选择插件，bump 版本 + 打包签名 + 回填 repo.json + 提交
#   ./release.sh <plugin-name>      # 指定单个插件
#   ./release.sh <plugin-name> --tag-only   # 不构建，仅打 tag 触发 CI 多平台发布
#
# 签名: 读取 SWALLOWNOTE_PLUGIN_SIGNING_KEY 环境变量（CI 同源），或 package/.signing-key
# 多平台 zip 发布由 .github/workflows/plugin-release.yml（tag plugin-v* 触发）完成，
# 本脚本负责本地构建签名 + 版本推进 + 推 tag。

get_remote_info() {
    local remote_info
    remote_info=$(git remote -v 2>/dev/null | head -1)
    if [ -z "$remote_info" ]; then
        return 1
    fi
    echo "$remote_info" | sed -E 's/.*github\.com[:/]([^.]+).*/\1/' | awk '{print $1}'
}

REPO_NAME="${RELEASE_REPO_NAME:-$(get_remote_info || echo "SwallowNotePlugins")}"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CLI="$REPO_ROOT/sdk/plugin-kit/dist/cli.js"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
echo_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
echo_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

check_git_status() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        echo_error "当前目录不是 Git 仓库"
        exit 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
        echo_warning "工作区有未提交改动，打包产物可能与仓库不一致"
    fi
}

# 列出可发布插件（package/ 下含 package.json 的目录）
list_plugins() {
    for d in "$REPO_ROOT"/package/*/; do
        [ -f "$d/package.json" ] && basename "$d"
    done
}

# 确保 plugin-kit CLI 就绪（CI/本地共用 tsc 产物）
ensure_cli() {
    if [ ! -f "$CLI" ]; then
        echo_info "plugin-kit 未构建，正在构建..."
        (cd "$REPO_ROOT/sdk/plugin-kit" && npm ci --silent && npm run build --silent)
    fi
}

# 打包单个插件：bump patch 版本 + 构建 + zip + 签名 + repo.json 回填
package_plugin() {
    local plugin="$1"
    local dir="$REPO_ROOT/package/$plugin"
    if [ ! -f "$dir/package.json" ]; then
        echo_error "插件不存在: package/$plugin"
        exit 1
    fi
    local old_ver
    old_ver=$(node -p "require('$dir/package.json').version")
    echo_info "==> 发布 $plugin (v$old_ver)"

    # 密钥检查：本地签名依赖（环境变量或 .signing-key 文件）
    if [ -z "$SWALLOWNOTE_PLUGIN_SIGNING_KEY" ] && [ ! -f "$REPO_ROOT/package/.signing-key" ]; then
        echo_warning "未配置签名密钥（SWALLOWNOTE_PLUGIN_SIGNING_KEY 或 package/.signing-key），产物将不带有效签名，市场校验会拒绝"
    fi

    (cd "$dir" && node "$CLI" package)
    local new_ver
    new_ver=$(node -p "require('$dir/package.json').version")
    echo_success "$plugin 已发布: v$old_ver -> v$new_ver"
}

# 打 tag 触发 CI 多平台发布
tag_and_push() {
    local version="$1"
    local tag="plugin-v$version"
    echo_info "推送 tag $tag 触发 CI 多平台构建..."
    git tag -f "$tag" -m "plugin release v$version"
    git push origin "$tag" --force
    echo_success "CI 已触发: https://github.com/$REPO_NAME/actions"
}

# ---------------- 主流程 ----------------

check_git_status
ensure_cli

# git 提交的仓库身份提取（对齐主仓 release.sh 风格）
REPO_NAME="${RELEASE_REPO_NAME:-$(get_remote_info || echo "SwallowNotePlugins")}"

if [ "$1" == "--tag-only" ]; then
    version="${2:?用法: ./release.sh --tag-only <version>}"
    tag_and_push "$version"
    exit 0
fi

PLUGINS=("$@")

# 无参数: 交互多选
if [ ${#PLUGINS[@]} -eq 0 ]; then
    echo_info "可用插件:"
    available=()
    while IFS= read -r p; do
        available+=("$p")
        echo "  $((${#available[@]})). $p"
    done < <(list_plugins)
    read -rp "输入要发布的插件编号（逗号分隔，回车=全部）: " choice
    if [ -z "$choice" ]; then
        PLUGINS=("${available[@]}")
    else
        IFS=',' read -ra idx <<< "$choice"
        PLUGINS=()
        for i in "${idx[@]}"; do
            PLUGINS+=("${available[$((i-1))]}")
        done
    fi
fi

# 依次打包
for plugin in "${PLUGINS[@]}"; do
    package_plugin "$plugin"
done

# 回填后的索引一并提交
echo_info "提交版本与索引..."
git add package/*/package.json package/*/manifest.json package/repo.json 2>/dev/null || true
git add package/*/com.swallownote.*.zip 2>/dev/null || true
git commit -m "chore(release): 发布插件 ${PLUGINS[*]}" || echo_warning "无变更可提交（可能已发布过该版本）"

read -rp "是否推送 tag 触发 CI 多平台发布？[y/N] " push_ci
if [ "$push_ci" == "y" ]; then
    # bash 3.2 兼容：不支持 PLUGINS[-1]，用偏移取末元素
    latest_plugin="${PLUGINS[@]: -1}"
    version=$(node -p "require('$REPO_ROOT/package/$latest_plugin/package.json').version")
    tag_and_push "$version"
else
    echo_info "本地发布完成。后续可执行 ./release.sh --tag-only <version> 触发 CI"
fi

echo_success "全部完成 ✓"
