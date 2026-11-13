# 仓库 UX 变更与截图

本次将仓库功能统一到 Code / Issues / Pull requests / Actions / Settings，
让跨功能切换保留仓库上下文，各功能自己的筛选和操作由侧栏及页面内容承载。
保留 MoonHub 品牌、英文界面和浅色主题。

截图来自本地一次性测试数据库与仓库，包含演示账号 Alice，没有生产数据。
本目录保存 30 张原始浏览器截图：六组 1440px 修改前后对照，以及有内容的详情、
菜单和 390px 移动端页面。补充桌面截图为 1440px，Secrets 为既有 smoke 的 1280px。
对照截图使用相同测试仓库内容；补充截图使用独立演示数据。
自动化另覆盖 320、390、900、1440px。

## 公共导航与代码浏览

原来 Files、Commits、Issues、Merge requests、Pipelines、Releases 和各种设置
混在同一个长侧栏中。现在顶部保留五个仓库标签，侧栏随当前功能切换。
账号、团队及站点入口进入独立全局抽屉，Settings 仅对管理员显示，默认打开分支保护。

Code 页面把分支/标签、文件定位、History 和绿色 Code 菜单放到文件列表附近，
并展示提交摘要和安全渲染的 README。文件页增加目录导航、行号锚点、复制路径/
原文，以及 Markdown Preview/Code 切换。创建和导入表单明确展示 Owner、仓库名
和可见性，保留既有任务进度、失败后重试和输入恢复。

文件定位通过授权后的 Git 只读查询生成，最多 5,000 个路径、2 MiB 输出；
触及上限或不能解码时说明限制并提供目录浏览。README 预览最多 256 KiB。
同名分支/标签、含 `/` 的分支和历史版本继续通过原有修订解析能力处理。

<details>
<summary>Code：修改前后与移动端</summary>

修改前：

![Code 修改前](images/repository-ux/before-code.png)

修改后：

![Code 修改后](images/repository-ux/code-desktop.png)

390px：

<img src="images/repository-ux/code-mobile.png" alt="390px Code 页面" width="390">

</details>

<details>
<summary>文件定位与全局抽屉</summary>

![文件定位](images/repository-ux/file-finder-desktop.png)

![全局抽屉](images/repository-ux/global-drawer-desktop.png)

</details>

## Issues

列表采用标题搜索、Open/Closed 切换和紧凑记录行；侧栏直接进入 All issues 或
Assigned to me。筛选和分页仍使用既有 URL，前进后退可以恢复筛选上下文。

详情把正文、活动、评论编辑器放在主列，Assignee、关联 PR、订阅和 Copy reference
放在右栏。移动端顺序堆叠。Close/Reopen 与 Add comment 保持独立，复制引用为 `#123`。

<details>
<summary>Issues：修改前后、列表与讨论详情</summary>

![Issues 修改前](images/repository-ux/before-issues.png)

![Issues 修改后](images/repository-ux/issues-overview-desktop.png)

![有内容的 Issue 列表](images/repository-ux/issue-list-desktop.png)

![Issue 讨论详情](images/repository-ux/issue-detail-desktop.png)

<img src="images/repository-ux/issue-detail-mobile.png" alt="390px Issue 讨论详情" width="390">

</details>

## Pull requests

用户可见术语改为 Pull requests，服务路径仍为 `/merge-requests`，引用仍为 `!123`。
创建页按 base ← compare 排列，明确目标分支与来源分支，提供普通/草稿选择。

详情分为 Conversation / Commits / Files changed。评审人位于右栏，检查结果和
合并入口位于 Conversation 主内容下方，便于看完讨论后判断是否可以合并。
Files changed 在差异前提供 Review changes，保留文件导航、折叠和 Unified/Split。
MoonDiff 继续使用现有 Token/AST 和过滤默认值，同时显式显示模式/过滤状态并提供 Line。
行内评论仍立即发布；整体验证和评审仍按原有版本规则生效。

<details>
<summary>Pull requests：修改前后与创建页</summary>

![Pull requests 修改前](images/repository-ux/before-pull-requests.png)

![Pull requests 修改后](images/repository-ux/pull-requests-overview-desktop.png)

![base compare 与草稿创建](images/repository-ux/pull-request-create-desktop.png)

</details>

<details>
<summary>Conversation 与 Files changed（桌面/移动端）</summary>

![Conversation 与合并状态](images/repository-ux/pull-request-conversation-desktop.png)

![Files changed 与 Review changes](images/repository-ux/pull-request-files-desktop.png)

<img src="images/repository-ux/pull-request-files-mobile.png" alt="390px Files changed" width="390">

</details>

## Actions

原 Pipelines 的 UI 名称统一为 Actions，路径继续使用 `/pipelines`。
侧栏提供当前结果中的工作流和 Trigger events；状态、分支、工作流筛选沿用现有能力。
运行详情继续按作业、步骤、日志组织。手动执行集中在 Run workflow 页面，
区分重新执行已有快照与读取分支最新版本，避免误判执行的代码版本。

<details>
<summary>Actions：修改前后、工作流、手动执行与日志</summary>

![Actions 修改前](images/repository-ux/before-actions.png)

![Actions 修改后](images/repository-ux/actions-overview-desktop.png)

![工作流列表](images/repository-ux/actions-workflows-desktop.png)

![Run workflow](images/repository-ux/actions-run-workflow-desktop.png)

![作业步骤和日志](images/repository-ux/actions-log-desktop.png)

</details>

## Releases

入口归入 Code，侧栏保留 Releases。列表使用发布卡片，集中展示版本、提交、时间、
状态和安全 Markdown 说明；详情把下载整理为原生可折叠 Assets。
截图中 v1.4.0 已通过现有草稿 → CLI/API 上传 → 发布流程生成，包含真实的
79-byte CHANGELOG.txt 附件。浏览器不增加访问令牌输入，也不改变发布及附件不可替换约束。

<details>
<summary>Releases：修改前后、发布卡片与附件</summary>

![Releases 修改前](images/repository-ux/before-releases.png)

![Releases 修改后](images/repository-ux/releases-overview-desktop.png)

![发布卡片](images/repository-ux/release-list-desktop.png)

![发布详情和真实附件](images/repository-ux/release-detail-desktop.png)

</details>

## Settings

将分支保护、Actions 配置、Secrets/Variables、Webhooks、Deploy keys 和 Mirrors
集中到 Settings 分类侧栏；Secrets/Variables 使用相邻标签页。
普通成员仍可以在 Actions 查看只读 Variables。现有表单、错误、版本冲突反馈和权限
保持不变，删除分支保护前展开原生确认区域，减少误操作。

<details>
<summary>Settings：修改前后、Secrets/Variables 与删除确认</summary>

![Settings 修改前](images/repository-ux/before-settings.png)

![Settings 修改后](images/repository-ux/settings-overview-desktop.png)

![Secrets](images/repository-ux/settings-secrets-desktop.png)

![Variables](images/repository-ux/settings-variables-desktop.png)

![分支保护删除确认](images/repository-ux/settings-branch-confirmation-desktop.png)

</details>

## 键盘、回退与边界

- `/` 聚焦当前页面可见搜索，代码页 `t` 打开文件定位，Esc 关闭菜单并恢复焦点。
  输入框、编辑器和可编辑正文内不触发这些导航快捷键。
- 菜单与下载列表使用原生 details，链接/表单保留无 JavaScript 回退。
  页面切换继续清理监听、编辑器、轮询及未完成请求。
- 保留草稿恢复、上传期间的导航/重复提交保护、上传失败保留输入及重试。
- 搜索仅映射已有能力。PR Open/Merged/Closed 分开筛选，没有真实总数时省略计数。
- 保留 `!123` / `#123`、MoonDiff 默认值、即时行内评论和原有合并权限。
  不添加 Labels、Milestones、Projects、Star/Fork、在线编辑、Blame、ZIP、HTTPS clone
  或由浏览器重新编码的 raw 下载入口。
- Rabbita SSR/SPA、React 代码视图与 EasyMDE 保留。改动限定在 Web 展示、只读 Git
  数据组合、浏览器资源、测试和文档；业务包、数据库、API、权限及后台任务未修改。
- 生成接口变化仅限 `web/ui` 的可选侧栏内容、可选代码工具栏内容和共享
  Secrets/Variables 标签渲染函数，业务包接口不变。

## 验证结果与限制

| 检查 | 结果 |
| --- | --- |
| 浏览器资源构建、TypeScript | 通过 |
| 每次提交前 check → fmt → info 及 pre-commit | 通过 |
| 原生构建 `--strip -j 1` | 通过 |
| MoonBit 全量 | 813/813 |
| Playwright 全量 | 90/90 |
| 最终 UX/上传/折叠侧栏回归 | 10/10 |
| 分支/标签/文件定位上限 | 通过，超过 5,000 分支和 5,002 路径 |
| 包边界 | 50 个包通过 |
| 既有 collaboration UI / Secrets / UI browser smoke | 通过；UI smoke 37 张截图 |
| 加载/回退 smoke | 20 次延迟脚本导航，以及无脚本/脚本失败回退通过 |

验收 Git 为 2.43.7，支持 `merge-tree --write-tree`；系统 Git 2.34.1 不满足此要求。
构建和测试日志保留在本地 `_build/repository-ux/`，复现命令见
[覆盖清单](repository-ux.md#verification-and-screenshots)。

两项 smoke 没有记为通过：

1. 实时日志 smoke 的最后 flushed-tail 断言在本分支与 pristine master 上同样失败。
   此前的日志更新、作业/步骤导航、搜索、换行、follow、隐藏标签页检查已完成。
   本次未改动轮询或 Pipeline 业务代码。
2. runner merge-check smoke 因本机缺少固定 Node/action-runtime 路径返回 127；
   在私有命名空间补齐路径后执行原生服务又返回 EACCES，未能完成。
   未修改主机运行时目录或 runner 策略。MoonBit 合并/评审/检查 HTTP 回归通过。
