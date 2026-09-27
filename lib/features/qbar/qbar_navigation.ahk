; qbar folder navigation and path completion.

QbarUpperFolderPath() {
    global QbarVisible, QbarFutureStack, QbarFolderDir
    if !QbarVisible || QbarFolderDir = ""
        return false
    dir := QbarFolderDir
    parent := QbarParentFolder(dir)
    if parent = "" || parent = dir
        return false
    QbarFutureStack.Push(dir)
    QbarSetInput(parent)
    return true
}

QbarLowerFolderPath() {
    global QbarVisible, QbarFutureStack
    if !QbarVisible || !QbarFutureStack.Length
        return false
    QbarSetInput(QbarFutureStack.Pop())
    return true
}

QbarParentFolder(dir) {
    trimmed := RTrim(dir, "\")
    if RegExMatch(trimmed, "^.*\\", &match)
        return match[0]
    return trimmed . "\"
}

; ---------------------------------------------------------------------------
; Page language
; ---------------------------------------------------------------------------

QbarFolderOf(text) {
    if !RegExMatch(text, "i)^([a-zA-Z]:\\(?:[^\\]*\\)*)", &match)
        return ""
    dir := match[1]
    return DirExist(dir) ? dir : ""
}

QbarLeafOf(text) {
    return RegExMatch(text, "i)(?<=\\)[^\\]*$", &match) ? match[0] : ""
}
