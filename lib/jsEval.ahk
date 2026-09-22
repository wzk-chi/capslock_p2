; Optional JavaScript extension support for the capslock_p2 Tab feature.
; The built-in expression parser remains the primary path. This compatibility
; layer keeps the original loadScript feature available when HTMLFile exists.

global JavaScriptRuntime := 0
global JavaScriptRuntimeReady := false

InitializeJavaScriptRuntime() {
    global JavaScriptRuntime, JavaScriptRuntimeReady
    JavaScriptRuntime := 0
    JavaScriptRuntimeReady := false

    scriptList := Trim(GetGlobalSetting("loadScript", ""))
    if scriptList = ""
        return

    try {
        JavaScriptRuntime := ComObject("HTMLFile")
        JavaScriptRuntime.write("<meta http-equiv='X-UA-Compatible' content='IE=11'>")
        JavaScriptRuntime.write(BuildJavaScriptPrelude())

        for scriptName in StrSplit(scriptList, ",") {
            scriptName := Trim(scriptName)
            if scriptName = ""
                continue
            scriptPath := A_ScriptDir . "\loadScript\" . scriptName
            if !FileExist(scriptPath)
                continue
            scriptText := FileRead(scriptPath, "UTF-8")
            JavaScriptRuntime.write("<script>" . scriptText . "</script>")
        }
        JavaScriptRuntimeReady := true
    } catch {
        JavaScriptRuntime := 0
        JavaScriptRuntimeReady := false
    }
}

BuildJavaScriptPrelude() {
    return "<script>"
        . "var funcArr=['abs','acos','asin','atan','atan2','ceil','cos','exp','floor','log','max','min','pow','random','round','sin','sqrt','tan'];"
        . "var consArr=['E','LN2','LN10','LOG2E','LOG10E','PI','SQRT1_2','SQRT2'];"
        . "for(var i=0;i<funcArr.length;i++){window[funcArr[i]]=Math[funcArr[i]];}"
        . "for(var j=0;j<consArr.length;j++){window[consArr[j]]=Math[consArr[j]];window[consArr[j].toLowerCase()]=Math[consArr[j]];}"
        . "function fixFloatCalcRudely(num){if(typeof num==='number'){var s=num.toString();if(s.length<18)return num;return Number(num.toPrecision(12));}return num;}"
        . "</script>"
}

EvaluateJavaScript(expression, &success := false) {
    global JavaScriptRuntime, JavaScriptRuntimeReady
    success := false
    if !JavaScriptRuntimeReady || !IsObject(JavaScriptRuntime)
        return ""

    escaped := EscapeJavaScriptString(expression)
    try {
        JavaScriptRuntime.write("<body><script>(function(){var t=document.body;t.innerText='';t.innerText=eval('" . escaped . "');})()</script></body>")
        result := JavaScriptRuntime.body.innerText
        if InStr(result, "body")
            return ""
        success := true
        return result
    } catch {
        return ""
    }
}

strSelected2Script(selectedText) {
    pattern := "\R[ \t]*\..+\(.*\)\s*$"
    matchPosition := RegExMatch(selectedText, pattern, &match)
    if !matchPosition
        return selectedText
    prefix := SubStr(selectedText, 1, matchPosition - 1)
    suffix := Trim(SubStr(selectedText, matchPosition))
    return "'" . EscapeJavaScriptString(prefix) . "'" . suffix
}

EscapeJavaScriptString(value) {
    value := StrReplace(value, Chr(96), Chr(96) . Chr(96))
    value := StrReplace(value, Chr(34), Chr(96) . Chr(34))
    value := StrReplace(value, "'", "\'")
    value := StrReplace(value, "\", "\\")
    value := StrReplace(value, "`r", "\r")
    value := StrReplace(value, "`n", "\n")
    value := StrReplace(value, "`t", "\t")
    return value
}
