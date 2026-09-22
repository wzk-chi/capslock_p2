; capslock_p2 Tab calculation and Math Board.

global MathBoardGui := 0
global MathBoardEdit := 0
global MathBoardOpen := false

class ExpressionParser {
    __New(expression) {
        this.expression := expression
        this.position := 1
        this.length := StrLen(expression)
    }

    Parse() {
        value := this.ParseExpression()
        this.SkipSpaces()
        if this.position <= this.length
            throw Error("Unexpected token at position " . this.position)
        return value
    }

    ParseExpression() {
        value := this.ParseTerm()
        Loop {
            this.SkipSpaces()
            if this.Match("+")
                value += this.ParseTerm()
            else if this.Match("-")
                value -= this.ParseTerm()
            else
                break
        }
        return value
    }

    ParseTerm() {
        value := this.ParseUnary()
        Loop {
            this.SkipSpaces()
            if this.Match("*") {
                value *= this.ParseUnary()
            } else if this.Match("/") {
                divisor := this.ParseUnary()
                if divisor = 0
                    throw Error("Division by zero")
                value /= divisor
            } else if this.Match("%") {
                divisor := this.ParseUnary()
                if divisor = 0
                    throw Error("Modulo by zero")
                value := Mod(value, divisor)
            } else {
                break
            }
        }
        return value
    }

    ParseUnary() {
        this.SkipSpaces()
        if this.Match("+")
            return this.ParseUnary()
        if this.Match("-")
            return -this.ParseUnary()
        return this.ParsePower()
    }

    ParsePower() {
        value := this.ParsePrimary()
        this.SkipSpaces()
        if this.Match("^")
            value := value ** this.ParseUnary()
        return value
    }

    ParsePrimary() {
        this.SkipSpaces()
        if this.Match("(") {
            value := this.ParseExpression()
            this.SkipSpaces()
            if !this.Match(")")
                throw Error("Missing closing parenthesis")
            return value
        }

        remaining := SubStr(this.expression, this.position)
        if RegExMatch(remaining, "^(0[xX][0-9A-Fa-f]+|0[bB][01]+|\$[bBxX]?[0-9A-Fa-f]+|(?:\d+\.?(?:\d*)?|\.\d+)(?:[eE][+-]?\d+)?)", &numberMatch) {
            raw := numberMatch[0]
            this.position += StrLen(raw)
            return ParseNumberToken(raw)
        }

        if RegExMatch(remaining, "^[A-Za-z_][A-Za-z0-9_]*", &nameMatch) {
            name := nameMatch[0]
            this.position += StrLen(name)
            this.SkipSpaces()
            if this.Match("(") {
                args := []
                this.SkipSpaces()
                if !this.Match(")") {
                    Loop {
                        args.Push(this.ParseExpression())
                        this.SkipSpaces()
                        if this.Match(")")
                            break
                        if !this.Match(",")
                            throw Error("Missing function argument separator")
                    }
                }
                return EvaluateMathFunction(name, args)
            }
            switch StrLower(name) {
                case "pi":
                    return 3.141592653589793
                case "e":
                    return 2.718281828459045
                case "ln2":
                    return 0.6931471805599453
                case "ln10":
                    return 2.302585092994046
                case "sqrt1_2":
                    return 0.7071067811865476
                case "sqrt2":
                    return 1.4142135623730951
                default:
                    throw Error("Unknown identifier: " . name)
            }
        }

        throw Error("Expected a number or parenthesis")
    }

    SkipSpaces() {
        while this.position <= this.length && InStr(" `t`r`n", SubStr(this.expression, this.position, 1))
            this.position += 1
    }

    Match(token) {
        if SubStr(this.expression, this.position, StrLen(token)) = token {
            this.position += StrLen(token)
            return true
        }
        return false
    }
}

ParseNumberToken(token) {
    if SubStr(token, 1, 1) = "$" {
        prefix := StrLower(SubStr(token, 2, 1))
        digits := prefix = "b" || prefix = "x" ? SubStr(token, 3) : SubStr(token, 2)
        return prefix = "b" ? Integer("0b" . digits) : Integer("0x" . digits)
    }
    if SubStr(token, 1, 2) = "0x" || SubStr(token, 1, 2) = "0X"
        return Integer(token)
    if SubStr(token, 1, 2) = "0b" || SubStr(token, 1, 2) = "0B"
        return Integer(token)
    return token + 0
}

EvaluateMathFunction(name, args) {
    switch StrLower(name) {
        case "abs":
            RequireMathArguments(name, args, 1)
            return Abs(args[1])
        case "acos":
            RequireMathArguments(name, args, 1)
            return ACos(args[1])
        case "asin":
            RequireMathArguments(name, args, 1)
            return ASin(args[1])
        case "atan":
            RequireMathArguments(name, args, 1)
            return ATan(args[1])
        case "atan2":
            RequireMathArguments(name, args, 2)
            return EvaluateAtan2(args[1], args[2])
        case "ceil":
            RequireMathArguments(name, args, 1)
            return Ceil(args[1])
        case "cos":
            RequireMathArguments(name, args, 1)
            return Cos(args[1])
        case "exp":
            RequireMathArguments(name, args, 1)
            return Exp(args[1])
        case "floor":
            RequireMathArguments(name, args, 1)
            return Floor(args[1])
        case "log":
            RequireMathArguments(name, args, 1)
            return Log(args[1])
        case "max":
            if !args.Length
                throw Error("max requires an argument")
            return Max(args*)
        case "min":
            if !args.Length
                throw Error("min requires an argument")
            return Min(args*)
        case "pow":
            RequireMathArguments(name, args, 2)
            return args[1] ** args[2]
        case "random":
            if args.Length = 0
                return Random()
            if args.Length = 1
                return Random(args[1])
            RequireMathArguments(name, args, 2)
            return Random(args[1], args[2])
        case "round":
            if args.Length = 1
                return Round(args[1])
            RequireMathArguments(name, args, 2)
            return Round(args[1], args[2])
        case "sin":
            RequireMathArguments(name, args, 1)
            return Sin(args[1])
        case "sqrt":
            RequireMathArguments(name, args, 1)
            return Sqrt(args[1])
        case "tan":
            RequireMathArguments(name, args, 1)
            return Tan(args[1])
        default:
            throw Error("Unknown function: " . name)
    }
}

EvaluateAtan2(y, x) {
    pi := 3.141592653589793
    halfPi := pi / 2
    if x > 0
        return ATan(y / x)
    if x < 0 {
        angle := ATan(y / x)
        return y >= 0 ? angle + pi : angle - pi
    }
    if y > 0
        return halfPi
    if y < 0
        return -halfPi
    return 0
}

RequireMathArguments(name, args, count) {
    if args.Length != count
        throw Error(name . " expects " . count . " argument(s)")
}

NormalizeCalculationResult(value) {
    if value = ""
        return ""
    if !IsNumber(value)
        return value
    rounded := Round(value, 12)
    formatted := Format("{:.12f}", rounded)
    formatted := RegExReplace(formatted, "0+$", "")
    formatted := RegExReplace(formatted, "\.$", "")
    return formatted = "-0" ? "0" : formatted
}

EvaluateExpression(expression, &success := false) {
    global JavaScriptRuntimeReady
    success := false
    expression := Trim(expression)
    if expression = ""
        return ""

    if GetGlobalSetting("javascriptOriginalReturn", "0") = "1" && JavaScriptRuntimeReady {
        javascriptResult := EvaluateJavaScript(expression, &javascriptSuccess)
        if javascriptSuccess {
            success := true
            return javascriptResult
        }
    }

    try {
        parser := ExpressionParser(expression)
        value := parser.Parse()
    } catch {
        if JavaScriptRuntimeReady {
            javascriptResult := EvaluateJavaScript(expression, &javascriptSuccess)
            if javascriptSuccess {
                success := true
                return NormalizeCalculationResult(javascriptResult)
            }
        }
        return ""
    }
    success := true
    return NormalizeCalculationResult(value)
}

clCalculate(inputText, &result, autoMatch := false, isScratch := false) {
    result := "?"
    source := inputText
    candidate := Trim(inputText, " `t`r`n")
    hadEquals := false
    prefix := ""

    if autoMatch {
        found := false
        length := StrLen(candidate)
        Loop length {
            start := A_Index
            possible := Trim(SubStr(candidate, start))
            equalsHere := SubStr(possible, -1) = "="
            if equalsHere
                possible := Trim(SubStr(possible, 1, StrLen(possible) - 1))
            evaluated := EvaluateExpression(possible, &ok)
            if ok {
                candidate := possible
                result := evaluated
                prefix := start > 1 ? SubStr(source, 1, start - 1) : ""
                hadEquals := equalsHere
                found := true
                break
            }
        }
        if !found {
            result := "?"
            return inputText
        }
    } else {
        hadEquals := SubStr(candidate, -1) = "="
        if hadEquals
            candidate := Trim(SubStr(candidate, 1, StrLen(candidate) - 1))
        result := EvaluateExpression(candidate, &ok)
        if !ok
            return inputText
    }

    if isScratch || hadEquals
        return prefix . candidate . "=" . result
    return prefix . result
}

tabAction() {
    global A_Clipboard, ClipboardWatcherSuspended
    oldClipboard := ClipboardAll()
    selectedText := GetSelectedText()
    replacement := ""

    if selectedText != "" {
        replacement := GetHotStringReplacement(selectedText, &matched)
        if matched = "" {
            scriptText := strSelected2Script(selectedText)
            replacement := clCalculate(scriptText, &calculationResult, scriptText = selectedText, false)
        }
        if replacement != selectedText
            SetClipboardText(replacement)
    } else {
        ClipboardWatcherSuspended := true
        try {
            A_Clipboard := ""
            SendInput("+{Home}")
            Sleep(10)
            SendInput("^{Insert}")
            if ClipWait(0.15) {
                lineText := A_Clipboard
                replacement := GetHotStringReplacement(lineText, &matched)
                if matched = ""
                    replacement := clCalculate(lineText, &calculationResult, true, false)
                if replacement != lineText {
                    A_Clipboard := replacement
                    SendInput("^v")
                    Sleep(60)
                }
            }
        } finally {
            ClipboardWatcherSuspended := false
        }
    }
    A_Clipboard := oldClipboard
    return replacement
}

keyFunc_mathBoard() {
    global MathBoardGui, MathBoardEdit, MathBoardOpen
    selectedText := GetSelectedText()
    fitSize := ScreenFitSize(600, 400, 600, 220)
    if !IsObject(MathBoardGui) {
        MathBoardGui := Gui("+AlwaysOnTop +Resize +MinSize600x220", "Math Board")
        MathBoardGui.SetFont("s12", "Consolas")
        MathBoardEdit := MathBoardGui.AddEdit("x0 y0 w" . fitSize[1] . " h" . fitSize[2] . " -Wrap", selectedText)
        MathBoardGui.OnEvent("Close", MathBoardClose)
        MathBoardGui.OnEvent("Escape", MathBoardClose)
        MathBoardGui.OnEvent("Size", MathBoardSize)
    } else {
        MathBoardEdit.Value := selectedText
    }
    MathBoardOpen := true
    MathBoardGui.Show("w" . fitSize[1] . " h" . fitSize[2])
    MathBoardEdit.Focus()
    SendInput("{End}")
}

MathBoardClose(*) {
    global MathBoardGui, MathBoardOpen
    MathBoardOpen := false
    if IsObject(MathBoardGui)
        MathBoardGui.Hide()
}

MathBoardSize(targetGui, minMax, width, height) {
    global MathBoardEdit
    if IsObject(MathBoardEdit)
        MathBoardEdit.Move(0, 0, Max(100, width - 4), Max(80, height - 4))
}

MathBoardEnter(*) {
    global A_Clipboard, ClipboardWatcherSuspended
    if GetKeyState("Ctrl", "P") {
        SendInput("{Enter}")
        return
    }

    oldClipboard := ClipboardAll()
    ClipboardWatcherSuspended := true
    try {
        A_Clipboard := ""
        SendInput("+{Home}")
        Sleep(10)
        SendInput("^{Insert}")
        if ClipWait(0.15) {
            lineText := A_Clipboard
            replacement := GetHotStringReplacement(lineText, &matched)
            if matched = ""
                replacement := clCalculate(lineText, &calculationResult, true, true)
            if replacement != lineText && replacement != "?" {
                A_Clipboard := replacement
                SendInput("^v")
                Sleep(60)
            }
            SendInput("{End}{Enter}")
        }
    } finally {
        A_Clipboard := oldClipboard
        ClipboardWatcherSuspended := false
    }
}

RegisterMathBoardHotkeys() {
    global MathBoardOpen
    HotIf((*) => MathBoardOpen)
    Hotkey("Enter", MathBoardEnter)
    Hotkey("NumpadEnter", MathBoardEnter)
    HotIf()
}
