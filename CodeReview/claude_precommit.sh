#!/bin/bash

# 添加：执行前选择弹窗（放在最前面）
# macOS 弹窗函数
show_macos_dialog() {
  local message="$1"
  local title="$2"
  local buttons="$3"
  local default_button="$4"

  osascript <<EOF 2>/dev/null
    set theMessage to "$message"
    set theButtons to {$buttons}
    set theResult to display dialog theMessage buttons theButtons default button "$default_button" with title "$title" with icon note
    return button returned of theResult
EOF
  return $?
}

# 检测操作系统类型（仅 macOS）
IS_MAC=false
if [[ "$OSTYPE" == "darwin"* ]]; then
  IS_MAC=true
fi

# 检测是否有 GUI 会话（macOS）
HAS_GUI_SESSION=true
if [ "$IS_MAC" = true ]; then
  # 尝试运行 osascript 测试
  if ! osascript -e 'tell application "System Events" to get name of every process' >/dev/null 2>&1; then
    HAS_GUI_SESSION=false
  fi
fi

# 检测是否在 pre-commit hook 中运行
IS_PRE_COMMIT=false
if [ -n "$GIT_PREFIX" ] || [ -n "$GIT_INDEX_FILE" ]; then
  IS_PRE_COMMIT=true
fi

# 执行前选择：只在非pre-commit模式下显示，并且有GUI会话
if [ "$IS_PRE_COMMIT" = false ] && [ "$IS_MAC" = true ] && [ "$HAS_GUI_SESSION" = true ]; then
  echo "显示执行前选择弹窗..."
  
  # 显示执行前选择弹窗
  EXEC_CHOICE=$(show_macos_dialog \
    "请选择执行方式：\n\n1. 审核代码 - 分析代码变更并生成审核报告\n2. 直接提交 - 跳过审核直接提交代码" \
    "代码提交 - 执行选择" \
    "\"审核代码\", \"直接提交\"" \
    "审核代码")
  
  if [ $? -eq 0 ] && [ -n "$EXEC_CHOICE" ]; then
    case "$EXEC_CHOICE" in
      "直接提交")
        echo "✅ 用户选择直接提交，跳过代码审核"
        exit 0
        ;;
      "审核代码")
        echo "✅ 用户选择审核代码，继续执行审核流程"
        ;;
    esac
  fi
fi

# 如果不是macOS或没有GUI，或者是在pre-commit中运行，显示命令行选择
if [ "$IS_PRE_COMMIT" = false ] && { [ "$IS_MAC" = false ] || [ "$HAS_GUI_SESSION" = false ] || [ -z "$EXEC_CHOICE" ]; }; then
  echo "================================================================="
  echo "                代码提交 - 执行选择"
  echo "================================================================="
  echo ""
  echo "请选择执行方式："
  echo ""
  echo "  1) 审核代码 - 分析代码变更并生成审核报告"
  echo "  2) 直接提交 - 跳过审核直接提交代码"
  echo ""
  
  # 检查标准输入是否可用
  if [ -t 0 ]; then
    while true; do
      printf "你的选择 (1或2): "
      read choice
      choice=$(echo "$choice" | xargs)

      if [ -z "$choice" ]; then
        echo ""
        echo "提示： 请输入 1 或 2，或按 ctrl+c 取消"
        echo ""
        continue
      fi

      case "$choice" in
        1|"审核代码")
          echo ""
          echo "✅ 继续执行代码审核"
          echo ""
          break
          ;;
        2|"直接提交")
          echo ""
          echo "✅ 直接提交，跳过代码审核"
          exit 0
          ;;
        *)
          echo ""
          echo "提示： 请输入 1 或 2"
          echo ""
          ;;
      esac
    done
  else
    # 非交互式环境，默认执行审核
    echo "⚠️  非交互式环境，自动执行代码审核"
    echo ""
  fi
fi

# 如果是pre-commit模式，直接执行审核（不显示选择）
if [ "$IS_PRE_COMMIT" = true ]; then
  echo "pre-commit hook 模式，自动执行代码审核"
fi

# 以下是您原来的脚本内容，不做任何修改
echo "🔍 Claude Code 正在审核本次提交..."

# 检测 git 命令路径
if command -v git &> /dev/null; then
  GIT_CMD="git"
elif [ -f "/usr/bin/git" ]; then
  GIT_CMD="/usr/bin/git"
elif [ -f "/usr/local/bin/git" ]; then
  GIT_CMD="/usr/local/bin/git"
else
  echo "❌ 错误: 找不到 git 命令"
  exit 1
fi

# 确保在项目根目录执行
PROJECT_ROOT="$($GIT_CMD rev-parse --show-toplevel)"
cd "$PROJECT_ROOT" || exit 1

# 设置临时文件路径
TMP_DIR="/tmp"
DIFF_FILE="$TMP_DIR/claude_diff_$$.patch"

# ⚠️ 一定要用 git diff - 使用完整路径，禁用 pager
$GIT_CMD --no-pager diff --cached > "$DIFF_FILE"

if [ ! -s "$DIFF_FILE" ]; then
  echo "ℹ️ 无 staged 变更，跳过审核"
  rm -f "$DIFF_FILE"
  exit 0
fi

# ... [后面所有原有代码保持不变] ...
