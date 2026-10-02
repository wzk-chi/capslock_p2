# Qbar 全插件化重构设计

日期：2026-10-02

状态：设计文档，已完成协议和数据生命周期修订，尚未实施。

## 1. 设计结论

Qbar 后续不再把内置命令、QSearch、QRun、路径打开、开始菜单和工具面板分别处理。
它们统一成为可注册的插件命令，由同一个注册表负责：

- 插件发现与注册；
- 命令别名；
- 参数解析；
- 下拉列表展示；
- 冲突候选；
- 执行；
- 历史与使用频率；
- 插件设置；
- 启用和停用。

存储边界采用以下规则：

| 内容 | 唯一来源 |
| --- | --- |
| 插件定义、插件代码、handler、默认 manifest | AHK 代码或插件目录中的 manifest |
| 插件实例、命令、别名 | qbar.db |
| 插件私有设置 | qbar.db 中的 JSON 设置 |
| 历史、使用频率 | qbar.db |
| 全局程序设置、翻译和 AI 的非 Qbar 设置 | 现有配置系统 |

Qbar 命令不再使用 INI 作为配置来源。新架构不实现旧 QSearch/QRun 配置的兼容读取、
导入或历史迁移。首次启用新架构时直接创建新的 qbar.db。

QWeb 如果继续服务于 CapsLock+Tab 的网址展开，属于独立的热字符串来源，不注册为
Qbar 命令插件。

## 2. 目标与非目标

### 2.1 目标

1. 所有 Qbar 动作都能用同一套插件描述。
2. 一个别名可以对应多个插件，冲突是正常状态而不是配置错误。
3. 用户可以编辑内置工具的别名和启用状态。
4. 用户可以新增、编辑、停用自定义命令插件。
5. 插件可以声明自己的设置结构，由设置页面自动生成编辑控件。
6. 新增工具时只需要增加插件和 handler，不修改 Qbar 主分发器。
7. 输入响应过程中只使用内存注册表，不对 SQLite 做逐字符查询。
8. 历史、使用频率、冲突选择和插件设置均有稳定的 definitionId/pluginId/commandId。
9. UI、执行、历史和排序使用同一个命令身份，不通过显示文本反查命令。

### 2.2 非目标

- 不保留旧 QSearch、QRun、QWeb 的 Qbar 兼容读取路径。
- 不把可执行 AHK 代码存入数据库。
- 不允许数据库中的任意字符串直接调用任意函数。
- 不把 Qbar 命令和 CapsLock+Tab 热字符串混成同一个运行时系统。
- 不在每次输入变化时查询数据库。
- 本阶段不实现第三方远程市场、自动下载或在线更新。

## 3. 核心概念

### 3.1 插件定义、插件实例和命令

运行时把三个概念分开：

- `PluginDefinition` 是代码和 manifest 的身份，描述 handler、capability、设置 schema 和可提供的命令。它由内置代码或插件目录提供，不代表某个用户配置。
- `PluginInstance` 是一个可启用、可配置的安装实例，拥有 `pluginId`、别名、设置和状态。内置工具通常只有一个实例；用户可以用同一个定义创建多个搜索或运行实例。
- `Command` 属于一个插件实例，是 Qbar 真正执行的对象，拥有稳定的 `commandId`。同一实例可以提供多个命令并共享设置。

插件定义的 manifest 至少包含：

    {
      definitionId: "builtin.ai",
      version: 1,
      name: "AI 问答",
      icon: "bot",
      capabilities: ["panel.ai"],
      commands: [{
        id: "ask",
        title: "AI 问答",
        handlerId: "builtin.ai.ask",
        kind: "tool",
        argMode: "optional",
        priority: 100
      }],
      settingsSchema: { ... }
    }

内置定义的 manifest 可以直接由 AHK Map 构造，不要求每个内置工具额外生成文件。
外部定义使用插件目录中的 manifest 文件，但 manifest 中声明的 handler 只有在受信任代码目录中注册过才可执行。仅有一个外部 manifest 不会获得执行 AHK 的能力。

插件实例示例：

    definitionId: builtin.search
    pluginId: user.search.bd
    commandId: user.search.bd.execute

内置实例可以约定使用相同的 `definitionId` 和 `pluginId`，但二者在模型上仍然不同。复制一个用户插件时必须生成新的 `pluginId` 和 `commandId`，旧身份不能复用。

插件定义 ID 全局唯一，使用稳定、命名空间化的格式：

    builtin.ai
    builtin.everything
    builtin.notes
    builtin.settings
    builtin.path
    builtin.url
    builtin.start-menu
    user.search.bd
    user.run.cmd

插件定义 ID 一旦发布后不再因为显示名或别名变化而改变。插件实例和命令 ID 也遵守同样的稳定性规则。

### 3.2 命令

一个插件实例可以只提供一个命令，也可以提供多个共享设置的命令。命令的 handler 来自受信任的插件定义，数据库只能保存已注册的 handlerId。
命令 ID 在插件内唯一，完整 ID 使用插件 ID 加命令名：

    builtin.ai.ask
    builtin.everything.search
    user.search.bd.execute

命令描述如下：

    CommandSpec {
        id:          string
        pluginId:    string
        definitionId: string
        title:       string
        kind:        "tool" | "search" | "run" | "fallback"
        handlerId:   string
        argMode:     "none" | "optional" | "required" | "rest"
        priority:    integer
        enabled:     boolean
        usageKey:    string
    }

普通候选的执行对象始终是 commandId；动态候选还需要本次查询生成的 candidateId。显示名称、别名和当前输入文本都不是执行身份。

### 3.3 别名

别名是命令的用户入口，一个命令可以有多个别名，多个命令也可以共享一个别名。

别名规范：

- 比较时统一转小写；
- 连续空白折叠成一个空格；
- 不允许空别名；
- 不允许包含换行；
- 单词别名和多词别名都支持；
- 多词别名采用最长匹配；
- 别名与显示名称完全分离；
- 别名修改不改变 commandId。

示例：

    builtin.ai.ask
      q
      ai

    builtin.everything.search
      e
      everything
      find
      f

    builtin.settings.open
      cl set
      cl settings

## 4. 插件分类

### 4.1 内置工具插件

内置工具由程序提供插件定义和 handler，插件实例的别名、设置和启用状态由数据库管理。

首批插件：

| 插件 | 命令 | 默认别名 | 参数 |
| --- | --- | --- | --- |
| builtin.ai | ask | q、ai | 可选问题 |
| builtin.everything | search | e、everything、find、f | 可选查询 |
| builtin.notes | search | n、note、w、write | 可选关键词 |
| builtin.settings | open | cl set、cl settings | 无 |

内置插件不再在 qbar_commands.ahk 中通过专门的 if 分支识别。
它们只提供统一的 CommandSpec 和 handler。

### 4.2 声明式用户命令插件

用户通过设置页面创建的搜索、运行和打开命令，不需要编写 AHK。
它们是内置声明式定义的用户实例，使用受控 handler：

| handlerId | 用途 |
| --- | --- |
| builtin.search | URL 模板搜索 |
| builtin.run | 运行程序、文件或文件夹 |
| builtin.open-url | 打开 URL |
| builtin.open-path | 打开路径 |

数据库中的 handlerId 只能取受信任白名单，不能把任意函数名作为 handlerId 执行。

### 4.3 动态匹配插件

某些能力没有固定别名，但仍通过插件参与候选生成：

- builtin.path：识别文件、文件夹和 FTP 路径；
- builtin.url：识别完整网址或域名；
- builtin.start-menu：匹配开始菜单应用；
- builtin.folder-browser：处理目录浏览和文件补全。

动态插件通过 Match 方法返回候选，不占用普通别名表。它们仍然拥有普通的 commandId，例如
`builtin.start-menu.open`，但每个返回项还必须有一个本次查询专用的 candidateId，以及可选的稳定
candidateKey。

candidateId 由宿主在生成查询结果时创建，只在 `sessionId + queryId + registryGeneration` 对应的
结果快照中有效。候选的真实执行参数保存在宿主内存中，不随页面消息传回，也不直接写入 SQLite。
candidateKey 由动态插件生成，用于历史重放和按具体项目统计使用频率；没有稳定 key 时退回使用命令级
usageKey。动态插件的匹配优先级低于显式别名命令。

## 5. SQLite 数据模型

数据库文件：

    %AppData%\capslock_p2\qbar.db

数据库由 Qbar 单独管理，启动时打开一次，并启用外键约束。

### 5.1 schema_meta

保存数据库自身的 schema 版本：

    schema_meta(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )

至少保存：

    schema_version
    created_at
    updated_at

数据库升级使用集中式、编号递增的 migration，不由插件直接修改公共表结构。

### 5.2 plugin_definitions

插件定义表保存已发现的 manifest 元数据，不保存可执行 AHK 代码：

    plugin_definitions(
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        version INTEGER NOT NULL,
        name TEXT NOT NULL,
        icon TEXT NOT NULL DEFAULT '',
        capabilities_json TEXT NOT NULL DEFAULT '[]',
        settings_schema_json TEXT NOT NULL DEFAULT '{}',
        manifest_json TEXT NOT NULL DEFAULT '{}',
        trust_level TEXT NOT NULL,
        available INTEGER NOT NULL DEFAULT 1,
        installed_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )

source 取值为 `builtin` 或 `external`。`trust_level` 取值为：

    host-declarative
    trusted-inprocess
    isolated-process

manifest_json 是 manifest 缓存，便于 UI 展示和诊断。可执行实现的真实来源仍是受信任的代码注册表或
未来的隔离进程，数据库中的 manifest 不能自行获得执行权限。

### 5.3 plugins

plugins 表保存插件实例。用户创建两个搜索命令时，它们是同一个 plugin definition 的两个实例：

    plugins(
        id TEXT PRIMARY KEY,
        definition_id TEXT NOT NULL,
        source TEXT NOT NULL,
        display_name TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        deleted_at TEXT NOT NULL DEFAULT '',
        installed_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(definition_id) REFERENCES plugin_definitions(id)
    )

source 取值为 `builtin`、`user` 或 `external`。`deleted_at` 采用逻辑删除：实例被移除后不再进入
registry，但仍可被历史引用。物理清理是单独的 purge 操作，只有明确清理相关数据时才执行。

### 5.4 commands

    commands(
        id TEXT PRIMARY KEY,
        plugin_id TEXT NOT NULL,
        title TEXT NOT NULL,
        kind TEXT NOT NULL,
        handler_id TEXT NOT NULL,
        arg_mode TEXT NOT NULL,
        priority INTEGER NOT NULL DEFAULT 100,
        enabled INTEGER NOT NULL DEFAULT 1,
        usage_key TEXT NOT NULL,
        deleted_at TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE CASCADE
    )

索引：

    CREATE INDEX commands_plugin_idx
        ON commands(plugin_id);

命令 disabled 或所属插件 disabled 时，都不能成为有效候选。

命令定义中的 handlerId 必须在对应 plugin definition 注册时校验通过。命令或插件被逻辑删除后，不能成为
有效候选，但不会立即破坏历史。

### 5.5 command_aliases

    command_aliases(
        command_id TEXT NOT NULL,
        alias TEXT NOT NULL,
        normalized_alias TEXT NOT NULL,
        origin TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        is_default INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(command_id, normalized_alias),
        FOREIGN KEY(command_id) REFERENCES commands(id) ON DELETE CASCADE
    )

重点是不能对 normalized_alias 单独建立唯一约束。
同一个别名对应多个插件正是冲突候选的基础。

索引：

    CREATE INDEX aliases_lookup_idx
        ON command_aliases(normalized_alias, enabled);

origin 取值：

    manifest-default
    user

用户编辑内置别名时，把对应记录标记为 user。
恢复默认时删除 user 记录并重新生成 manifest-default 记录。`is_default` 只表示该别名来自 manifest
的默认别名，不表示冲突候选的默认执行项。

### 5.6 plugin_settings

插件设置使用 JSON 文档保存，不为每个插件动态创建数据库字段：

    plugin_settings(
        plugin_id TEXT PRIMARY KEY,
        schema_version INTEGER NOT NULL,
        values_json TEXT NOT NULL DEFAULT '{}',
        pending_restart INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE CASCADE
    )

插件私有设置的字段、类型、默认值和校验规则由关联 plugin definition 的 settingsSchema 声明。
主程序负责 JSON 解析、类型校验和保存，插件 handler 只接收校验后的 Map。

### 5.7 plugin_state

插件运行状态和缓存不能混入用户设置：

    plugin_state(
        plugin_id TEXT PRIMARY KEY,
        schema_version INTEGER NOT NULL,
        state_json TEXT NOT NULL DEFAULT '{}',
        updated_at TEXT NOT NULL,
        FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE CASCADE
    )

例如 Everything 的后端探测状态、某个插件的缓存索引，都应该放在这里。
不把瞬时状态写入 plugin_settings。

### 5.8 usage

    command_usage(
        usage_key TEXT PRIMARY KEY,
        command_id TEXT NOT NULL,
        candidate_key TEXT NOT NULL DEFAULT '',
        score REAL NOT NULL DEFAULT 0,
        use_count INTEGER NOT NULL DEFAULT 0,
        last_used_at TEXT NOT NULL DEFAULT '',
        FOREIGN KEY(command_id) REFERENCES commands(id) ON DELETE CASCADE
    )

普通命令的 usageKey 等于 commandId，因此 q、ai 都执行 builtin.ai.ask 时共享同一个 usage 记录。
动态候选有稳定 candidateKey 时，usageKey 由 commandId 和 candidateKey 派生，使开始菜单中的不同
应用可以分别排序；没有稳定 key 时退回命令级 usageKey。candidateId 是一次查询的临时身份，不能写入
usage 表。

使用分数采用时间衰减。读取时先计算：

    effectiveScore =
        score * 2 ^ (-(now - last_used_at) / half_life)

建议半衰期为 7 天。一次成功执行的更新顺序为：先把旧 score 衰减到当前时间，再执行
`score = effectiveScore + 1`、`use_count = use_count + 1` 并写入当前 UTC 时间。

### 5.9 history

    command_history(
        id TEXT PRIMARY KEY,
        command_id TEXT NOT NULL,
        plugin_id TEXT NOT NULL,
        command_title TEXT NOT NULL,
        candidate_key TEXT NOT NULL DEFAULT '',
        input_text TEXT NOT NULL,
        args_json TEXT NOT NULL DEFAULT '{}',
        payload_json TEXT NOT NULL DEFAULT '{}',
        replayable INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        last_used_at TEXT NOT NULL,
        FOREIGN KEY(command_id) REFERENCES commands(id) ON DELETE CASCADE
    )

历史记录保存 commandId、pluginId、标题快照、可选 candidateKey 和经过 handler 校验的可重放 payload，
不通过别名重新解析。用户修改别名后，历史仍然知道原来执行的是哪个插件命令；插件逻辑删除后，
历史可以显示快照并标记为不可重放。逻辑删除不会触发上述外键级联，物理 purge 才会清理相关历史。

## 6. 插件设置协议

### 6.1 settingsSchema

插件通过 manifest 声明设置：

    settingsSchema: {
        template: {
            type: "url-template",
            required: true
        },
        encodeQuery: {
            type: "boolean",
            default: true
        }
    }

支持的基础类型：

    string
    multiline
    integer
    number
    boolean
    enum
    url
    url-template
    command-line
    path
    secret-reference

每个字段还可以声明：

    label
    description
    default
    required
    min
    max
    pattern
    reloadPolicy
    secret

### 6.2 QSearch 设置

每个 QSearch 命令是 `builtin.search` 定义的一个用户插件实例：

    definitionId: builtin.search
    pluginId: user.search.bd
    commandId: user.search.bd.execute

    settings: {
        template: "https://www.baidu.com/s?wd={q}",
        encodeQuery: true
    }

别名、显示名称和 URL 模板不再拼在一个 INI 键名中，而是分开存储。

### 6.3 QRun 设置

    definitionId: builtin.run
    pluginId: user.run.cmd
    commandId: user.run.cmd.execute

    settings: {
        command: "C:\\Windows\\System32\\cmd.exe",
        runAs: false,
        argumentMode: "append"
    }

Run 参数必须通过结构化字段保存，最终由 builtin.run handler 统一构造命令。
数据库中的字符串不能直接选择 AHK 函数。

### 6.4 共享服务

插件不重复实现 AI、网址打开、进程启动、Everything 等基础能力。
由 PluginHost 提供受控服务：

    context.services.openUrl(...)
    context.services.runProcess(...)
    context.services.showPanel(...)
    context.services.everything(...)
    context.services.ai(...)
    context.services.notify(...)

插件只描述需要的 capability，宿主在执行前检查 capability。

对于 `host-declarative` 和 `trusted-inprocess` 定义，capability 是宿主的调用策略；它不能把不受信任的
同进程 AHK 代码变成沙箱。需要加载不受信任第三方代码时，必须使用 `isolated-process` 定义，通过受限
IPC 调用宿主服务，并由宿主处理超时、退出和消息大小限制。

## 7. 注册流程

### 7.1 启动阶段

1. 打开 qbar.db。
2. 执行数据库 schema migration。
3. 注册内置 plugin definition 和受信任 handler。
4. 扫描外部 manifest；未通过信任校验的定义只记录为 unavailable，不加载可执行代码。
5. 在事务中 upsert definition、plugin instance 和 command 元数据。
6. 为首次出现的命令生成默认别名。
7. 加载用户别名、启用状态和逻辑删除状态。
8. 按 definition 的 settingsSchema 升级并校验所有实例设置。
9. 构建内存中的 CommandRegistry 和动态 provider。
10. 为每个 Qbar session 创建查询快照缓存，并发布 registry generation。

内置 manifest 的默认值不能覆盖用户已经保存的 settings 或别名。
设置升级或校验失败时保留数据库中的原始值，将对应实例标记为 configuration-error，并从有效 registry
中排除，直到用户修复设置。

### 7.2 配置修改

设置页面修改插件、命令、别名或设置时：

1. 在内存中把待修改值与当前 definition schema 合并，并完成类型、范围、模板和 capability 校验；
2. 根据待修改值构建新的待发布 RuntimeRegistry，构建失败时不写数据库；
3. 在一个 SQLite transaction 中写入变更并提交；写入失败时回滚，继续使用旧 registry；
4. 提交成功后原子替换内存 registry，递增 registry generation；
5. 使当前 session 的旧 resolution snapshot 失效，并通知 qbar 页面重新查询；
6. 下次查询使用新 registry。

不在输入回调中写数据库。

只有成功发布后才递增 registry generation。`reloadPolicy` 为 restart 的设置写入 values_json 并设置
pending_restart=1，但当前实例继续使用旧的已发布设置，直到下次启动；同一个实例中只要有一个字段要求
restart，本次修改的整组设置都等待重启，避免同一插件同时使用两份配置。启动成功加载后清除
pending_restart。immediate 设置按上述流程即时发布。

### 7.3 插件停用

停用插件只修改 plugins.enabled。

- 不删除命令；
- 不删除别名；
- 不删除历史；
- 不删除使用频率；
- 下次启用后自动恢复。

删除用户插件时默认只做逻辑删除，不立即清理其命令、别名、设置和状态；历史由快照和逻辑删除状态
显示“插件已删除”，不参与新的下拉排序。

这里的“删除”默认指逻辑删除：设置 `plugins.deleted_at` 并将实例及其命令从有效 registry 排除，保留
别名、使用频率和历史以便恢复或展示。物理 purge 是单独的明确操作，会按外键级联清理实例数据、
使用频率和历史；purge 后不承诺保留原 commandId 的可重放能力，也不复用旧 ID。

## 8. 命令解析

### 8.1 解析结果

解析器返回：

    Resolution {
        sessionId
        queryId
        rawText
        normalizedInput
        matchedAlias
        args
        candidates[]
        selectedCandidateId
        registryGeneration
    }

candidates 中每一项包含：

    candidateId
    commandId
    pluginId
    candidateKey
    title
    icon
    matchedAlias
    args
    matchRank
    usageScore
    usageLastUsedAt
    conflict

静态别名候选的 candidateKey 为空，candidateId 仍由本次查询生成。动态候选的执行参数只保存在宿主的
resolution snapshot 中；页面收到的行数据不包含可直接执行的任意 payload。解析器在内存中保留最近的
有限数量 snapshot，配置变化或 session 结束时全部失效。

### 8.2 最长匹配

输入：

    cl settings

如果同时存在 cl 和 cl settings，优先匹配多词别名 cl settings。

匹配顺序：

1. 完整多词别名；
2. 完整单词别名；
3. 前缀匹配；
4. 动态 fallback；
5. 无匹配。

### 8.3 冲突解析

以 q 为例：

    candidates:
      builtin.ai.ask
      user.search.q.execute

解析器不直接丢弃任何候选。

候选列表先按匹配等级排序，再在同一匹配等级内按以下稳定规则排序：

1. usageScore 降序；
2. last_used_at 降序；
3. command priority 降序；
4. commandId、candidateKey 字典序。

usageScore 是按半衰期衰减后的分数，因此最近成功使用的命令会自然排在前面。没有页面选择时，初始
选中列表第一项；用户在页面上明确选择候选后，执行请求中的 candidateId 直接确定本次执行对象。

如果输入带参数，所有候选共享同一份原始参数，但由各自 handler 解释。
例如：

    q weather

AI 插件和搜索插件都能看到 weather，用户选择谁就执行谁。

## 9. Qbar 页面协议

当前页面不应再依赖 selectedType 判断行为。

Qbar 打开时宿主为页面分配一个 sessionId。页面在同一个 session 内为每次输入递增 queryId；宿主为
每次查询建立一个 resolution snapshot。页面展示的 candidateId 只在对应的
`sessionId + queryId + registryGeneration` 范围内有效。

建议消息结构：

查询结果：

    {
      sessionId: "qbar-17",
      queryId: 42,
      registryGeneration: 12,
      candidateId: "c-42-2",
      commandId: "user.search.q.execute",
      pluginId: "user.search.q",
      candidateKey: "",
      short: "q",
      label: "必应搜索",
      alias: "q",
      args: "weather",
      type: "search",
      conflict: true,
      matchRank: 0,
      usageScore: 2.4
    }

执行消息：

    {
      type: "execute",
      sessionId: "qbar-17",
      queryId: 42,
      candidateId: "c-42-2",
      commandId: "user.search.q.execute",
      text: "q weather",
      ctrl: false,
      registryGeneration: 12
    }

AHK 执行前必须同时检查 sessionId、queryId、candidateId 和 registryGeneration，并确认 candidateId 对应
的 commandId 与消息中的 commandId 一致。任何一项不匹配，都直接返回 stale-resolution，页面重新查询，
不能使用页面传回的 text 或 args 代替旧候选执行。

当页面在输入变化后还没有收到新的查询结果，或者用户没有选中任何候选时，执行消息可以省略
candidateId；宿主只使用当前 registry 对消息中的 text 重新解析。此路径不会复用旧 snapshot。

queryId 只在当前 session 内递增，避免页面重新加载后与旧 snapshot 的数字碰撞。宿主应限制 snapshot
数量和存活时间，session 关闭或 registry generation 变化时清理旧 snapshot。

## 10. 执行生命周期

插件 handler 不能直接决定历史是否写入。
统一返回：

    ExecutionResult {
        status: "success" | "failed" | "deferred" | "cancelled",
        executionId,
        commandId,
        usageKey,
        historyPayload,
        message
    }

宿主处理规则：

- success：写入 history 和 usage；
- failed：显示错误，不写成功记录；
- deferred：返回 executionId，由异步完成回调决定最终结果；
- cancelled：不写记录。

Everything、AI、设置页面等异步面板必须显式报告成功、失败和取消。

动态候选完成执行后，宿主把 handler 返回的 candidateKey 和经过校验的 historyPayload 写入历史；不把
临时 candidateId 当作可重放身份。历史重放直接使用 commandId、candidateKey 和 payload，并再次检查当前
插件是否启用、设置是否有效以及 capability 是否允许。

handler 只负责动作本身，宿主负责：

- Qbar 隐藏；
- 历史记录；
- 使用频率；
- 错误展示；
- registry generation；
- 日志。

## 11. 内存注册表

SQLite 不是输入热路径。
启动或配置变化后构建：

    Registry {
        generation
        byAlias: Map<normalizedAlias, Candidate[]>
        byCommandId: Map<commandId, CommandRuntime>
        dynamicProviders[]
        visibleCommands[]
    }

每次输入只访问内存 Map 和动态 provider。

registry generation 是进程内递增的运行时版本，不写入 qbar.db；进程启动时从 1 开始。sessionId 会阻止
旧页面把另一个进程中的数字 generation 当成当前结果，因此没有跨进程持久化 generation 的必要。

动态 provider 也不能直接查询 SQLite；需要从宿主拿到已加载的设置和必要缓存。

查询引擎为每个结果创建 `ResolutionSnapshot`：

    ResolutionSnapshot {
        sessionId
        queryId
        registryGeneration
        rawText
        candidates: Map<candidateId, ResolvedCandidate>
    }

`ResolvedCandidate` 保存 commandId、candidateKey、解析后的参数和动态执行 payload。页面只收到可展示
字段和 candidateId，执行时由宿主从 snapshot 取回 payload。snapshot 是短期内存对象，不进入 SQLite。

插件设置读取后缓存到 RuntimePlugin：

    RuntimePlugin {
        definitionId
        pluginId
        manifest
        settings
        state
        commands
        status
    }

## 12. 设置页面

设置页面改为插件管理器，分为三个区域。

### 12.1 插件列表

显示：

- 插件名称；
- 内置/用户/外部来源；
- 启用状态；
- 版本；
- 命令数量；
- 是否有冲突；
- 是否有配置错误。

### 12.2 命令和别名

每个命令显示：

- 命令名称；
- 所属插件；
- 别名 chips；
- 使用频率；
- 冲突候选；
- 启用/停用；
- 恢复默认别名。

添加别名时即时显示占用情况，但允许保存冲突。

### 12.3 插件设置

根据 settingsSchema 自动生成：

- 文本框；
- URL 模板框；
- 数字范围；
- 下拉选项；
- 布尔开关；
- 路径选择；
- 密钥引用。

保存时一次 transaction 写入设置，并触发 registry generation 更新。

## 13. 文件结构

建议的新模块：

    lib/features/qbar/qbar_plugin_host.ahk
    lib/features/qbar/qbar_plugin_catalog.ahk
    lib/features/qbar/qbar_registry.ahk
    lib/features/qbar/qbar_store.ahk
    lib/features/qbar/qbar_plugin_services.ahk
    lib/features/qbar/qbar_execution.ahk

职责：

- qbar_plugin_host：插件生命周期和 handler 白名单；
- qbar_plugin_catalog：内置插件 manifest；
- qbar_registry：命令、别名、冲突和解析；
- qbar_store：SQLite schema、transaction、queries；
- qbar_plugin_services：打开 URL、运行进程、面板、Everything、AI 等服务；
- qbar_execution：统一执行结果、历史和使用频率；
- qbar_index：只负责把 registry 候选转换成页面行；
- qbar.html：只负责候选展示、选择和发送 sessionId、queryId、candidateId 与 commandId。

未来不应再把具体插件分支堆到 qbar_commands.ahk。

## 14. 安全边界

1. SQLite 中只能保存已经注册的 handlerId，handlerId 必须来自宿主白名单或受信任代码注册表。
2. manifest、数据库字段和页面消息都不能直接指定任意 AHK 函数。
3. `host-declarative` 只允许宿主提供的结构化 handler；`trusted-inprocess` 只允许明确注册并信任的
   AHK 代码；`isolated-process` 才用于未来的不受信任外部代码。
4. capability 在执行前检查。对同进程 trusted-inprocess 代码，capability 是调用策略，不是安全沙箱。
5. secret 类型设置不能直接作为普通文本展示，日志和历史 payload 也不得写入明文密钥。
6. 插件设置 JSON 经过 schema 校验和版本升级后才能进入 handler。
7. 数据库写入统一走参数化查询；插件 manifest 不能直接修改公共 schema。
8. 单个 handler 的异常要转换为 failed 并隔离对应候选；宿主对同进程代码不承诺能隔离进程级崩溃，真正
   的故障隔离必须使用 isolated-process。
9. 一个插件的 settings/state 不能读取另一个插件实例的私有命名空间，跨插件能力只能通过宿主服务完成。

## 15. 实施阶段

### 阶段一：基础存储与 Host

- 创建 qbar.db；
- 建立 schema_meta、plugin_definitions、plugins、commands、aliases、bindings、settings、state、usage、history；
- 实现 plugin definition、plugin instance 和 command 的关系；
- 实现 transaction、设置校验、逻辑删除和 registry generation；
- 实现 handler 白名单和信任级别；
- 不接入页面。

### 阶段二：内置插件

- 将 AI、Everything、笔记、设置注册为内置插件；
- 将路径、网址、开始菜单注册为动态 fallback 插件；
- 把默认别名写入数据库；
- 用统一 ExecutionResult 代替散落的成功判断。

### 阶段三：用户命令插件

- 实现 builtin.search handler；
- 实现 builtin.run handler；
- 设置页面创建搜索和运行插件；
- QSearch、QRun 不再作为独立配置段存在。

### 阶段四：页面协议

- qbar 查询结果携带 commandId；
- 页面执行携带 sessionId、queryId、candidateId、commandId 和 registryGeneration；
- 实现 resolution snapshot，动态候选的执行参数只保存在宿主内存；
- 支持同一别名的多候选展示；
- 支持冲突候选展示和插件别名编辑。

### 阶段五：历史与排序

- history 统一保存 commandId，usage 按 usageKey 关联到 commandId；
- 实现时间衰减频率；
- 普通候选和动态候选分别使用 commandId 或 commandId + candidateKey 统计；
- 冲突候选先按匹配等级，再按使用频率、最近使用时间、优先级和稳定 ID 排序；
- 历史重放直接调用 commandId 和已校验 payload，不重新按别名解析。

### 阶段六：外部插件

- 扫描插件目录；
- 读取 manifest；
- 校验版本、trust level 和 capability；
- 先支持声明式 external definition；需要执行第三方代码时使用 trusted-inprocess 或 isolated-process；
- 提供启用、停用和删除；
- manifest 或 handler 失败时将对应 definition 标记 unavailable，不影响其他 definition；进程级故障隔离
  只由 isolated-process 提供。

## 16. 验收条件

1. AI、Everything、笔记、设置、搜索、运行、路径和开始菜单都通过 commandId 执行。
2. Q 与用户搜索命令同时存在时，下拉列表显示两个候选。
3. 用户可以编辑 AI 的 q/ai 别名。
4. 同一别名对应多个命令时，所有候选都显示，并按统一匹配和使用频率规则排序。
5. 一个别名冲突不会导致另一个插件消失。
6. QSearch 和 QRun 的设置由插件 schema 生成。
7. 输入变化过程中不访问 SQLite。
8. 执行成功后按 usageKey 更新使用频率，静态命令按 commandId，动态项目可按 commandId + candidateKey。
9. 禁用插件后，其命令和别名立即从有效注册表消失。
10. 插件逻辑删除后，旧历史仍能显示快照；purge 才清理关联数据。
11. 插件设置修改失败时事务回滚，旧 registry 继续服务；修改成功后旧 query snapshot 不能执行。
12. 页面收到旧 queryId、candidateId 或 registryGeneration 时，执行被拒绝并要求重新查询。
13. 新增一个工具插件不需要修改 Qbar 主分发器。
14. QWeb 仍可作为 CapsLock+Tab 网址展开来源，但不会进入 Qbar 命令注册表。

## 17. 最终原则

- manifest 定义能力；
- definition 描述代码能力，instance 保存用户配置；
- SQLite 保存用户状态；
- registry 提供运行时视图；
- commandId 是稳定的命令执行身份，candidateId 只负责校验本次查询中的具体候选；
- candidateId 只标识一次查询中的候选，candidateKey 才用于动态候选的重放和统计；
- alias 只是入口，不是命令身份；
- 冲突是候选集合，不是错误；
- settings 属于插件；
- history 属于命令，usage 可按命令或动态候选的稳定 key 统计；
- handler 由宿主安全调用；
- 同进程受信任代码不等于安全沙箱；
- Qbar 页面不包含业务分发逻辑。
