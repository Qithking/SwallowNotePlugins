#!/bin/bash

set -e

# SwallowNotePlugins 发布工具（菜单驱动，与主仓 SwallowNote/release.sh 同款交互风格）
#
# 操作说明:
#   1. 提交代码到 GitHub        — add/commit/push 当前分支
#   2. 发布新版本               — 创建 plugin-v* tag 推送，触发 Actions 多平台构建
#   3. 本地打包插件             — swallow-plugin package（bump + 构建 + zip + 签名 + repo.json 回填）
#   4. 清除 Actions             — 失败运行 / 全部运行
#   5. 删除 Tag                 — 指定 / 全部
#   6. 重新触发最新版本 Actions — 删除远程 tag 后重推
#   7. 推送 beta 内容到远程 main 分支
#   8. 发布指定插件            — 触发 CI 单插件构建发布 / 单独更新 repo.json
#   0. 退出
#
# 签名: 读取 SWALLOWNOTE_PLUGIN_SIGNING_KEY 环境变量（CI 同源），或 package/.signing-key

REPO_SLUG="Qithking/SwallowNotePlugins"

get_remote_info() {
    local remote_info
    remote_info=$(git remote -v 2>/dev/null | head -1)
    if [ -z "$remote_info" ]; then
        return 1
    fi
    echo "$remote_info" | sed -E 's/.*github\.com[:/]([^.]+).*/\1/' | awk '{print $1}'
}

REPO_NAME="${RELEASE_REPO_NAME:-$(get_remote_info || echo "$REPO_SLUG")}"
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

# 检查 Git 状态
check_git_status() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        echo_error "当前目录不是 Git 仓库"
        exit 1
    fi
}

# 获取最新插件版本 tag（plugin-v* 前缀）
get_current_version() {
    git tag --sort=-version:refname 2>/dev/null | grep "^plugin-v" | head -1 || echo ""
}

# 确保 plugin-kit CLI 就绪（CI/本地共用 tsc 产物）
ensure_cli() {
    if [ ! -f "$CLI" ]; then
        echo_info "plugin-kit 未构建，正在构建..."
        (cd "$REPO_ROOT/sdk/plugin-kit" && npm ci --silent && npm run build --silent)
    fi
}

# 确保 plugin-sdk 就绪（插件 vite.config 依赖其 dist 入口）
ensure_sdk() {
    if [ ! -f "$REPO_ROOT/sdk/plugin-sdk/dist/index.js" ]; then
        echo_info "plugin-sdk 未构建，正在构建..."
        (cd "$REPO_ROOT/sdk/plugin-sdk" && npm ci --silent && npm run build --silent) || {
            echo_error "plugin-sdk 构建失败"
            return 1
        }
    fi
}

# 提交并推送代码
push_to_github() {
    echo ""
    echo "=== 提交代码到 GitHub ==="
    echo ""

    # 检查远程仓库
    remote_name=$(git remote 2>/dev/null | head -1)
    if [ -z "$remote_name" ]; then
        echo_error "未找到远程仓库"
        exit 1
    fi
    echo_info "检测到远程仓库: $remote_name"

    current_branch=$(git branch --show-current)

    # 拉取远程最新引用
    echo_info "拉取远程最新代码..."
    if ! git fetch "$remote_name" --prune; then
        echo_error "git fetch 失败，请检查网络连接"
        return 1
    fi

    # 显示更改
    echo ""
    echo_info "当前更改:"
    git status --short

    # 用 porcelain 判定（覆盖 untracked/staged/modified）
    echo ""
    if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
        ahead=$(git rev-list --count "refs/remotes/$remote_name/$current_branch..$current_branch" 2>/dev/null || echo 0)
        if [ "$ahead" -gt 0 ]; then
            echo_info "工作区无新更改，但本地有 $ahead 个未推送提交，执行推送..."
        fi
        if ! git push "$remote_name" "$current_branch"; then
            echo_error "推送失败（远程包含本地没有的提交），请先执行 git pull 同步"
            return 1
        fi
        if [ "$ahead" -gt 0 ]; then
            echo_success "代码已成功推送到 GitHub!"
        else
            echo_info "没有需要提交的更改，本地与远程已同步"
        fi
        return 0
    fi

    echo ""
    read -p "输入提交信息 (留空使用默认): " commit_msg
    if [ -z "$commit_msg" ]; then
        commit_msg="Update: $(date '+%Y-%m-%d %H:%M:%S')"
    fi

    echo ""
    echo_info "执行: git add . && git commit -m '$commit_msg'"
    git add .
    if ! git commit -m "$commit_msg"; then
        echo_error "git commit 失败（可能是 pre-commit hook 拒绝或配置问题）"
        return 1
    fi

    echo ""
    echo_info "推送到 $remote_name/$current_branch..."
    if ! git push "$remote_name" "$current_branch"; then
        echo_error "推送失败（远程可能包含本地没有的提交），请先执行 git pull"
        return 1
    fi

    echo_success "代码已成功推送到 GitHub!"
}

# 列出可发布插件（package/ 下含 package.json 的目录）
list_plugins() {
    for d in "$REPO_ROOT"/package/*/; do
        [ -f "$d/package.json" ] && basename "$d"
    done
}

# 本地打包插件：bump patch 版本 + 构建 + zip + 签名 + repo.json 回填
package_plugin() {
    local plugin="$1"
    local dir="$REPO_ROOT/package/$plugin"
    if [ ! -f "$dir/package.json" ]; then
        echo_error "插件不存在: package/$plugin"
        return 1
    fi
    local old_ver
    old_ver=$(node -p "require('$dir/package.json').version")
    echo_info "==> 打包 $plugin (v$old_ver)"

    # 依赖检查：node_modules 与 SDK 产物
    if [ ! -d "$dir/node_modules" ]; then
        echo_info "  未安装依赖，执行 npm install..."
        (cd "$dir" && npm install --silent) || { echo_error "npm install 失败"; return 1; }
    fi
    ensure_sdk || return 1

    # 密钥检查：本地签名依赖（环境变量或 .signing-key 文件）
    if [ -z "$SWALLOWNOTE_PLUGIN_SIGNING_KEY" ] && [ ! -f "$REPO_ROOT/package/.signing-key" ]; then
        echo_warning "未配置签名密钥（SWALLOWNOTE_PLUGIN_SIGNING_KEY 或 package/.signing-key），产物将不带有效签名，市场校验会拒绝"
    fi

    (cd "$dir" && node "$CLI" package) || { echo_error "打包失败"; return 1; }
    local new_ver
    new_ver=$(node -p "require('$dir/package.json').version")
    echo_success "$plugin 打包完成: v$old_ver -> v$new_ver"
}

# 操作 3: 本地打包插件（单选/多选）
local_package() {
    echo ""
    echo "=== 本地打包插件 ==="
    echo ""

    ensure_cli
    if ! command -v node &> /dev/null; then
        echo_error "需要安装 Node.js"
        exit 1
    fi

    echo_info "可用插件:"
    available=()
    while IFS= read -r p; do
        available+=("$p")
        echo "  $((${#available[@]})). $p"
    done < <(list_plugins)

    if [ ${#available[@]} -eq 0 ]; then
        echo_error "package/ 下没有可用插件"
        return 1
    fi

    echo ""
    read -p "输入要打包的插件编号（逗号分隔，回车=全部）: " choice

    PLUGINS=()
    if [ -z "$choice" ]; then
        PLUGINS=("${available[@]}")
    else
        IFS=',' read -ra idx <<< "$choice"
        for i in "${idx[@]}"; do
            PLUGINS+=("${available[$((i-1))]}")
        done
    fi

    echo ""
    for plugin in "${PLUGINS[@]}"; do
        package_plugin "$plugin" || echo_warning "跳过: $plugin"
    done

    echo ""
    echo_info "版本与索引变更:"
    git status --short | grep -E "package/.*\.(json)$|repo.json" || true
    echo ""
    read -p "是否提交并推送版本变更? (y/n): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        git add package/*/package.json package/*/manifest.json package/*/src-tauri/Cargo.toml package/repo.json 2>/dev/null || true
        git commit -m "chore(release): 打包插件 ${PLUGINS[*]}" || echo_warning "无变更可提交"
        remote_name=$(git remote 2>/dev/null | head -1)
        git push "$remote_name" "$(git branch --show-current)" || echo_warning "推送失败，请手动处理"
        echo_success "版本变更已推送!"
    fi
}

# 发布版本：创建 plugin-v* tag 触发 Actions 多平台构建
create_release() {
    echo ""
    echo "=== 发布新版本（创建 tag 触发 GitHub Actions）==="
    echo ""

    # 检查 GitHub CLI
    if ! command -v gh &> /dev/null; then
        echo_error "需要安装 GitHub CLI"
        echo "安装命令: brew install gh"
        exit 1
    fi

    # 检查登录状态
    if ! gh auth status &> /dev/null; then
        echo_error "未登录 GitHub"
        echo "请运行: gh auth login"
        exit 1
    fi

    # 检查远程仓库
    remote_name=$(git remote 2>/dev/null | head -1)
    if [ -z "$remote_name" ]; then
        echo_error "未找到远程仓库"
        exit 1
    fi
    echo_info "检测到远程仓库: $remote_name"

    # 提示先本地打包
    echo_warning "发布前请确认已完成「本地打包插件」（版本 bump + repo.json 回填已提交）"
    echo ""

    # 获取当前版本并推荐新版本
    current_version=$(get_current_version)
    if [ -n "$current_version" ]; then
        echo_info "当前版本: $current_version"
    fi
    if [[ "$current_version" =~ ^plugin-v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        patch="${BASH_REMATCH[3]}"
        recommended_version="plugin-v${major}.${minor}.$((patch + 1))"
    else
        recommended_version="plugin-v0.1.0"
    fi

    echo ""
    echo_info "推荐版本号: $recommended_version"
    echo ""
    read -p "输入新版本号 (留空使用推荐版本号 $recommended_version): " new_version

    # 如果用户直接回车，使用推荐版本号
    if [ -z "$new_version" ]; then
        new_version="$recommended_version"
    else
        # 验证版本格式并添加 plugin-v 前缀
        if [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            new_version="plugin-v$new_version"
        elif ! [[ "$new_version" =~ ^plugin-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo_error "版本号格式错误，请使用 *.*.* 格式"
            exit 1
        fi
    fi

    echo_info "创建版本: $new_version"

    # 检查版本是否已存在
    if git tag | grep -q "^${new_version}$"; then
        echo_warning "版本 $new_version 已存在"
        read -p "是否删除旧 tag 并重新发布? (y/n): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            git tag -d "$new_version" 2>/dev/null && echo_info "已删除本地 tag: $new_version"
            git push "$remote_name" --delete "$new_version" 2>/dev/null && echo_info "已删除远程 tag: $new_version" || echo_warning "远程 tag 可能不存在"
        else
            echo_info "已取消发布"
            return
        fi
    fi

    echo ""
    echo_info "创建 tag: $new_version"
    git tag "$new_version"

    echo ""
    echo_info "推送 tag 到 GitHub..."
    git push "$remote_name" "$new_version"

    echo_success "已创建版本 $new_version 并推送!"
    echo ""
    echo_info "GitHub Actions 将自动构建三平台插件后端并打包签名发布..."
    echo_info "查看构建进度: https://github.com/$REPO_SLUG/actions"
}

# 下载最新版本（插件包 + repo.json）
download_latest() {
    echo ""
    echo "=== 下载最新插件包 ==="
    echo ""

    echo_info "正在获取最新版本信息..."

    # 检查 GitHub CLI
    if command -v gh &> /dev/null && gh auth status &> /dev/null; then
        latest_info=$(gh release view --repo "$REPO_SLUG" --json tagName,url 2>/dev/null || echo "")
        latest_version=$(echo "$latest_info" | grep -o '"tagName"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    fi

    # 备用方案: 使用 API
    if [ -z "$latest_version" ]; then
        latest_version=$(curl -s "https://api.github.com/repos/$REPO_SLUG/releases/latest" 2>/dev/null | \
            grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
    fi

    if [ -z "$latest_version" ]; then
        echo_error "无法获取最新版本（该仓库可能还没有 Release）"
        exit 1
    fi

    echo_info "最新版本: $latest_version"

    # 获取可用的下载资产
    echo ""
    echo_info "可用下载包:"

    if command -v gh &> /dev/null && gh auth status &> /dev/null; then
        assets=$(gh release view "$latest_version" --repo "$REPO_SLUG" --json assets -q '.assets[] | .name' 2>/dev/null || echo "")
        if [ -n "$assets" ]; then
            echo "$assets" | while read -r asset; do
                echo "  - $asset"
            done
        fi
    fi

    echo ""
    echo_info "下载页: https://github.com/$REPO_SLUG/releases/tag/$latest_version"
    echo_info "应用内市场源: https://github.com/$REPO_SLUG/releases/latest/download/repo.json"
}

# 清除 GitHub Actions
clean_actions() {
    echo ""
    echo "=== 清除 GitHub Actions ==="
    echo ""
    echo "  1. 清除失败的 Actions"
    echo "  2. 清除所有 Actions"
    echo "  0. 返回"
    echo ""
    read -p "请选择: " sub_choice

    case $sub_choice in
        1)
            clean_failed_actions
            ;;
        2)
            clean_all_actions
            ;;
        0)
            return
            ;;
        *)
            echo_error "无效选择"
            ;;
    esac
}

# 清除失败的 GitHub Actions
clean_failed_actions() {
    echo ""
    echo "=== 清除失败的 GitHub Actions ==="
    echo ""

    if ! command -v gh &> /dev/null; then
        echo_error "需要安装 GitHub CLI"
        echo "安装命令: brew install gh"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        echo_error "未登录 GitHub"
        echo "请运行: gh auth login"
        exit 1
    fi

    echo_info "获取失败的 Actions 运行..."

    failed_runs=$(gh run list --repo "$REPO_SLUG" --status failure --json databaseId,workflowName --jq '.[] | "\(.databaseId) \(.workflowName)"' 2>/dev/null)

    if [ -z "$failed_runs" ]; then
        echo_info "没有失败的 Actions 运行"
        return
    fi

    echo ""
    echo_info "找到以下失败的运行:"
    echo "$failed_runs" | while read -r id name; do
        echo "  - [$id] $name"
    done

    echo ""
    read -p "确认删除所有失败运行? (y/n): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        echo ""
        echo_info "正在删除..."
        echo "$failed_runs" | while read -r id name; do
            gh run delete "$id" --repo "$REPO_SLUG" 2>/dev/null && echo_success "已删除: $name ($id)" || echo_error "删除失败: $id"
        done
        echo_success "清理完成!"
    else
        echo_info "已取消"
    fi
}

# 清除所有 GitHub Actions
clean_all_actions() {
    echo ""
    echo "=== 清除所有 GitHub Actions ==="
    echo ""

    if ! command -v gh &> /dev/null; then
        echo_error "需要安装 GitHub CLI"
        echo "安装命令: brew install gh"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        echo_error "未登录 GitHub"
        echo "请运行: gh auth login"
        exit 1
    fi

    echo_warning "此操作将删除所有 Actions 运行记录！"
    echo ""
    read -p "确认删除所有 Actions? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo_info "已取消"
        return
    fi

    echo ""
    echo_info "获取所有 Actions 运行..."

    all_runs=$(gh run list --repo "$REPO_SLUG" --json databaseId --jq '.[] | .databaseId' 2>/dev/null)

    if [ -z "$all_runs" ]; then
        echo_info "没有 Actions 运行"
        return
    fi

    echo_info "正在删除..."
    deleted=0
    failed=0
    for id in $all_runs; do
        if gh run delete "$id" --repo "$REPO_SLUG" 2>/dev/null; then
            ((deleted++)) || true
        else
            ((failed++)) || true
        fi
    done
    echo_success "已删除: $deleted 个, 失败: $failed 个"
}

# 删除 tag
delete_tag() {
    echo ""
    echo "=== 删除 Tag ==="
    echo ""
    echo "  1. 删除指定 Tag"
    echo "  2. 删除所有 Tags"
    echo "  0. 返回"
    echo ""
    read -p "请选择: " sub_choice

    case $sub_choice in
        1)
            delete_single_tag
            ;;
        2)
            delete_all_tags
            ;;
        0)
            return
            ;;
        *)
            echo_error "无效选择"
            ;;
    esac
}

# 删除指定 tag
delete_single_tag() {
    echo ""
    echo "=== 删除指定 Tag ==="
    echo ""

    remote_name=$(git remote 2>/dev/null | head -1)
    if [ -z "$remote_name" ]; then
        echo_error "未找到远程仓库"
        exit 1
    fi

    echo_info "本地 Tags:"
    git tag --sort=-version:refname | head -10

    echo ""
    read -p "输入要删除的 tag 名称 (如 plugin-v0.1.9): " tag_name

    if [ -z "$tag_name" ]; then
        echo_error "请输入 tag 名称"
        exit 1
    fi

    if ! git tag | grep -q "^${tag_name}$"; then
        echo_error "本地未找到 tag: $tag_name"
        exit 1
    fi

    echo ""
    read -p "确认删除本地 tag '$tag_name'? (y/n): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        git tag -d "$tag_name"
        echo_success "已删除本地 tag: $tag_name"
    fi

    echo ""
    read -p "同时删除远程 tag '$tag_name'? (y/n): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        git push "$remote_name" --delete "$tag_name" 2>/dev/null && echo_success "已删除远程 tag: $tag_name" || echo_warning "远程 tag 可能不存在"
    fi
}

# 删除所有 tags
delete_all_tags() {
    echo ""
    echo "=== 删除所有 Tags ==="
    echo ""

    remote_name=$(git remote 2>/dev/null | head -1)
    if [ -z "$remote_name" ]; then
        echo_error "未找到远程仓库"
        exit 1
    fi

    local_tags=$(git tag --sort=-version:refname 2>/dev/null)
    if [ -z "$local_tags" ]; then
        echo_info "没有本地 Tags"
        return
    fi

    echo_info "本地 Tags:"
    echo "$local_tags" | head -10
    echo ""

    echo_warning "此操作将删除所有本地和远程 Tags！"
    echo ""
    read -p "确认删除所有 Tags? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo_info "已取消"
        return
    fi

    echo ""
    echo_info "正在删除本地 Tags..."
    deleted_local=0
    for tag in $local_tags; do
        if git tag -d "$tag" 2>/dev/null; then
            ((deleted_local++)) || true
        fi
    done
    echo_success "已删除本地 Tags: $deleted_local 个"

    echo_info "正在删除远程 Tags..."
    deleted_remote=0
    failed_remote=0
    for tag in $local_tags; do
        if git push "$remote_name" --delete "$tag" 2>/dev/null; then
            ((deleted_remote++)) || true
        else
            ((failed_remote++)) || true
        fi
    done
    echo_success "已删除远程 Tags: $deleted_remote 个, 失败: $failed_remote 个"
}

# 重新触发最新版本的 GitHub Actions
rerun_latest_action() {
    echo ""
    echo "=== 重新触发最新版本的 GitHub Actions ==="
    echo ""

    # 检查 GitHub CLI
    if ! command -v gh &> /dev/null; then
        echo_error "需要安装 GitHub CLI"
        echo "安装命令: brew install gh"
        exit 1
    fi

    # 检查登录状态
    if ! gh auth status &> /dev/null; then
        echo_error "未登录 GitHub"
        echo "请运行: gh auth login"
        exit 1
    fi

    # 获取远程仓库名称
    remote_name=$(git remote 2>/dev/null | head -1)
    if [ -z "$remote_name" ]; then
        echo_error "未找到远程仓库"
        exit 1
    fi
    echo_info "检测到远程仓库: $remote_name"

    # 获取最新 tag
    echo_info "获取最新版本 tag..."
    latest_tag=$(get_current_version)

    if [ -z "$latest_tag" ]; then
        echo_error "未找到任何 plugin-v* tag"
        exit 1
    fi

    echo_info "最新版本: $latest_tag"
    echo ""
    read -p "确认重新触发 $latest_tag 的构建? (y/n): " confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo_info "已取消"
        return
    fi

    # 删除并重新推送 tag
    echo ""
    echo_info "删除远程 tag..."
    git push "$remote_name" --delete "$latest_tag" 2>/dev/null || echo_warning "远程 tag 可能不存在"

    echo_info "重新推送 tag: $latest_tag"
    git push "$remote_name" "$latest_tag"

    echo_success "已重新触发 GitHub Actions!"
    echo_info "查看构建进度: https://github.com/$REPO_SLUG/actions"
}

# 发布指定插件（子菜单：CI 单插件构建发布 / 单独更新 repo.json）
#
# 场景 1（CI 发布）：单插件迭代后不想全量重发——触发 plugin-release.yml 的
#   workflow_dispatch，三平台只构建该插件，只上传该插件 zip + repo.json。
#   构建基于 --ref 指定的分支（默认当前分支），发布到指定 tag 的 release。
# 场景 2（仅 repo.json）：本地手动改了 repo.json（描述/权限/平台声明等），
#   不重打 zip，直接覆盖最新 release 上的 repo.json 资产。
publish_single_plugin() {
    echo ""
    echo "=== 发布指定插件 ==="
    echo ""
    echo "  1. 触发 CI 构建发布指定插件（三平台构建 + 签名 + 上传 release）"
    echo "  2. 单独更新 repo.json 到最新 Release（不重新打包）"
    echo "  0. 返回"
    echo ""
    read -p "请选择: " sub_choice

    case $sub_choice in
        1)
            dispatch_single_plugin_ci
            ;;
        2)
            update_repo_json_only
            ;;
        0)
            return
            ;;
        *)
            echo_error "无效选择"
            ;;
    esac
}

# 检查 gh CLI 可用性（未安装/未登录直接报错退出）
require_gh() {
    if ! command -v gh &> /dev/null; then
        echo_error "需要安装 GitHub CLI"
        echo "安装命令: brew install gh"
        exit 1
    fi
    if ! gh auth status &> /dev/null; then
        echo_error "未登录 GitHub"
        echo "请运行: gh auth login"
        exit 1
    fi
}

# 交互式选择插件（复用本地打包的编号选择逻辑；返回全局数组 SELECTED_PLUGINS）
select_plugins() {
    echo_info "可用插件:"
    available=()
    while IFS= read -r p; do
        available+=("$p")
        echo "  $((${#available[@]})). $p"
    done < <(list_plugins)

    if [ ${#available[@]} -eq 0 ]; then
        echo_error "package/ 下没有可用插件"
        return 1
    fi

    echo ""
    read -p "输入插件编号（逗号分隔，回车=全部）: " choice

    SELECTED_PLUGINS=()
    if [ -z "$choice" ]; then
        SELECTED_PLUGINS=("${available[@]}")
    else
        IFS=',' read -ra idx <<< "$choice"
        for i in "${idx[@]}"; do
            SELECTED_PLUGINS+=("${available[$((i-1))]}")
        done
    fi
}

# 场景 1: 触发 CI workflow_dispatch 单插件构建发布
dispatch_single_plugin_ci() {
    require_gh

    remote_name=$(git remote 2>/dev/null | head -1)
    if [ -z "$remote_name" ]; then
        echo_error "未找到远程仓库"
        return 1
    fi
    echo_info "检测到远程仓库: $remote_name"

    # 选择插件（CI dispatch 一次只传一个插件，多选则逐个触发）
    select_plugins || return 1

    # 发布目标 tag（release 资产挂载点）：留空推荐最新 tag +1（新建 release，
    # CI 会自动从上一个 release 继承其它插件 zip，保证市场相对 URL 不 404）；
    # 输入已有 tag 则挂载到现有 release（覆盖同名资产）
    latest_tag=$(get_current_version)
    if [ -z "$latest_tag" ]; then
        echo_error "仓库还没有 plugin-v* tag，请先通过菜单 2 发布首个版本"
        return 1
    fi
    if [[ "$latest_tag" =~ ^plugin-v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        recommended_tag="plugin-v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
    else
        recommended_tag="$latest_tag"
    fi
    echo_info "当前最新版本 tag: $latest_tag"
    echo ""
    read -p "输入发布目标 tag (留空=$recommended_tag 新建 release；输入 $latest_tag 挂现有 release): " target_tag
    if [ -z "$target_tag" ]; then
        target_tag="$recommended_tag"
    fi

    # 构建代码源分支：默认当前分支（插件最新代码），可指定
    current_branch=$(git branch --show-current)
    echo ""
    read -p "输入构建分支 (留空=当前分支 $current_branch): " build_ref
    build_ref="${build_ref:-$current_branch}"

    echo ""
    echo_warning "即将触发 CI: 插件 [${SELECTED_PLUGINS[*]}] ← 分支 $build_ref → 发布到 $target_tag"
    read -p "确认执行? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo_info "已取消"
        return
    fi

    for plugin in "${SELECTED_PLUGINS[@]}"; do
        echo_info "触发 workflow_dispatch: plugin=$plugin tag=$target_tag ref=$build_ref"
        if ! gh workflow run plugin-release.yml --repo "$REPO_SLUG" --ref "$build_ref" \
            -f plugin="$plugin" -f tag="$target_tag"; then
            echo_error "触发失败: $plugin（检查分支 $build_ref 是否存在且包含 plugin-release.yml）"
            return 1
        fi
    done

    echo_success "已触发 CI 单插件发布!"
    echo_info "查看构建进度: https://github.com/$REPO_SLUG/actions"
}

# 场景 2: 单独更新 repo.json 到最新 release（不重新打包）
update_repo_json_only() {
    require_gh

    if [ ! -f "$REPO_ROOT/package/repo.json" ]; then
        echo_error "未找到 package/repo.json"
        return 1
    fi

    # 目标 tag：默认最新 plugin-v* tag
    default_tag=$(get_current_version)
    if [ -n "$default_tag" ]; then
        echo_info "当前最新版本 tag: $default_tag"
    fi
    echo ""
    read -p "输入目标 tag (留空=${default_tag:-无}): " target_tag
    target_tag="${target_tag:-$default_tag}"
    if [ -z "$target_tag" ]; then
        echo_error "仓库还没有 plugin-v* tag，请先通过菜单 2 发布首个版本"
        return 1
    fi

    # repo.json 是市场索引权威源：展示变更摘要再确认
    echo ""
    echo_info "即将上传的 repo.json（前 30 行）:"
    head -30 "$REPO_ROOT/package/repo.json"
    echo ""
    echo_warning "将覆盖 release $target_tag 上的 repo.json 资产（市场源 URL 不变）"
    read -p "确认上传? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo_info "已取消"
        return
    fi

    if gh release upload "$target_tag" "$REPO_ROOT/package/repo.json" --clobber --repo "$REPO_SLUG"; then
        echo_success "repo.json 已更新到 release $target_tag!"
        echo_info "市场源地址: https://github.com/$REPO_SLUG/releases/latest/download/repo.json"
    else
        echo_error "上传失败（检查 release $target_tag 是否存在）"
        return 1
    fi
}

# 将本地 beta 分支远程推送到 main（全程不检出 main，本地只保留 beta 分支）
#
# 合并策略（按序判定）:
#   1. 远程 main 不存在            → 直接推送 beta 首建 main
#   2. beta 是远程 main 的祖先     → 无新内容，明确提示（不假成功）
#   3. 远程 main 是 beta 的祖先    → fast-forward 推送（零 merge commit，最常见路径）
#   4. 分叉                        → GitHub API merge；成功后把含 merge commit 的
#                                    main 回写到远程 beta（消除分叉，下次回到 ff 路径）
merge_beta_to_main() {
    echo ""
    echo "=== 推送 beta 内容到远程 main 分支 ==="
    echo ""

    # 检查远程仓库
    remote_name=$(git remote 2>/dev/null | head -1)
    if [ -z "$remote_name" ]; then
        echo_error "未找到远程仓库"
        return 1
    fi

    # 校验本地 beta 分支存在
    if ! git show-ref --verify --quiet refs/heads/beta; then
        echo_error "本地未找到 beta 分支"
        return 1
    fi

    # 工作区必须干净，确保推送内容与本地提交状态一致
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        echo_error "工作区有未提交的更改，请先提交或暂存 (git stash)"
        git status --short
        return 1
    fi

    # 拉取远程最新引用
    echo_info "拉取远程最新代码..."
    if ! git fetch "$remote_name" --prune; then
        echo_error "git fetch 失败"
        return 1
    fi

    # 场景 1: 远程 main 尚不存在 → 推送 beta 首建 main
    if ! git rev-parse --verify -q "refs/remotes/$remote_name/main" >/dev/null; then
        echo_info "远程 main 不存在，推送 beta 首建..."
        if git push "$remote_name" beta:main; then
            echo_success "远程 main 已创建并同步到 beta!"
            return 0
        fi
        echo_error "推送 main 失败，请检查远程仓库权限"
        return 1
    fi

    # 场景 2: beta 已被远程 main 包含 → 无新内容（merges API 对此返回 409，
    # 旧实现回退推送 Everything-up-to-date 后仍显示成功，造成「假成功」）
    if git merge-base --is-ancestor beta "refs/remotes/$remote_name/main"; then
        echo_info "远程 main 已包含 beta 全部提交，无需合并"
        return 0
    fi

    # 场景 3: fast-forward 可行（远程 main 是 beta 的祖先）→ 直接推送
    if git merge-base --is-ancestor "refs/remotes/$remote_name/main" beta; then
        echo_info "远程 main 落后于 beta，fast-forward 推送..."
        if git push "$remote_name" beta:main; then
            echo_success "远程 main 已同步到 beta!"
            return 0
        fi
        echo_error "fast-forward 推送失败，请检查远程仓库权限"
        return 1
    fi

    # 场景 4: 真分叉 → GitHub API 服务端合并
    if command -v gh &> /dev/null && gh auth status &> /dev/null && [[ "$REPO_NAME" == */* ]]; then
        # 先同步远程 beta，保证服务端合并包含本地最新内容
        echo_info "同步本地 beta 到远程 beta..."
        if ! git push "$remote_name" beta; then
            echo_error "推送 beta 失败（远程 beta 可能包含本地没有的提交），请先执行 git pull 同步 beta 分支"
            return 1
        fi
        echo_info "分支已分叉，调用 GitHub API 远程合并 beta -> main..."
        if merge_output=$(gh api -X POST "repos/$REPO_NAME/merges" -f base=main -f head=beta 2>&1); then
            echo_success "GitHub API 远程合并完成: beta 已合并到 main!"
            return 0
        fi
        if echo "$merge_output" | grep -qi "conflict"; then
            echo_error "远程合并存在冲突，无法自动完成，请在本地手动处理"
            return 1
        fi
        echo_error "GitHub API 合并失败: $merge_output"
        echo_info "分支已分叉且 API 合并失败，请手动处理（本地: git checkout main && git merge beta && git push && git checkout beta）"
        return 1
    fi

    echo_error "分支已分叉且未安装/登录 GitHub CLI，无法自动合并: brew install gh && gh auth login"
    return 1
}

# 主菜单
show_menu() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║       SwallowNotePlugins 插件发布工具 v1.0       ║"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║  1. 提交代码到 GitHub                            ║"
    echo "║  2. 发布新版本 (plugin-v* tag 触发 Actions)      ║"
    echo "║  3. 本地打包插件 (bump+构建+签名+repo.json)      ║"
    echo "║  4. 清除 Actions                                ║"
    echo "║  5. 删除 Tag                                    ║"
    echo "║  6. 重新触发最新版本 GitHub Actions              ║"
    echo "║  7. 推送 beta 内容到远程 main 分支               ║"
    echo "║  8. 发布指定插件 (CI 单插件发布/更新 repo.json)  ║"
    echo "║  0. 退出                                        ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
}

# 主程序
main() {
    check_git_status

    while true; do
        show_menu
        read -p "请选择操作 (0-8): " choice

        case $choice in
            1)
                push_to_github
                ;;
            2)
                create_release
                ;;
            3)
                local_package
                ;;
            4)
                clean_actions
                ;;
            5)
                delete_tag
                ;;
            6)
                rerun_latest_action
                ;;
            7)
                merge_beta_to_main
                ;;
            8)
                publish_single_plugin
                ;;
            0)
                echo_info "再见!"
                exit 0
                ;;
            *)
                echo_error "无效选择，请输入 0-8"
                ;;
        esac

        echo ""
        read -p "按 Enter 继续..." dummy
    done
}

# 仅在直接执行时进入交互主循环；被 source（测试）时不启动
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main
fi
