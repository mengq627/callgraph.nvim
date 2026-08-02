# callgraph.nvim

一个在 Neovim 里显示**真正的函数调用图**（有向图，类似流程图）的插件，不是缩进树。

调用者永远在**左边**，被调用者在**右边**；边用正交折线 + 箭头画出。数据来自 LSP 的
[Call Hierarchy](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_prepareCallHierarchy)。

## 命令

| 命令 | 作用 |
|---|---|
| `:Callout` | 以光标处函数为根，展示它**调用了谁**（向右展开） |
| `:Callin` | 以光标处函数为根，展示**谁调用了它**（向左展开） |

视图是**只读画布**，非编辑 buffer，焦点会自动还回原窗口。

### 视图内按键

| 键 | 动作 |
|---|---|
| `h` `j` `k` `l` / 方向键 | 移动选中框（空间最近邻） |
| `<Enter>` | 展开 / 折叠当前框（切换显示直接子节点） |
| `q` `<Esc>` | 关闭 |
| `r` | 刷新 |
| `i` / `o` | 原地切换 callin / callout |
| `+` / `-` | 全局深度 +1 / -1 |
| `d` | 跳到当前框函数定义 |
| `?` | 按键速查 |

鼠标：单击选中框，**双击**展开/折叠，滚轮滚动画布。

## 特性

- **真 DAG**：同一个函数全图只有一个框（按 `uri + 名字 + 定义位置` 去重），菱形结构共享节点。
- **层级限制**：`max_depth` 默认 4（从根出发最多 4 条边）。边界节点折叠显示 `▸`，Enter/双击展开，`+`/`-` 调整深度。
- **循环**：检测到回边时不再展开，函数名右侧显示带高亮的 **⟳** 终止节点，不画回边。
- **去重 + 最小深度**：节点放在从根最短路径的那一层。
- **调用点标注**：框内显示调用点 `文件:行号`（`show_call_site` 可关）。
- **长名截断**：超宽函数名截断为 `…`，光标悬停时在消息区显示完整路径。
- **Lazy.nvim 友好**：`documentSymbol` 在 `LspAttach` 后后台异步缓存，打开文件零阻塞。

## 要求

- Neovim **≥ 0.10**
- 语言服务器支持 Call Hierarchy。C 请用 **clangd**：
  - `callin`（incomingCalls）：clangd ≥ LLVM 12。
  - `callout`（outgoingCalls）：clangd **≥ LLVM 20**（outgoingCalls 于 2024-12 才落地）。
  - ⚠️ clangd 17 在部分环境下 call hierarchy / references **返回空结果**（索引相关已知问题，
    见 [clangd#2554](https://github.com/clangd/clangd/discussions/2554)、[clangd#1358](https://github.com/clangd/clangd/issues/1358)）。
    遇到"服务器返回 0 个调用"时请升级 clangd 或确认项目有 `compile_commands.json` 且后台索引已就绪。

## 安装

```lua
-- lazy.nvim
{
  '你的用户/callgraph.nvim',
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
  window = {
    max_width_ratio = 0.8,   -- 浮窗最大宽度（占编辑器）
    max_height_ratio = 0.8,
    border = 'rounded',
    row_gap = 2,             -- 列内框的垂直间距
    col_gap = 5,             -- 列间距
    max_name_width = 26,     -- 函数名截断长度
    max_loc_width = 22,      -- 位置标注截断长度
  },
  highlights = {            -- 各元素的高亮组
    canvas = 'CallgraphCanvas',   -- 画布背景（默认链接 NormalFloat）
    box = 'CallgraphBox',
    focus = 'CallgraphFocus',     -- 选中框
    cycle = 'CallgraphCycle',     -- ⟳
    edge = 'CallgraphEdge',
    collapsed = 'CallgraphCollapsed', -- ▸
  },
  keymaps = {               -- 全部可重映射；设为 '' 禁用
    move_left = 'h', move_down = 'j', move_up = 'k', move_right = 'l',
    toggle_expand = '<CR>',
    close = 'q', close_alt = '<Esc>',
    refresh = 'r',
    to_callin = 'i', to_callout = 'o',
    depth_up = '+', depth_down = '-',
    jump_to_def = 'd', help = '?',
  },
})
```

## 架构

```
plugin/callgraph.lua  懒加载入口：只注册 :Callout/:Callin
lua/callgraph/
  init.lua      setup()、公共 API、LspAttach 后台缓存
  config.lua    默认配置 + 合并 + 高亮组定义
  lsp.lua       LSP 适配层：根函数解析、callHierarchy 请求、跳定义
  graph.lua     建图：递归取数、去重、循环检测、深度裁剪（纯逻辑，注入 fetch）
  layout.lua    分层布局 + 正交边路由（纯函数）
  render.lua    把图画进画布 buffer + 高亮 extmark
  view.lua      浮窗生命周期、keymap、鼠标、悬停 echo
```

核心（graph / layout / render）是纯逻辑，可无 LSP 测试。

## 开发 / 测试

测试都在 `tests/` 下，从仓库根目录运行：

```bash
# 无服务器冒烟测试（假 call-hierarchy 数据，验证建图/布局/渲染）
nvim --headless -u NONE -l tests/smoke.lua

# 真实 clangd 集成探测（需要 clangd 和 tests/test.c）
nvim --headless -u NONE -l tests/integration.lua
```

`tests/smoke.lua` 覆盖：去重/最小深度/菱形共享、循环终止节点、callin 镜像、
`max_depth` 边界折叠、展开/折叠切换。`tests/test.c` 是一个含菱形调用结构的 C 样例。
