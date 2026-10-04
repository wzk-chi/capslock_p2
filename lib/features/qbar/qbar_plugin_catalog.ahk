; Built-in Qbar plugin definitions.
;
; Definitions describe code capabilities. User editable aliases and instance
; state are persisted by qbar_store.ahk, so changing an alias never changes a
; commandId.

QbarPluginCatalogDefinitions() {
    return [
        Map(
            "definitionId", "builtin.ai",
            "source", "builtin",
            "version", 1,
            "name", "AI 问答",
            "icon", "bot",
            "trustLevel", "trusted-inprocess",
            "capabilities", ["panel.ai"],
            "settingsSchema", Map(),
            "commands", [Map(
                "id", "ask",
                "title", "AI 问答",
                "kind", "tool",
                "handlerId", "builtin.ai.ask",
                "argMode", "optional",
                "priority", 100,
                "usageKey", "builtin:ai",
                "aliases", ["q", "ai"])]),
        Map(
            "definitionId", "builtin.everything",
            "source", "builtin",
            "version", 1,
            "name", "文件搜索",
            "icon", "search",
            "trustLevel", "trusted-inprocess",
            "capabilities", ["panel.everything"],
            "settingsSchema", Map(),
            "commands", [Map(
                "id", "search",
                "title", "文件搜索",
                "kind", "search",
                "handlerId", "builtin.everything.search",
                "argMode", "optional",
                "priority", 100,
                "usageKey", "builtin:everything",
                "aliases", ["e", "everything", "find", "f"])]),
        Map(
            "definitionId", "builtin.notes",
            "source", "builtin",
            "version", 1,
            "name", "笔记",
            "icon", "notes",
            "trustLevel", "trusted-inprocess",
            "capabilities", ["panel.notes"],
            "settingsSchema", Map(),
            "commands", [Map(
                "id", "search",
                "title", "笔记",
                "kind", "search",
                "handlerId", "builtin.notes.search",
                "argMode", "optional",
                "priority", 100,
                "usageKey", "builtin:notes",
                "aliases", ["n", "note", "w", "write"])]),
        Map(
            "definitionId", "builtin.clipboard",
            "source", "builtin",
            "version", 1,
            "name", "剪贴板历史",
            "icon", "clipboard-list",
            "trustLevel", "trusted-inprocess",
            "capabilities", ["panel.clipboard"],
            "settingsSchema", Map(
                "enabled", Map("type", "boolean", "label", "记录剪贴板历史", "default", true),
                "maxItems", Map("type", "integer", "label", "非收藏历史上限",
                    "default", 500, "min", 20, "max", 5000, "step", 1),
                "maxCaptureBytes", Map("type", "integer", "label", "单次采集上限（MiB）",
                    "default", 268435456, "min", 1048576, "max", 268435456,
                    "step", 1048576, "displayScale", 1048576),
                "retentionDays", Map("type", "integer", "label", "历史保存天数",
                    "default", 30, "min", 1, "max", 3650, "step", 1)),
            "commands", [Map(
                "id", "open",
                "title", "剪贴板历史",
                "kind", "tool",
                "handlerId", "builtin.clipboard.open",
                "argMode", "optional",
                "priority", 100,
                "usageKey", "builtin:clipboard",
                "aliases", ["cv"])]),
        Map(
            "definitionId", "builtin.settings",
            "source", "builtin",
            "version", 1,
            "name", "设置",
            "icon", "settings",
            "trustLevel", "trusted-inprocess",
            "capabilities", ["panel.settings"],
            "settingsSchema", Map(),
            "commands", [Map(
                "id", "open",
                "title", "打开设置",
                "kind", "tool",
                "handlerId", "builtin.settings.open",
                "argMode", "none",
                "priority", 100,
                "usageKey", "builtin:settings",
                "aliases", ["cl set", "cl settings"])]),
        Map(
            "definitionId", "builtin.path",
            "source", "builtin",
            "version", 1,
            "name", "路径打开",
            "icon", "folder",
            "trustLevel", "trusted-inprocess",
            "capabilities", ["filesystem.open"],
            "settingsSchema", Map(),
            "commands", [Map(
                "id", "open",
                "title", "打开路径",
                "kind", "fallback",
                "handlerId", "builtin.open-path",
                "argMode", "required",
                "priority", 10,
                "usageKey", "builtin:path",
                "dynamic", true)]),
        Map(
            "definitionId", "builtin.url",
            "source", "builtin",
            "version", 1,
            "name", "网址打开",
            "icon", "web",
            "trustLevel", "trusted-inprocess",
            "capabilities", ["browser.open"],
            "settingsSchema", Map(),
            "commands", [Map(
                "id", "open",
                "title", "打开网址",
                "kind", "fallback",
                "handlerId", "builtin.open-url",
                "argMode", "required",
                "priority", 10,
                "usageKey", "builtin:url",
                "dynamic", true)]),
        Map(
            "definitionId", "builtin.start-menu",
            "source", "builtin",
            "version", 1,
            "name", "开始菜单",
            "icon", "app",
            "trustLevel", "trusted-inprocess",
            "capabilities", ["process.start"],
            "settingsSchema", Map(),
            "commands", [Map(
                "id", "open",
                "title", "开始菜单应用",
                "kind", "fallback",
                "handlerId", "builtin.start-menu.open",
                "argMode", "required",
                "priority", 10,
                "usageKey", "builtin:start-menu",
                "dynamic", true)]),
        Map(
            "definitionId", "builtin.search",
            "source", "builtin",
            "version", 1,
            "name", "网址搜索",
            "icon", "search",
            "trustLevel", "host-declarative",
            "capabilities", ["browser.open"],
            "settingsSchema", Map(
                "template", Map("type", "url-template", "required", true),
                "encodeQuery", Map("type", "boolean", "default", true)),
            "commands", [Map(
                "id", "execute",
                "title", "网址搜索",
                "kind", "search",
                "handlerId", "builtin.search",
                "argMode", "required",
                "priority", 100,
                "usageKey", "")]),
        Map(
            "definitionId", "builtin.run",
            "source", "builtin",
            "version", 1,
            "name", "快捷命令",
            "icon", "app",
            "trustLevel", "host-declarative",
            "capabilities", ["process.start"],
            "settingsSchema", Map(
                "command", Map("type", "command-line", "required", true),
                "runAs", Map("type", "boolean", "default", false),
                "argumentMode", Map("type", "enum", "values", ["append", "replace"], "default", "append")),
            "commands", [Map(
                "id", "execute",
                "title", "快捷命令",
                "kind", "run",
                "handlerId", "builtin.run",
                "argMode", "optional",
                "priority", 100,
                "usageKey", "")])
    ]
}

QbarPluginCatalogBuiltinInstances() {
    return [
        Map("definitionId", "builtin.ai", "pluginId", "builtin.ai", "source", "builtin", "displayName", "AI 问答"),
        Map("definitionId", "builtin.everything", "pluginId", "builtin.everything", "source", "builtin", "displayName", "文件搜索"),
        Map("definitionId", "builtin.notes", "pluginId", "builtin.notes", "source", "builtin", "displayName", "笔记"),
        Map("definitionId", "builtin.clipboard", "pluginId", "builtin.clipboard", "source", "builtin",
            "displayName", "剪贴板历史"),
        Map("definitionId", "builtin.settings", "pluginId", "builtin.settings", "source", "builtin", "displayName", "设置"),
        Map("definitionId", "builtin.path", "pluginId", "builtin.path", "source", "builtin", "displayName", "路径打开"),
        Map("definitionId", "builtin.url", "pluginId", "builtin.url", "source", "builtin", "displayName", "网址打开"),
        Map("definitionId", "builtin.start-menu", "pluginId", "builtin.start-menu", "source", "builtin", "displayName", "开始菜单"),
        Map("definitionId", "builtin.search", "pluginId", "builtin.search.bd", "source", "builtin",
            "displayName", "百度", "settings", Map("template", "https://www.baidu.com/s?wd={q}", "encodeQuery", true),
            "commandAliases", Map("builtin.search.bd.execute", ["bd"])),
        Map("definitionId", "builtin.search", "pluginId", "builtin.search.g", "source", "builtin",
            "displayName", "Google", "settings", Map("template", "https://www.google.com/search?q={q}", "encodeQuery", true),
            "commandAliases", Map("builtin.search.g.execute", ["g", "gg"])),
        Map("definitionId", "builtin.search", "pluginId", "builtin.search.bing", "source", "builtin",
            "displayName", "Bing", "settings", Map("template", "https://www.bing.com/search?q={q}", "encodeQuery", true),
            "commandAliases", Map("builtin.search.bing.execute", ["s", "bing"])),
        Map("definitionId", "builtin.search", "pluginId", "builtin.search.wiki", "source", "builtin",
            "displayName", "维基百科", "settings", Map("template", "https://zh.wikipedia.org/w/index.php?search={q}", "encodeQuery", true),
            "commandAliases", Map("builtin.search.wiki.execute", ["wk"])),
        Map("definitionId", "builtin.search", "pluginId", "builtin.search.mdn", "source", "builtin",
            "displayName", "MDN", "settings", Map("template", "https://developer.mozilla.org/zh-CN/search?q={q}", "encodeQuery", true),
            "commandAliases", Map("builtin.search.mdn.execute", ["m", "mdn"])),
        Map("definitionId", "builtin.run", "pluginId", "builtin.run.cmd", "source", "builtin",
            "displayName", "命令提示符", "settings", Map("command", "cmd.exe", "runAs", true, "argumentMode", "append"),
            "commandAliases", Map("builtin.run.cmd.execute", ["cmd"])),
        Map("definitionId", "builtin.run", "pluginId", "builtin.run.pwsh", "source", "builtin",
            "displayName", "PowerShell 7", "settings", Map("command", "pwsh.exe", "runAs", true, "argumentMode", "append"),
            "commandAliases", Map("builtin.run.pwsh.execute", ["pwsh"]))
    ]
}

QbarPluginCatalogRetiredBuiltinPluginIds() {
    return ["builtin.search.default"]
}

QbarPluginCatalogDefinitionById(definitionId) {
    for definition in QbarPluginCatalogDefinitions()
        if definition["definitionId"] = definitionId
            return definition
    return 0
}
