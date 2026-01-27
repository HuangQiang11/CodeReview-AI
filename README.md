## Claude Code + Git Hook 本地代码审核方案 ##

本方案通过 Git Hook + Claude Code 在开发者本地提交阶段进行自动代码审核，提前拦截高风险代码，并可无缝扩展至 CI / PR 阶段，形成完整的代码质量防线。


#### 一、方案目标
    •    在 commit 阶段 自动进行代码审核，尽早发现问题
    •    阻断存在严重风险的提交（Crash / 内存 / 主线程 / SwiftUI 状态问题等）
    •    审核逻辑本地化，不依赖远端 CI 即可生效
    •    可平滑升级为 PR / CI 自动 Review + Merge Gate


#### 二、整体流程

本地阶段（已实现）
```
开发者本地 git commit
        ↓
Git pre-commit Hook
        ↓
Claude Code 审核 staged diff
        ↓
ALLOW → 允许提交
BLOCK → 阻断提交
```


远端阶段（可扩展）
```
git push
   ↓
创建 Pull Request
   ↓
CI（GitHub Actions / GitLab CI）
   ↓
Claude Code 自动 Review
   ↓
评论到 PR
   ↓
是否允许 merge

```


#### 三、使用前准备

- Step 1：准备 Claude Code 环境

请确保本地已正确安装并可直接在终端中使用 claude 命令。

示例：
```
claude --version
```


#### 四、本地代码审核接入

- Step 2：准备审核脚本
    1.    将 CodeReview 目录拷贝到 项目根目录
    2.    赋予脚本执行权限：
```
chmod +x CodeReview/claude_precommit.sh
```

- Step 3：配置 Git pre-commit Hook

1️⃣ 创建或编辑 pre-commit 文件
路径：

.git/hooks/pre-commit

若文件不存在，可手动创建：
```
touch .git/hooks/pre-commit
```

2️⃣ 写入 Hook 内容
```
echo "pre-commit hook is running"

# 获取项目根目录
PROJECT_ROOT="$(git rev-parse --show-toplevel)"

# 使用绝对路径调用审核脚本
"$PROJECT_ROOT/CodeReview/claude_precommit.sh"
```

3️⃣ 赋予执行权限
```
chmod +x .git/hooks/pre-commit
```
至此，本地 commit 自动审核已生效 🎉



#### 五、如何使用

当在终端 git commit 
或者在sourceTree中点击commit时
会自动提交审核，并将审核结果通过弹窗的形式展示出来。提交者根据信息可以选择提交或者不不提交


#### 六、进阶扩展（推荐）

在当前方案基础上，可进一步扩展为 端到端代码审核链路：
    •    CI 中自动执行 Claude Code Review
    •    Review 结果自动评论到 PR
    •    结合 Branch Protection 规则控制 merge
    •    与人工 Review 形成互补

#### 七、最佳实践建议
    •    本地 Hook 只做 高风险拦截，避免过度严格
    •    CI / PR 阶段可执行 更完整、更耗时的审核
    •    审核 Prompt 建议版本化维护，便于团队统一标准
