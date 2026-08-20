# callgraph.nvim

> [English](README.md) · **中文**

一个在 Neovim 里显示**真正的函数调用图**（有向图，类似流程图）的插件，不是缩进树。

调用者永远在**左边**，被调用者在**右边**；边用正交折线 + 箭头画出。数据来自 LSP 的
[Call Hierarchy](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_prepareCallHierarchy)。
这是一个语言无关、跨文件的来源——任何实现了 call hierarchy 的语言服务器（clangd、gopls、rust-analyzer 等）都可以驱动。

## 命令

| 命令 | 作用 |
|---|---|
| `:Callout` | 以光标处函数为根，展示它**调用了谁** |
| `:Callin` | 以光标处函数为根，展示**谁调用了它** |
| `:CallgraphLog` | 打开调试日志文件 |
| `:CallgraphDebug on\|off` | 运行时开关调试日志 |

## 视图

- 默认在编辑器**底部**分割（`window.position` 可配 `right` / `bottom`），只读画布 buffer。
- 窗口尺寸固定（right 布局用 `fixed_width` 列宽、bottom 布局用 `fixed_height` 行高；设为 0 则按内容自适应）。
- 窗口顶部有 **winbar 标签栏**：每个 tab 是一个「函数 + 方向」，`<Tab>` / `<S-Tab>` 循环切换；同函数同方向重复打开会跳转到已有 tab，不重复创建。
- 选中框的**函数名标色**（默认绿，`highlights.focus`），位置标注 `文件:行号` **变灰**（`highlights.loc`）；`highlights.focus_bold` 可给选中函数名加粗。
- `<Enter>` 跳转到定义并**保持视图打开**；`q` / `<Esc>` 关闭（关闭后焦点自动还回原窗口）。

### 视图内按键

| 键 | 动作 |
|---|---|
| `h` `j` `k` `l` / 方向键 | 移动选中框（空间最近邻） |
| `<Space>` | 展开 / 折叠当前框（切换显示直接子节点） |
| `<Enter>` / `d` | 跳转到函数定义（视图保持打开） |
| `<Tab>` `<S-Tab>` | 多标签页切换 |
| `q` `<Esc>` | 关闭当前 tab（最后一个 tab 关闭时关闭视图） |
| `r` | 刷新 |
| `i` / `o` | 原地切换 callin / callout |
| `+` / `-` | 全局深度 +1 / -1 |
| `?` | 按键速查 |

鼠标：单击选中框，**双击**展开/折叠，滚轮滚动画布。

## 特性

- **树形展开**：每个调用路径展开成自己的节点——同一函数被不同地方调用时按路径各出现一次（不去重），边不交叉、谁调谁一目了然。
- **层级限制**：`max_depth` 默认 4（从根出发最多 4 条边）。边界节点折叠显示 `▸`，Enter/双击展开，`+`/`-` 调整深度。
- **循环**：检测到回边时不再展开，函数名右侧显示带高亮的 **⟳** 终止节点，不画回边。
- **连线不交叉**：行按子树连续分配，父→子边不会压过其他边。
- **调用点标注**：框内显示调用点 `文件:行号`（`show_call_site` 可关）。
- **长名截断**：超宽函数名截断为 `…`，光标悬停时在消息区显示完整路径。
- **自动滚动**：移动选中框时，若函数框超出窗口可视范围，画布自动横向/纵向滚动让它保持可见。
- **多标签页**：一个视图内可同时打开多个「函数 + 方向」的图，winbar 显示标签，`<Tab>` 切换。
- **多来源**：调用关系可来自 `lsp` / `cscope` / `ctags` / `auto` 多种方式，按 `sources` 配置的优先级取第一个有结果者；启动时后台探测各来源是否可用（如 cscope 二进制/索引不存在则自动跳过），结果缓存避免每次查询重新探测。
- **Lazy.nvim 友好**：`documentSymbol` 在 `LspAttach` 后后台异步缓存，打开文件零阻塞。

## 数据来源

`config.sources` 按优先级列出可用来源（`sources = { 'lsp', 'auto' }`）：

- **`lsp`（默认首选）**：LSP Call Hierarchy——语言无关、跨文件。`incomingCalls`（callin）clangd ≥ LLVM 12；`outgoingCalls`（callout）需要 clangd **≥ LLVM 20**（2024-12 才落地）。
- **`cscope`**：cscope 数据库查询（需要 `cscope` 二进制 + `cscope.out`，适合 C/C++）。
- **`ctags`**：ctags（预留，尚未实现）。
- **`auto`（兜底）**：启发式单文件——callout 扫描函数体里的调用点逐个 `prepareCallHierarchy` 解析，解析不到时**按函数名在当前文件 documentSymbol 里匹配**（能处理先调用后声明的源码）；callin 用 `references` + documentSymbol 定位调用者。**只能单文件内兜底**，跨文件调用解析不了。

> 建议：使用 clangd ≥ 20，这样 callin / callout 都走标准语义分析（跨文件、精确）。
> clangd < 20 时 callout 会从 lsp 自动降到下一个来源（如 `auto`）。

## 要求

- Neovim **≥ 0.10**
- 语言服务器。C 请用 **clangd**（≥ 20 以获得完整的 callout/callin 支持）
- 跨文件/大项目请确认有 `compile_commands.json` 且后台索引就绪

## 安装

```lua
-- lazy.nvim
{
  'mengq627/callgraph.nvim',
  cmd = { 'Callout', 'Callin' },
  keys = {
    { '<leader>co', '<cmd>Callout<CR>', desc = 'Call graph: callees' },
    { '<leader>ci', '<cmd>Callin<CR>',  desc = 'Call graph: callers' },
  },
  opts = {}, -- 可选，见下
}
```

## 配置

```lua
require('callgraph').setup({
  max_depth = 4,          -- 默认最多展开的边数
  show_call_site = true,  -- 框内显示 文件:行号
  sources = { 'lsp', 'auto' }, -- 调用关系来源，按优先级取第一个有结果者：
                              -- lsp / cscope / ctags（预留）/ auto（单文件启发式）；
                              -- 启动时自动探测哪些可用（如未装 cscope 则跳过）
  highlight = true,       -- 高亮开关（默认开）。选中函数名标色、位置标注变灰
  window = {
    position = 'bottom',     -- 'right'（右侧竖分） | 'bottom'（底部横分）
    fixed_width = 80,        -- right 布局的固定列宽（0 = 按内容自适应）
    fixed_height = 20,       -- bottom 布局的固定行高
    row_gap = 2,             -- 列内框的垂直间距
    col_gap = 5,             -- 列间距
    max_name_width = 26,     -- 函数名截断长度
    max_loc_width = 22,      -- 位置标注截断长度
    arrows = { right='', down='', up='', left='' }, -- Nerd Font 箭头
    collapse_marker = '❯',  -- 可展开标记：'❯' 粗 | '▶' 大 | '▸' 小 | '▷' 空心
  },
  highlights = {
    focus = 'CallgraphFocus',       -- 选中函数名颜色（默认绿）
    focus_bold = false,             -- 选中函数名加粗
    loc = 'CallgraphLoc',           -- 位置标注颜色（默认灰）
    tab_active = 'CallgraphTabActive',     -- 当前 tab 标签
    tab_inactive = 'CallgraphTabInactive', -- 其他 tab 标签
  },
  colors = {
    -- 画布颜色：'off'（默认终端色）| 'auto'（镜像代码区：函数名 <- @function、
    -- 文件:行号 <- Comment、背景 <- Normal；连线白色、边框蓝紫）
    -- | 'custom'（用下面的颜色）
    mode = 'auto',
    func = '#98c379',    -- 函数名（custom）
    location = '#5c6370', -- 文件:行号（custom）
    border = '#9d7cd8',  -- 函数边框（custom）
    edge = '#ffffff',    -- 连线（custom）
    focus = '#98c379',   -- 选中函数名（custom）
    symbol = '#e5c07b',  -- 内联符号 ⟳ 循环 / ▸ 可折叠（custom）
  },
  keymaps = {               -- 全部可重映射；设为 '' 禁用
    move_left = 'h', move_down = 'j', move_up = 'k', move_right = 'l',
    move_left_alt = '<Left>', move_down_alt = '<Down>',
    move_up_alt = '<Up>', move_right_alt = '<Right>',
    toggle_expand = '<Space>',
    close = 'q', close_alt = '<Esc>',
    refresh = 'r',
    to_callin = 'i', to_callout = 'o',
    depth_up = '+', depth_down = '-',
    jump_to_def = '<CR>', jump_to_def_alt = 'd',
    tab_next = '<Tab>', tab_prev = '<S-Tab>',
    help = '?',
  },
})
```

### 颜色模式

`colors.mode` 控制画布配色：

| `off`（默认终端色） | `auto`（镜像代码区） |
|---|---|
| ![off](assets/off_colors.png) | ![auto](assets/auto_colors.png) |

- **off**：纯终端色——边框、文本、连线都用默认调色板。
- **auto**：镜像代码区——函数名跟随 `@function`、文件:行号跟随 `Comment`、
  内联符号（⟳ / ❯）跟随 `@keyword`、背景跟随 `Normal`、边框蓝紫、连线白。
- **custom**：使用上面 `colors.*` 的显式颜色。

## 架构

```
plugin/callgraph.lua  懒加载入口：注册 :Callout / :Callin / :CallgraphLog / :CallgraphDebug
lua/callgraph/
  init.lua      setup()、公共 API、LspAttach 后台缓存
  config.lua    默认配置 + 合并 + 高亮组定义
  source.lua    来源管理器：可用性探测缓存、按 sources 优先级组合 fetch、根函数解析
  source/       symbol 来源（每个一种调用关系查询方式）：
    lsp.lua       LSP call hierarchy（outgoing/incomingCalls）
    auto.lua      启发式单文件（复用 scanner + fallback）
    cscope.lua    cscope 数据库查询（-dL -2/-3）
    ctags.lua     ctags（预留）
  lsp.lua       LSP 工具：根函数解析（prepareCallHierarchy + documentSymbol）、跳定义
  graph.lua     建图：递归取数（树形、不去重）、循环检测、深度裁剪（纯逻辑，注入 fetch）
  scanner.lua   纯 C 调用点扫描器（跳过注释/字符串/预处理，返回调用 token）
  fallback.lua  启发式取数：callout 扫描函数体+解析调用点（含按名兜底），callin 用 references
  layout.lua    分层布局 + 正交边路由（纯函数）
  render.lua    把图画进画布 buffer + 高亮 extmark
  view.lua      分割视图、多标签（winbar）、keymap、鼠标、悬停 echo
```

核心（graph / scanner / layout / render）是纯逻辑，可无 LSP 测试。

## 开发 / 测试

测试都在 `tests/` 下，从仓库根目录运行：

```bash
nvim --headless -u NONE -l tests/load_check.lua        # 所有模块加载
nvim --headless -u NONE -l tests/smoke.lua             # 无服务器：建图/布局/渲染/扫描器/fallback
nvim --headless -u NONE -l tests/repro_move.lua        # 移动选中框的光标定位回归
nvim --headless -u NONE -l tests/tabs.lua              # 多标签：复用/切换/关闭 + winbar
nvim --headless -u NONE -l tests/scroll.lua            # 横向滚动让选中框可见
nvim --headless -u NONE -l tests/ui.lua                # 无服务器：分割视图/导航/展开/关闭
nvim --headless -u NONE -l tests/integration.lua       # 真 clangd：clean.c 的 callout(fallback)+callin
nvim --headless -u NONE -l tests/integration_testc.lua # 真 clangd：test.c 先调用后声明的 name-match 兜底
nvim --headless -u NONE -l tests/integration_lsp.lua   # clangd ≥ 20：纯 LSP callout 4 层 + callin
nvim --headless -u NONE -l tests/cscope.lua            # cscope provider：输出解析 / 索引发现 / 可用性探测
nvim --headless -u NONE -l tests/integration_complex.lua # test_complex.c：菱形 / 循环 / fan-out / 深链
```

`tests/smoke.lua` 覆盖：树形展开（同一符号按路径各出现一次）、循环终止节点、callin 镜像、
`max_depth` 边界折叠、展开/折叠切换、C 调用点扫描器、fallback 编排、同列边箭头。
`tests/clean.c` 是格式良好的样例；`tests/test.c` 是"先调用后声明"的菱形结构样例。

### 覆盖率（luacov）

每个测试都跑在 vendored 的 [luacov](https://lunarmodules.github.io/luacov/) 下（`tests/vendor/luacov/`，纯 Lua 无外部依赖）。

```bash
# 跑全部测试 + 输出覆盖率汇总
nvim --headless -u NONE -l tests/run_coverage.lua

# 额外检查"新提交代码 100% 覆盖"（新增的可执行行必须被测试执行）
nvim --headless -u NONE -l tests/run_coverage.lua --diff origin/main
```

规则：

- **测试是硬性门禁**：每次 push / PR 全量测试必须通过，否则阻断。
- **覆盖率是非阻塞门禁**：push / PR 都显示新代码覆盖结果（`--diff <base>` 时，`git diff base` 新增的**可执行行**是否被测试执行，未覆盖会列出 `UNCOVERED NEW LINE`；新增行在**未被任何测试加载**的 `lua/callgraph` 文件里同样被标记）。它**不阻断合并**——committer 可以强制合入。
- **豁免异常分支**：用 `-- luacov: disable` / `-- luacov: enable` 注释包裹确定不需要覆盖的分支（如防御性/异常处理），这些行不计入 miss、也不被新代码检查要求。
- GitHub Actions（`.github/workflows/ci.yml`）：单个 job——测试 + 覆盖率汇总是硬性门禁；新代码覆盖检查复用同一次运行的报告（`--no-run`、`continue-on-error`），push / PR 都执行并展示结果但不阻止合入。覆盖率报告（`luacov.report.out`）作为构建产物上传。
