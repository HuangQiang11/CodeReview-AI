#!/bin/bash
set -e

echo "🚀 开始自动接入 CodeReview AI..."

# 1️⃣ 确保在 Git 仓库中
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "❌ 当前目录不是 Git 仓库"
  exit 1
fi

# 2️⃣ 获取项目根目录
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "$PROJECT_ROOT"

echo "📁 项目根目录：$PROJECT_ROOT"

# 3️⃣ CodeReview 仓库信息
CODEREVIEW_REPO="https://github.com/HuangQiang11/CodeReview-AI.git"
CODEREVIEW_DIR="$PROJECT_ROOT/CodeReview"

# 4️⃣ 若本地已有 CodeReview，用线上版本替换
if [ -d "$CODEREVIEW_DIR" ]; then
  echo "♻️ 检测到本地 CodeReview，使用线上版本替换..."
  rm -rf "$CODEREVIEW_DIR"
fi

# 5️⃣ 拉取 CodeReview
echo "⬇️ 拉取 CodeReview 代码..."
git clone --depth=1 "$CODEREVIEW_REPO" /tmp/CodeReview-AI
mv /tmp/CodeReview-AI/CodeReview "$CODEREVIEW_DIR"
rm -rf /tmp/CodeReview-AI

# 6️⃣ 赋予执行权限
chmod +x "$CODEREVIEW_DIR/claude_precommit.sh"

# ================================
# Git Hook 处理
# ================================

HOOKS_DIR="$PROJECT_ROOT/.git/hooks"
HOOK_FILE="$HOOKS_DIR/pre-commit"

# 7️⃣ 确保 hooks 目录存在
if [ ! -d "$HOOKS_DIR" ]; then
  echo "📂 创建 hooks 目录"
  mkdir -p "$HOOKS_DIR"
fi

# 8️⃣ 确保 pre-commit 文件存在
if [ ! -f "$HOOK_FILE" ]; then
  echo "🪝 创建 pre-commit 文件"
  touch "$HOOK_FILE"
  chmod +x "$HOOK_FILE"
fi

# 9️⃣ 检测是否已接入 CodeReview
if grep -q "claude_precommit.sh" "$HOOK_FILE"; then
  echo "ℹ️ pre-commit 已接入 CodeReview，跳过追加"
else
  echo "➕ 向 pre-commit 追加 CodeReview Hook"

  cat >> "$HOOK_FILE" << 'EOF'

# ================================
# CodeReview AI Hook (Auto Added)
# ================================

echo "pre-commit hook is running (CodeReview AI)"

PROJECT_ROOT="$(git rev-parse --show-toplevel)"

"$PROJECT_ROOT/CodeReview/claude_precommit.sh"

# ================================
# End CodeReview AI Hook
# ================================
EOF
fi

echo "✅ CodeReview AI 自动接入完成！"
