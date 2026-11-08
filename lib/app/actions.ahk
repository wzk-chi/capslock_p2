; Trusted action definitions. IDs remain the existing configuration API names.
; Handler references, validation policy and editor metadata share this catalog.

ActionCatalog() {
    static catalog := ActionCatalogBuild()
    return catalog
}

ActionDefinition(id, handler, label, group, arguments := "none", custom := false, listed := true) {
    return Map("id", id, "handler", handler, "label", label, "group", group,
        "arguments", arguments, "custom", custom, "listed", listed)
}

ActionCatalogBuild() {
    catalog := Map(
        "@block", ActionDefinition("@block", 0, "禁用动作", "other"),
        "@native", ActionDefinition("@native", 0, "保留应用原键", "other"))
    for action in [
        ActionDefinition("keyFunc_doNothing", keyFunc_doNothing, "无操作", "other", "none", true, true),
        ActionDefinition("keyFunc_send", keyFunc_send, "自定义", "other", "text", false, true),
        ActionDefinition("keyFunc_run", keyFunc_run, "运行程序", "other", "text", false, true),
        ActionDefinition("keyFunc_toggleCapsLock", keyFunc_toggleCapsLock, "切换大小写", "press", "none", true, true),
        ActionDefinition("keyFunc_mouseSpeedIncrease", keyFunc_mouseSpeedIncrease, "提高鼠标速度", "mouse", "none", true, true),
        ActionDefinition("keyFunc_mouseSpeedDecrease", keyFunc_mouseSpeedDecrease, "降低鼠标速度", "mouse", "none", true, true),
        ActionDefinition("keyFunc_moveLeft", keyFunc_moveLeft, "向左移动", "move", "count", true, true),
        ActionDefinition("keyFunc_moveRight", keyFunc_moveRight, "向右移动", "move", "count", true, true),
        ActionDefinition("keyFunc_moveUp", keyFunc_moveUp, "向上移动", "move", "count", true, true),
        ActionDefinition("keyFunc_moveDown", keyFunc_moveDown, "向下移动", "move", "count", true, true),
        ActionDefinition("keyFunc_moveWordLeft", keyFunc_moveWordLeft, "按词向左移动", "move", "count", true, true),
        ActionDefinition("keyFunc_moveWordRight", keyFunc_moveWordRight, "按词向右移动", "move", "count", true, true),
        ActionDefinition("keyFunc_backspace", keyFunc_backspace, "退格", "edit", "none", true, true),
        ActionDefinition("keyFunc_delete", keyFunc_delete, "删除字符", "edit", "none", true, true),
        ActionDefinition("keyFunc_deleteAll", keyFunc_deleteAll, "删除全部", "edit", "none", true, true),
        ActionDefinition("keyFunc_deleteWord", keyFunc_deleteWord, "删除单词", "edit", "none", true, true),
        ActionDefinition("keyFunc_forwardDeleteWord", keyFunc_forwardDeleteWord, "向后删除单词", "edit", "none", true, true),
        ActionDefinition("keyFunc_end", keyFunc_end, "移动到行尾", "move", "none", true, true),
        ActionDefinition("keyFunc_home", keyFunc_home, "移动到行首", "move", "none", true, true),
        ActionDefinition("keyFunc_moveToPageBeginning", keyFunc_moveToPageBeginning, "移动到页面开头", "move", "none", true, true),
        ActionDefinition("keyFunc_moveToPageEnd", keyFunc_moveToPageEnd, "移动到页面末尾", "move", "none", true, true),
        ActionDefinition("keyFunc_deleteLine", keyFunc_deleteLine, "删除整行", "edit", "none", true, true),
        ActionDefinition("keyFunc_deleteToLineBeginning", keyFunc_deleteToLineBeginning, "删除到行首", "edit", "none", true, true),
        ActionDefinition("keyFunc_deleteToLineEnd", keyFunc_deleteToLineEnd, "删除到行尾", "edit", "none", true, true),
        ActionDefinition("keyFunc_deleteToPageBeginning", keyFunc_deleteToPageBeginning, "删除到页面开头", "edit", "none", true, true),
        ActionDefinition("keyFunc_deleteToPageEnd", keyFunc_deleteToPageEnd, "删除到页面末尾", "edit", "none", true, true),
        ActionDefinition("keyFunc_enterWherever", keyFunc_enterWherever, "在任意位置回车", "edit", "none", true, true),
        ActionDefinition("keyFunc_esc", keyFunc_esc, "退出 / 取消", "other", "none", true, true),
        ActionDefinition("keyFunc_enter", keyFunc_enter, "回车", "edit", "none", true, true),
        ActionDefinition("keyFunc_doubleChar", keyFunc_doubleChar, "输入成对字符", "edit", "pair", false, true),
        ActionDefinition("keyFunc_sendChar", keyFunc_sendChar, "发送字符", "edit", "text", false, true),
        ActionDefinition("keyFunc_doubleAngle", keyFunc_doubleAngle, "输入尖括号", "edit", "none", true, true),
        ActionDefinition("keyFunc_doubleQuote", keyFunc_doubleQuote, "输入双引号", "edit", "none", true, true),
        ActionDefinition("keyFunc_pageUp", keyFunc_pageUp, "向上翻页", "move", "none", true, true),
        ActionDefinition("keyFunc_pageDown", keyFunc_pageDown, "向下翻页", "move", "none", true, true),
        ActionDefinition("keyFunc_pageMoveUp", keyFunc_pageMoveUp, "切换到上一个页面", "other", "none", true, true),
        ActionDefinition("keyFunc_pageMoveDown", keyFunc_pageMoveDown, "切换到下一个页面", "other", "none", true, true),
        ActionDefinition("keyFunc_switchClipboard", keyFunc_switchClipboard, "切换粘贴来源", "clipboard", "none", true, true),
        ActionDefinition("keyFunc_pasteSystem", keyFunc_pasteSystem, "粘贴系统剪贴板", "clipboard", "none", true, true),
        ActionDefinition("keyFunc_cut_1", keyFunc_cut_1, "剪切到剪贴板 1", "clipboard", "none", true, true),
        ActionDefinition("keyFunc_copy_1", keyFunc_copy_1, "复制到剪贴板 1", "clipboard", "none", true, true),
        ActionDefinition("keyFunc_paste_1", keyFunc_paste_1, "粘贴剪贴板 1", "clipboard", "none", true, true),
        ActionDefinition("keyFunc_undoRedo", keyFunc_undoRedo, "撤销 / 重做", "other", "none", true, true),
        ActionDefinition("keyFunc_cut_2", keyFunc_cut_2, "剪切到剪贴板 2", "clipboard", "none", true, true),
        ActionDefinition("keyFunc_copy_2", keyFunc_copy_2, "复制到剪贴板 2", "clipboard", "none", true, true),
        ActionDefinition("keyFunc_paste_2", keyFunc_paste_2, "粘贴剪贴板 2", "clipboard", "none", true, true),
        ActionDefinition("keyFunc_qbar", keyFunc_qbar, "打开 qbar", "tools", "none", true, true),
        ActionDefinition("keyFunc_clipboardHistory", keyFunc_clipboardHistory, "打开剪贴板历史", "clipboard", "none", true, true),
        ActionDefinition("keyFunc_notes", keyFunc_notes, "打开笔记", "tools", "none", true, true),
        ActionDefinition("keyFunc_notesCyclePrompt", keyFunc_notesCyclePrompt, "复制下一篇循环笔记", "tools", "none", true, true),
        ActionDefinition("keyFunc_aiChat", keyFunc_aiChat, "打开 AI 问答", "tools", "none", true, true),
        ActionDefinition("keyFunc_translate", keyFunc_translate, "打开翻译", "tools", "none", true, true),
        ActionDefinition("keyFunc_tabPrve", keyFunc_tabPrve, "切换到上一个标签页", "other", "none", true, true),
        ActionDefinition("keyFunc_tabNext", keyFunc_tabNext, "切换到下一个标签页", "other", "none", true, true),
        ActionDefinition("keyFunc_jumpPageTop", keyFunc_jumpPageTop, "跳到页面顶部", "move", "none", true, true),
        ActionDefinition("keyFunc_jumpPageBottom", keyFunc_jumpPageBottom, "跳到页面底部", "move", "none", true, true),
        ActionDefinition("keyFunc_selectUp", keyFunc_selectUp, "向上选中", "select", "count", true, true),
        ActionDefinition("keyFunc_selectDown", keyFunc_selectDown, "向下选中", "select", "count", true, true),
        ActionDefinition("keyFunc_selectLeft", keyFunc_selectLeft, "向左选中", "select", "count", true, true),
        ActionDefinition("keyFunc_selectRight", keyFunc_selectRight, "向右选中", "select", "count", true, true),
        ActionDefinition("keyFunc_selectHome", keyFunc_selectHome, "选中到行首", "select", "none", true, true),
        ActionDefinition("keyFunc_selectEnd", keyFunc_selectEnd, "选中到行尾", "select", "none", true, true),
        ActionDefinition("keyFunc_selectToPageBeginning", keyFunc_selectToPageBeginning, "选中到页面开头", "select", "none", true, true),
        ActionDefinition("keyFunc_selectToPageEnd", keyFunc_selectToPageEnd, "选中到页面末尾", "select", "none", true, true),
        ActionDefinition("keyFunc_selectCurrentWord", keyFunc_selectCurrentWord, "选中当前词", "select", "none", true, true),
        ActionDefinition("keyFunc_selectCurrentLine", keyFunc_selectCurrentLine, "选中当前行", "select", "none", true, true),
        ActionDefinition("keyFunc_selectWordLeft", keyFunc_selectWordLeft, "按词向左选中", "select", "count", true, true),
        ActionDefinition("keyFunc_selectWordRight", keyFunc_selectWordRight, "按词向右选中", "select", "count", true, true),
        ActionDefinition("keyFunc_pageMoveLineUp", keyFunc_pageMoveLineUp, "按行向上翻页", "other", "count", true, true),
        ActionDefinition("keyFunc_pageMoveLineDown", keyFunc_pageMoveLineDown, "按行向下翻页", "other", "count", true, true),
        ActionDefinition("keyFunc_tabHotString", keyFunc_tabHotString, "执行 Tab 替换", "tools", "none", true, true),
        ActionDefinition("keyFunc_openCpasDocs", keyFunc_openCpasDocs, "打开使用介绍", "tools", "none", true, true),
        ActionDefinition("keyFunc_mediaPrev", keyFunc_mediaPrev, "上一首媒体", "other", "none", true, true),
        ActionDefinition("keyFunc_mediaNext", keyFunc_mediaNext, "下一首媒体", "other", "none", true, true),
        ActionDefinition("keyFunc_mediaPlayPause", keyFunc_mediaPlayPause, "播放 / 暂停媒体", "other", "none", true, true),
        ActionDefinition("keyFunc_volumeUp", keyFunc_volumeUp, "增大音量", "other", "none", true, true),
        ActionDefinition("keyFunc_volumeDown", keyFunc_volumeDown, "减小音量", "other", "none", true, true),
        ActionDefinition("keyFunc_volumeMute", keyFunc_volumeMute, "静音", "other", "none", true, true),
        ActionDefinition("keyFunc_reload", keyFunc_reload, "重新加载配置", "tools", "none", true, true),
        ActionDefinition("keyFunc_openSettings", keyFunc_openSettings, "打开设置中心", "other", "none", true, true),
        ActionDefinition("keyFunc_send_dot", keyFunc_send_dot, "输入句点", "other", "none", false, false),
        ActionDefinition("keyFunc_qbar_upperFolderPath", keyFunc_qbar_upperFolderPath, "上一级文件夹", "tools", "none", false, false),
        ActionDefinition("keyFunc_qbar_lowerFolderPath", keyFunc_qbar_lowerFolderPath, "下一级文件夹", "tools", "none", false, false),
        ActionDefinition("keyFunc_winbind_activate", keyFunc_winbind_activate, "激活绑定窗口", "window", "binding", false, true),
        ActionDefinition("keyFunc_winbind_binding", keyFunc_winbind_binding, "绑定窗口 / 窗口组 / 应用", "window", "binding", false, true),
        ActionDefinition("keyFunc_winPin", keyFunc_winPin, "切换窗口置顶", "window", "none", true, true),
        ActionDefinition("keyFunc_goCjkPage", keyFunc_goCjkPage, "切换中日韩页面", "other", "none", true, true),
        ActionDefinition("keyFunc_click_left", keyFunc_click_left, "鼠标左键", "mouse", "none", true, true),
        ActionDefinition("keyFunc_click_right", keyFunc_click_right, "鼠标右键", "mouse", "none", true, true),
        ActionDefinition("keyFunc_mouse_up", keyFunc_mouse_up, "鼠标向上移动", "mouse", "none", true, true),
        ActionDefinition("keyFunc_mouse_down", keyFunc_mouse_down, "鼠标向下移动", "mouse", "none", true, true),
        ActionDefinition("keyFunc_mouse_left", keyFunc_mouse_left, "鼠标向左移动", "mouse", "none", true, true),
        ActionDefinition("keyFunc_mouse_right", keyFunc_mouse_right, "鼠标向右移动", "mouse", "none", true, true),
        ActionDefinition("keyFunc_wheel_up", keyFunc_wheel_up, "鼠标滚轮向上", "mouse", "none", true, true),
        ActionDefinition("keyFunc_wheel_down", keyFunc_wheel_down, "鼠标滚轮向下", "mouse", "none", true, true),
        ActionDefinition("keyFunc_clearWinMinimizeStach", keyFunc_clearWinMinimizeStach, "清空最小化窗口记录", "other", "none", false, false),
        ActionDefinition("keyFunc_popWinMinimizeStack", keyFunc_popWinMinimizeStack, "恢复最近最小化窗口", "other", "none", false, false),
        ActionDefinition("keyFunc_pushWinMinimizeStack", keyFunc_pushWinMinimizeStack, "记录最小化窗口", "other", "none", false, false),
        ActionDefinition("keyFunc_unshiftWinMinimizeStack", keyFunc_unshiftWinMinimizeStack, "恢复最早最小化窗口", "other", "none", false, false),
        ActionDefinition("keyFunc_winTransparent", keyFunc_winTransparent, "切换窗口透明度", "window", "none", true, true)
    ]
        catalog[action["id"]] := action
    return catalog
}

ActionCatalogSnapshot() {
    result := []
    for id, action in ActionCatalog()
        if action["listed"]
            result.Push(Map("id", id, "label", action["label"], "group", action["group"],
                "arguments", action["arguments"], "customHotkey", action["custom"]
                    ? "@builtin:shortcut/" . id : ""))
    return result
}

ActionArgumentsValid(actionKey, args) {
    catalog := ActionCatalog()
    if !catalog.Has(actionKey)
        return false
    switch catalog[actionKey]["arguments"] {
        case "count", "binding":
            if !args.Length
                return catalog[actionKey]["arguments"] = "count"
            if args.Length != 1 || !RegExMatch(Trim(args[1]), "^\d+$")
                return false
            try argumentNumber := Integer(args[1])
            catch
                return false
            maximum := catalog[actionKey]["arguments"] = "binding" ? 10 : 10000
            return argumentNumber >= 1 && argumentNumber <= maximum
        case "text":
            return args.Length = 1
        case "pair":
            return args.Length >= 1 && args.Length <= 2
        default:
            return args.Length = 0
    }
}
