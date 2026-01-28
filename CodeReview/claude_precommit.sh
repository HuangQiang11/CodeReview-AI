#!/bin/bash

# ============================================================================
# 工具函数
# ============================================================================

# 清理临时文件
cleanup_temp_files() {
  rm -f "$DIFF_FILE" "$TEMP_RESULT" "$TEMP_PID" 2>/dev/null
}

# 命令行交互：询问用户是否继续提交（通用函数）
# 参数: $1 - 提示消息标题（可选）
ask_user_continue_commit() {
  local title="${1:-代码审核结果}"
  
  echo ""
  echo "================================================================="
  echo "$title"
  echo "================================================================="
  echo ""
  echo "输入命令："
  echo "  1) yes  - 继续提交"
  echo "  2) no   - 取消提交"
  echo ""

  while true; do
    printf "你的选择 (yes/no): "
    read choice
    choice=$(echo "$choice" | xargs)

    if [ -z "$choice" ]; then
      echo ""
      echo "提示： 请输入 yes 或 no， 或按 ctrl+c 取消"
      echo ""
      continue
    fi

    case "$choice" in
      yes|y|Y|YES)
        echo ""
        echo "✅ 已批准提交"
        echo ""
        cleanup_temp_files
        exit 0
        ;;
      no|n|N|NO)
        echo ""
        echo "❌ 已阻断提交"
        echo ""
        echo "请修复问题后重新提交"
        exit 1
        ;;
      *)
        echo ""
        echo "提示： 请输入 yes 或 no， 或按 ctrl+c 取消"
        echo ""
        ;;
    esac
  done
}

# ============================================================================
# 执行前选择弹窗（放在最前面）
# ============================================================================

# 检测是否是macOS
if [[ "$OSTYPE" == "darwin"* ]]; then
  # 尝试显示macOS弹窗
  CHOICE=$(osascript <<EOF 2>/dev/null
    set theResult to display dialog "请选择执行方式：" & return & return & "1. 审核代码 - 分析代码变更并生成审核报告" & return & "2. 直接提交 - 跳过审核直接提交代码" ¬
        buttons {"审核代码", "直接提交"} ¬
        default button "审核代码" ¬
        with title "代码提交 - 执行选择" ¬
        with icon note
    return button returned of theResult
EOF
  )
  
  if [ $? -eq 0 ] && [ -n "$CHOICE" ]; then
    case "$CHOICE" in
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

# 如果弹窗失败或不是macOS，显示命令行选择
if [[ "$OSTYPE" != "darwin"* ]] || [ -z "$CHOICE" ]; then
  echo "================================================================="
  echo "                代码提交 - 执行选择"
  echo "================================================================="
  echo ""
  echo "请选择执行方式："
  echo ""
  echo "  1) 审核代码 - 分析代码变更并生成审核报告"
  echo "  2) 直接提交 - 跳过审核直接提交代码"
  echo ""
  
  if [ -t 0 ]; then
    while true; do
      printf "你的选择 (1或2): "
      read choice
      choice=$(echo "$choice" | xargs)

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
          echo "提示： 请输入 1 或 2"
          ;;
      esac
    done
  else
    echo "自动执行代码审核"
    echo ""
  fi
fi

# ============================================================================
# 环境检测和初始化
# ============================================================================

# 检测是否在 pre-commit hook 中运行
IS_PRE_COMMIT=false
if [ -n "$GIT_PREFIX" ] || [ -n "$GIT_INDEX_FILE" ]; then
  IS_PRE_COMMIT=true
fi

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

echo "🔍 Claude Code 正在审核本次提交..."

# ============================================================================
# 文件路径初始化
# ============================================================================

# 设置临时文件路径
TMP_DIR="/tmp"
DIFF_FILE="$TMP_DIR/claude_diff_$$.patch"
TEMP_RESULT=""
TEMP_PID=""

# 设置审核结果输出文件
REVIEW_FILE="$PROJECT_ROOT/last_review_info.txt"

# ⚠️ 一定要用 git diff - 使用完整路径，禁用 pager
$GIT_CMD --no-pager diff --cached > "$DIFF_FILE"

if [ ! -s "$DIFF_FILE" ]; then
  echo "ℹ️ 无 staged 变更，跳过审核"
  cleanup_temp_files
  exit 0
fi

# ============================================================================
# 项目类型检测（iOS 或 Android）
# ============================================================================

# 检测 iOS 项目特征
IOS_INDICATORS=0
[ -f "$PROJECT_ROOT/Podfile" ] && IOS_INDICATORS=$((IOS_INDICATORS + 1))
find "$PROJECT_ROOT" -maxdepth 1 -name "*.xcodeproj" -o -name "*.xcworkspace" 2>/dev/null | grep -q . && IOS_INDICATORS=$((IOS_INDICATORS + 1))
find "$PROJECT_ROOT" -maxdepth 2 -name "Info.plist" 2>/dev/null | grep -q . && IOS_INDICATORS=$((IOS_INDICATORS + 1))

# 检测 Android 项目特征
ANDROID_INDICATORS=0
([ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/settings.gradle" ]) && ANDROID_INDICATORS=$((ANDROID_INDICATORS + 1))
([ -f "$PROJECT_ROOT/app/build.gradle" ] || [ -d "$PROJECT_ROOT/app" ]) && ANDROID_INDICATORS=$((ANDROID_INDICATORS + 1))
find "$PROJECT_ROOT" -maxdepth 2 -name "AndroidManifest.xml" 2>/dev/null | grep -q . && ANDROID_INDICATORS=$((ANDROID_INDICATORS + 1))

# 根据指标数量判断项目类型
if [ $IOS_INDICATORS -gt $ANDROID_INDICATORS ]; then
  PROJECT_TYPE="ios"
  echo "📱 检测到 iOS 项目"
elif [ $ANDROID_INDICATORS -gt 0 ]; then
  PROJECT_TYPE="android"
  echo "🤖 检测到 Android 项目"
else
  # 默认使用 iOS（如果无法检测）
  PROJECT_TYPE="ios"
  echo "⚠️  无法确定项目类型，默认使用 iOS 审核规则"
fi

# ============================================================================
# 提示词文件配置
# ============================================================================

# 根据项目类型设置审核提示词文件
if [ "$PROJECT_TYPE" = "ios" ]; then
  PROMPT_FILE="$PROJECT_ROOT/CodeReview/claude_prompt_ios.txt"
elif [ "$PROJECT_TYPE" = "android" ]; then
  PROMPT_FILE="$PROJECT_ROOT/CodeReview/claude_prompt_android.txt"
else
  PROMPT_FILE="$PROJECT_ROOT/CodeReview/claude_prompt.txt"
fi

# 获取变更的文件列表
CHANGED_FILES=$(grep "^diff --git" "$DIFF_FILE" | sed 's/diff --git a\///' | sed 's/diff --git b\///' | cut -d' ' -f1 | sort | uniq)

# 检查提示词文件是否存在，如果不存在则尝试使用默认文件
if [ ! -f "$PROMPT_FILE" ]; then
  echo "⚠️  提示词文件不存在: $PROMPT_FILE"
  
  # 尝试使用默认文件
  DEFAULT_PROMPT_FILE="$PROJECT_ROOT/CodeReview/claude_prompt.txt"
  if [ -f "$DEFAULT_PROMPT_FILE" ]; then
    echo "ℹ️  使用默认提示词文件: $DEFAULT_PROMPT_FILE"
    PROMPT_FILE="$DEFAULT_PROMPT_FILE"
  else
    echo "❌ 错误: 提示词文件不存在，且默认文件也不存在"
    echo "   请创建以下文件之一："
    echo "   - $PROJECT_ROOT/CodeReview/claude_prompt_ios.txt (iOS 项目)"
    echo "   - $PROJECT_ROOT/CodeReview/claude_prompt_android.txt (Android 项目)"
    echo "   - $PROJECT_ROOT/CodeReview/claude_prompt.txt (通用)"
    cleanup_temp_files
    exit 1
  fi
fi

# ============================================================================
# Claude 命令检测
# ============================================================================

# 检查 claude 命令是否可用（尝试多个可能的路径）
CLAUDE_CMD=""
CLAUDE_AVAILABLE=false

# 尝试多个可能的 claude 命令路径
for path in "claude" \
            "$HOME/.local/bin/claude" \
            "/usr/local/bin/claude" \
            "/opt/homebrew/bin/claude" \
            "$HOME/bin/claude"; do
  if command -v "$path" &> /dev/null || ([ -f "$path" ] && [ -x "$path" ]); then
    CLAUDE_CMD="$path"
    CLAUDE_AVAILABLE=true
    break
  fi
done

# ============================================================================
# Claude 调用和结果处理
# ============================================================================

# 调用 claude（带超时处理，默认 60 秒）
CLAUDE_TIMEOUT=60
CLAUDE_ERROR=false
RAW_RESULT=""

if [ "$CLAUDE_AVAILABLE" = true ] && [ -n "$CLAUDE_CMD" ]; then
  echo "⏳ 正在调用 Claude 进行代码审核（最多等待 ${CLAUDE_TIMEOUT} 秒）..."
  echo "   使用命令: $CLAUDE_CMD"
  
  # 创建临时文件存储结果
  TEMP_RESULT=$(mktemp 2>/dev/null || echo "$TMP_DIR/claude_result_$$.txt")
  TEMP_PID=$(mktemp 2>/dev/null || echo "$TMP_DIR/claude_pid_$$.txt")
  touch "$TEMP_RESULT" "$TEMP_PID"
  
  # 在后台运行 claude（使用完整路径，并确保环境变量正确）
  (
    # 确保 PATH 包含常用路径
    export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$HOME/bin:$PATH"
    "$CLAUDE_CMD" <<EOF 2>&1
$(cat "$PROMPT_FILE")
git diff 内容如下：
$(cat "$DIFF_FILE")
EOF
    echo $? > "$TEMP_PID"
  ) > "$TEMP_RESULT" 2>&1 &
  
  CLAUDE_PID=$!
  
  # 验证后台进程是否成功启动
  sleep 0.5
  if ! kill -0 $CLAUDE_PID 2>/dev/null; then
    # 进程立即退出了，可能是启动失败
    CLAUDE_ERROR=true
    echo "⚠️  Claude 进程启动失败，检查错误信息："
    if [ -f "$TEMP_RESULT" ]; then
      cat "$TEMP_RESULT" | head -20
      RAW_RESULT=$(cat "$TEMP_RESULT" 2>/dev/null)
    fi
    rm -f "$TEMP_RESULT" "$TEMP_PID"
  else
    # 进程成功启动，等待进程完成或超时
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt $CLAUDE_TIMEOUT ]; do
      if ! kill -0 $CLAUDE_PID 2>/dev/null; then
        # 进程已结束
        break
      fi
      sleep 1
      WAIT_COUNT=$((WAIT_COUNT + 1))
    done
    
    # 检查是否超时
    if kill -0 $CLAUDE_PID 2>/dev/null; then
      # 进程仍在运行，超时了
      kill $CLAUDE_PID 2>/dev/null
      kill -9 $CLAUDE_PID 2>/dev/null
      CLAUDE_ERROR=true
      echo "⏱️  Claude 审核超时（${CLAUDE_TIMEOUT} 秒）"
      RAW_RESULT=""
      rm -f "$TEMP_RESULT" "$TEMP_PID"
    else
      # 读取结果
      RAW_RESULT=$(cat "$TEMP_RESULT" 2>/dev/null)
      EXIT_CODE=$(cat "$TEMP_PID" 2>/dev/null || echo "0")
      
      # 清理临时文件
      rm -f "$TEMP_RESULT" "$TEMP_PID"
      
      # 检查返回码
      if [ "$EXIT_CODE" != "0" ]; then
        CLAUDE_ERROR=true
        echo "❌ Claude 调用失败（退出码: $EXIT_CODE）"
        if [ -n "$RAW_RESULT" ]; then
          echo "   错误信息: $(echo "$RAW_RESULT" | head -5 | tr '\n' ' ')"
        fi
      fi
      
      # 检查结果是否为空或包含错误信息
      if [ -z "$RAW_RESULT" ]; then
        CLAUDE_ERROR=true
        echo "⚠️  Claude 返回了空结果"
      elif echo "$RAW_RESULT" | grep -qE "(error|Error|ERROR|EPERM|operation not permitted|timeout|Timeout)" 2>/dev/null; then
        # 检查是否是真正的错误（排除正常的审核结果中可能包含这些词）
        if echo "$RAW_RESULT" | grep -qE "^\s*\{\"type\":\"result\".*\"is_error\":true" 2>/dev/null; then
          CLAUDE_ERROR=true
          echo "⚠️  Claude 返回了错误"
        fi
      fi
    fi
  fi
else
  CLAUDE_ERROR=true
  echo "❌ Claude 命令不可用"
  echo "   尝试的路径："
  echo "   - claude (PATH)"
  echo "   - $HOME/.local/bin/claude"
  echo "   - /usr/local/bin/claude"
  echo "   - /opt/homebrew/bin/claude"
  echo "   - $HOME/bin/claude"
  echo ""
  echo "   当前 PATH: $PATH"
fi

# macOS 弹窗函数 - 修复版本
show_macos_dialog() {
  local message="$1"
  local title="$2"
  local buttons="$3"
  local default_button="$4"

  # 修复：在AppleScript中直接构建消息，避免shell变量替换问题
  osascript <<EOF 2>/dev/null
    set theMessage to "$message"
    set theButtons to {$buttons}
    set theResult to display dialog theMessage buttons theButtons default button "$default_button" with title "$title" with icon caution
    return button returned of theResult
EOF
  return $?
}

# 如果 claude 不可用或出错，询问用户是否继续
if [ "$CLAUDE_ERROR" = true ] || [ "$CLAUDE_AVAILABLE" = false ]; then
  echo ""
  echo "⚠️  Claude 审核服务不可用或出错"
  echo ""
  
  # 使用弹窗询问用户
  USER_CHOICE=""
  if [ "$IS_MAC" = true ] && [ "$HAS_GUI_SESSION" = true ]; then
    # 修复：使用单行消息避免格式问题
    USER_CHOICE=$(show_macos_dialog \
    "Claude代码审核服务不可用或超时\n原因可能是：\n- Claude服务暂时不可用\n- 网络连接问题\n- 审核超时（超过${CLAUDE_TIMEOUT}秒）\n是否继续提交代码？" \
    "代码审核服务异常" \
    "\"取消提交\", \"继续提交\"" \
    "继续提交")
    DIALOG_EXIT_CODE=$?

    # 如果弹窗失败，降级到命令行交互
    if [ $DIALOG_EXIT_CODE -ne 0 ]; then
      echo "⚠️  无法显示弹窗（可能处于无 GUI 环境），使用命令行交互"
      USER_CHOICE=""
    else
      # 清理返回值（去除可能的空白字符）
      USER_CHOICE=$(echo "$USER_CHOICE" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    fi

    case "$USER_CHOICE" in
      "取消提交")
        echo "❌ 用户选择取消提交"
        exit 1
        ;;
      "继续提交")
        echo "✅ 用户选择继续提交（跳过审核）"
        echo ""
        cleanup_temp_files
        exit 0
        ;;
      *)
        # 弹窗失败或返回空值，使用命令行交互
        echo "================================================================="
        echo "Claude 代码审核服务不可用或超时"
        echo "================================================================="
        echo ""
        echo "原因可能是："
        echo "  - Claude 服务暂时不可用"
        echo "  - 网络连接问题"
        echo "  - 审核超时（超过 ${CLAUDE_TIMEOUT} 秒）"
        echo ""
        ask_user_continue_commit "是否继续提交代码？"
        ;;
    esac
  else
    # 非 macOS 系统，使用命令行交互
    echo "================================================================="
    echo "Claude 代码审核服务不可用或超时"
    echo "================================================================="
    echo ""
    echo "原因可能是："
    echo "  - Claude 服务暂时不可用"
    echo "  - 网络连接问题"
    echo "  - 审核超时（超过 ${CLAUDE_TIMEOUT} 秒）"
    echo ""
    ask_user_continue_commit "是否继续提交代码？"
  fi
fi

# 过滤掉 diff 命令的错误信息和 JSON，但保留有用的内容
CLEAN_RESULT=$(echo "$RAW_RESULT" || true) || true

# 将审核结果写入 last_review_info.txt
echo "=====================================================================" > "$REVIEW_FILE"
echo "                         代码审核报告" >> "$REVIEW_FILE"
echo "=====================================================================" >> "$REVIEW_FILE"
echo "" >> "$REVIEW_FILE"
echo "审核时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REVIEW_FILE"
echo "" >> "$REVIEW_FILE"
echo "==========" >> "$REVIEW_FILE"
echo "" >> "$REVIEW_FILE"

# 检查是否有审核结果
if [ -n "$CLEAN_RESULT" ]; then
  echo "$CLEAN_RESULT" >> "$REVIEW_FILE"
else
  echo "注意：Claude 审核服务暂时不可用，以下是本次提交的变更信息：" >> "$REVIEW_FILE"
  echo "" >> "$REVIEW_FILE"
  echo "## 变更文件" >> "$REVIEW_FILE"
  echo "" >> "$REVIEW_FILE"
  echo "$CHANGED_FILES" | while read file; do
    echo "- $file" >> "$REVIEW_FILE"
  done
  echo "" >> "$REVIEW_FILE"
  echo "## 潜在风险分析" >> "$REVIEW_FILE"
  echo "" >> "$REVIEW_FILE"
  echo "由于审核服务暂时不可用，请人工检查以下风险点：" >> "$REVIEW_FILE"
  echo "- 数组越界访问" >> "$REVIEW_FILE"
  echo "- 强制解包 nil 值" >> "$REVIEW_FILE"
  echo "- 内存泄漏" >> "$REVIEW_FILE"
  echo "- 主线程耗时操作" >> "$REVIEW_FILE"
fi

# 在报告末尾添加完整的 git diff（供查看详情时使用）
echo "" >> "$REVIEW_FILE"
echo "=================================================================" >> "$REVIEW_FILE"
echo "                        完整代码变更" >> "$REVIEW_FILE"
echo "=================================================================" >> "$REVIEW_FILE"
echo "" >> "$REVIEW_FILE"
cat "$DIFF_FILE" >> "$REVIEW_FILE"

echo "" >> "$REVIEW_FILE"
echo "=================================================================" >> "$REVIEW_FILE"

echo "✅ 审核完成，已生成报告文件: last_review_info.txt"
echo ""

# 修复：更智能的风险统计方法
# 首先提取所有风险描述块
RISK_BLOCKS=$(echo "$CLEAN_RESULT" | grep -n "风险描述" | cut -d: -f1)

# 初始化计数器
RISK_COUNT=0
HIGH_RISK_COUNT=0
MEDIUM_RISK_COUNT=0
LOW_RISK_COUNT=0

# 如果有风险描述，进行详细统计
if [ -n "$RISK_BLOCKS" ]; then
    # 计算风险总数
    RISK_COUNT=$(echo "$RISK_BLOCKS" | wc -l)
    
    # 统计每种风险类型
    HIGH_RISK_COUNT=$(echo "$CLEAN_RESULT" | grep -A5 "风险描述" | grep -c "严重程度.*高\|高风险")
    MEDIUM_RISK_COUNT=$(echo "$CLEAN_RESULT" | grep -A5 "风险描述" | grep -c "严重程度.*中\|中风险")
    LOW_RISK_COUNT=$(echo "$CLEAN_RESULT" | grep -A5 "风险描述" | grep -c "严重程度.*低\|低风险")
    
    # 如果还有其他风险（未明确分类的），都归为中风险
    UNCERTAIN_RISK_COUNT=$((RISK_COUNT - HIGH_RISK_COUNT - MEDIUM_RISK_COUNT - LOW_RISK_COUNT))
    if [ $UNCERTAIN_RISK_COUNT -gt 0 ]; then
        MEDIUM_RISK_COUNT=$((MEDIUM_RISK_COUNT + UNCERTAIN_RISK_COUNT))
    fi
else
    # 如果没有明确的风险描述，尝试其他统计方法
    RISK_COUNT=$(echo "$CLEAN_RESULT" | grep -c "风险描述\|风险提示\|发现.*风险\|潜在问题")
    
    # 如果没有找到任何风险，设置为0
    if [ -z "$RISK_COUNT" ] || [ "$RISK_COUNT" -eq 0 ]; then
        RISK_COUNT=0
        HIGH_RISK_COUNT=0
        MEDIUM_RISK_COUNT=0
        LOW_RISK_COUNT=0
    else
        # 如果有风险但没有明确分类，假设都是中风险
        MEDIUM_RISK_COUNT=$RISK_COUNT
    fi
fi

# 确保所有值都是数字
RISK_COUNT=$((RISK_COUNT))
HIGH_RISK_COUNT=$((HIGH_RISK_COUNT))
MEDIUM_RISK_COUNT=$((MEDIUM_RISK_COUNT))
LOW_RISK_COUNT=$((LOW_RISK_COUNT))

# 修复：文件数统计
FILE_COUNT=$(echo "$CHANGED_FILES" | wc -w)
FILE_COUNT=$((FILE_COUNT))

# 调试：显示统计值
echo "调试信息 - 风险统计:"
echo "  总风险数: $RISK_COUNT"
echo "  高风险数: $HIGH_RISK_COUNT"
echo "  中风险数: $MEDIUM_RISK_COUNT"
echo "  低风险数: $LOW_RISK_COUNT"
echo "  变更文件数: $FILE_COUNT"

# 初始化用户选择变量
CHOICE=""

# 修复：专门的审核结果弹窗函数
if [ "$IS_MAC" = true ] && [ "$HAS_GUI_SESSION" = true ]; then
  # 直接在AppleScript中构建完整消息
  CHOICE=$(osascript <<EOF 2>/dev/null
    set fileCount to "$FILE_COUNT"
    set riskCount to "$RISK_COUNT"
    set highRisk to "$HIGH_RISK_COUNT"
    set mediumRisk to "$MEDIUM_RISK_COUNT"
    set lowRisk to "$LOW_RISK_COUNT"
    
    -- 清理变量值（确保是纯数字）
    set fileCount to (do shell script "echo '" & fileCount & "' | tr -cd '0-9'")
    set riskCount to (do shell script "echo '" & riskCount & "' | tr -cd '0-9'")
    set highRisk to (do shell script "echo '" & highRisk & "' | tr -cd '0-9'")
    set mediumRisk to (do shell script "echo '" & mediumRisk & "' | tr -cd '0-9'")
    set lowRisk to (do shell script "echo '" & lowRisk & "' | tr -cd '0-9'")
    
    -- 如果为空则设为0
    if fileCount is "" then set fileCount to "0"
    if riskCount is "" then set riskCount to "0"
    if highRisk is "" then set highRisk to "0"
    if mediumRisk is "" then set mediumRisk to "0"
    if lowRisk is "" then set lowRisk to "0"
    
    -- 验证风险总数等于各类风险之和
    set totalRisks to (highRisk as integer) + (mediumRisk as integer) + (lowRisk as integer)
    if totalRisks ≠ (riskCount as integer) then
        -- 如果不匹配，调整风险总数
        set riskCount to (totalRisks as string)
    end if
    
    -- 构建消息
    set msgLines to {}
    set end of msgLines to "代码审核完成"
    set end of msgLines to "变更文件数: " & fileCount
    set end of msgLines to "发现风险数: " & riskCount
    
    if (highRisk as integer) > 0 then
        set end of msgLines to "  - 高风险: " & highRisk
    end if
    
    if (mediumRisk as integer) > 0 then
        set end of msgLines to "  - 中风险: " & mediumRisk
    end if
    
    if (lowRisk as integer) > 0 then
        set end of msgLines to "  - 低风险: " & lowRisk
    end if
    
    -- 如果没有找到风险类型，显示一个通用提示
    if (highRisk as integer) = 0 and (mediumRisk as integer) = 0 and (lowRisk as integer) = 0 and (riskCount as integer) > 0 then
        set end of msgLines to "  - 请查看详细报告了解风险分类"
    end if
    
    set end of msgLines to "审核报告已保存到: last_review_info.txt"
    
    -- 合并所有行
    set AppleScript's text item delimiters to return
    set theMessage to msgLines as text
    set AppleScript's text item delimiters to ""
    
    set theResult to display dialog theMessage ¬
        buttons {"查看详情", "取消提交", "继续提交"} ¬
        default button "查看详情" ¬
        with title "代码审核结果" ¬
        with icon caution
    return button returned of theResult
EOF
  )
  DIALOG_EXIT_CODE=$?

  # 如果 osascript 失败（无 GUI 环境），降级到命令行交互
  if [ $DIALOG_EXIT_CODE -ne 0 ] || [ -z "$CHOICE" ]; then
    echo "⚠️  无法显示弹窗（可能处于无 GUI 环境），使用命令行交互"
    CHOICE=""
  fi
fi

# 如果弹窗成功，处理用户选择
if [ -n "$CHOICE" ]; then
    case "$CHOICE" in
      "继续提交"|*"继续提交"*)
        echo ""
        echo "✅ 已批准提交"
        echo ""
        exit 0
        ;;
      "取消提交"|*"取消提交"*)
        echo ""
        echo "❌ 已阻断提交"
        echo ""
        echo "请修复问题后重新提交"
        exit 1
        ;;
      "查看详情")
        # 打开审核报告文件（macOS）
        if [ "$IS_MAC" = true ]; then
          open "$REVIEW_FILE"
        else
          # Linux 使用 xdg-open
          xdg-open "$REVIEW_FILE" 2>/dev/null || echo "请手动打开文件: $REVIEW_FILE"
        fi
        echo ""
        echo "已打开审核报告，请查看后决定是否提交"
        
        # 等待一小段时间，确保文件已打开
        sleep 1
        
        # 重新显示弹窗，让用户选择是否提交
        if [ "$IS_MAC" = true ] && [ "$HAS_GUI_SESSION" = true ]; then
          FINAL_CHOICE=$(show_macos_dialog \
          "审核报告已打开\n请查看 last_review_info.txt 文件后，决定是否继续提交代码" \
          "代码审核 - 确认提交" \
          "\"取消提交\", \"继续提交\"" \
          "继续提交")
        else
          FINAL_CHOICE=""
        fi
        
        # 处理最终选择
        case "$FINAL_CHOICE" in
          "继续提交"|*"继续提交"*)
            echo ""
            echo "✅ 已批准提交"
            echo ""
            exit 0
            ;;
          "取消提交"|*"取消提交"*)
            echo ""
            echo "❌ 已阻断提交"
            echo ""
            echo "请修复问题后重新提交"
            exit 1
            ;;
          *)
            # 如果弹窗失败，降级到命令行交互
            echo ""
            echo "⚠️  弹窗显示失败，使用命令行交互"
            echo ""
            ask_user_continue_commit "请查看审核报告 last_review_info.txt，然后决定是否继续提交："
            ;;
        esac
        ;;
      *)
        echo ""
        echo "❌ 已取消操作"
        exit 1
        ;;
    esac
fi

# 如果弹窗失败或未选择，使用命令行交互
if [ -z "$CHOICE" ]; then
  # 检查标准输入是否可用（是否是交互式终端）
  if [ ! -t 0 ]; then
    echo ""
    echo "⚠️  标准输入不可用，无法使用命令行交互"
    echo ""
    echo "请手动检查审核报告: $REVIEW_FILE"
    echo ""
    
    # 如果设置了允许非交互式提交的环境变量，则允许提交
    if [ "$ALLOW_NONINTERACTIVE_COMMIT" = "1" ]; then
      echo "✅ 检测到 ALLOW_NONINTERACTIVE_COMMIT=1，允许非交互式提交"
      cleanup_temp_files
      exit 0
    else
      echo "如需继续提交，请使用以下命令之一："
      echo "  1) ALLOW_NONINTERACTIVE_COMMIT=1 git commit -m \"your message\""
      echo "  2) git -c core.hooksPath=/dev/null commit -m \"your message\"  (临时禁用 hook)"
      echo ""
      echo "❌ 阻断提交（标准输入不可用）"
      exit 1
    fi
  fi

  ask_user_continue_commit "请查看审核报告 last_review_info.txt，然后决定是否继续提交："
fi

# 清理临时文件
cleanup_temp_files
