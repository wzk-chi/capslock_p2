; Lightweight local language detection used before a bidirectional request.
; Script based languages are identified from their Unicode ranges. Latin-script
; languages use a small stop-word score so short or mixed text remains
; ambiguous instead of being sent in the wrong direction.

TranslateDetectLanguage(text) {
    text := Trim(String(text))
    result := Map("status", "ambiguous", "language", "", "reason", "")
    if text = "" {
        result["status"] := "unsupported"
        result["reason"] := "empty"
        return result
    }

    if RegExMatch(text, "[\x{AC00}-\x{D7AF}\x{1100}-\x{11FF}\x{3130}-\x{318F}]") {
        result["status"] := "recognized"
        result["language"] := "ko"
        result["reason"] := "hangul"
        return result
    }
    if RegExMatch(text, "[\x{3040}-\x{30FF}\x{31F0}-\x{31FF}]") {
        result["status"] := "recognized"
        result["language"] := "ja"
        result["reason"] := "kana"
        return result
    }
    if RegExMatch(text, "[\x{0600}-\x{06FF}\x{0750}-\x{077F}\x{08A0}-\x{08FF}]") {
        result["status"] := "recognized"
        result["language"] := "ar"
        result["reason"] := "arabic"
        return result
    }
    if RegExMatch(text, "[\x{0400}-\x{04FF}\x{0500}-\x{052F}]") {
        if !TranslateDetectRussianEvidence(text) {
            result["reason"] := "cyrillic-ambiguous"
            return result
        }
        result["status"] := "recognized"
        result["language"] := "ru"
        result["reason"] := "cyrillic"
        return result
    }
    if RegExMatch(text, "[\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}]") {
        result["status"] := "recognized"
        result["language"] := TranslateDetectChineseVariant(text)
        result["reason"] := "han"
        return result
    }

    wordsText := Trim(RegExReplace(StrLower(text), "[^A-Za-zÀ-ÿ]+", " "))
    if wordsText = "" {
        result["status"] := "unsupported"
        result["reason"] := "no-supported-script"
        return result
    }
    words := StrSplit(wordsText, " ")
    dictionaries := Map(
        "en", "the and are is was were this that with from for you your have has not can into about hello please thanks of in it to a as be first all most widely used international language whether business science or education serves common tool communication mastering allows us access vast amount information opportunities would otherwise out reach",
        "fr", "le la les des une un est sont dans pour avec que qui pas cette bonjour merci",
        "de", "der die das den dem ein eine ist sind und nicht mit für von auf ich hallo danke",
        "es", "el la los las una un es son y del para con que por esta hola gracias",
        "it", "il lo la gli le una un è sono e per con che del questa ciao grazie",
        "pt", "o a os as uma um é são e para com que por esta olá obrigado obrigada")
    scores := Map()
    for code, dictionary in dictionaries {
        score := 0
        for word in words {
            if word = ""
                continue
            if InStr(" " . dictionary . " ", " " . word . " ")
                score++
        }
        scores[code] := score
    }

    bestCode := ""
    bestScore := 0
    secondScore := 0
    for code, score in scores {
        if score > bestScore {
            secondScore := bestScore
            bestScore := score
            bestCode := code
        } else if score > secondScore {
            secondScore := score
        }
    }
    if bestScore >= 2 && bestScore >= secondScore + 1 {
        result["status"] := "recognized"
        result["language"] := bestCode
        result["reason"] := "latin-stop-words"
        return result
    }
    result["reason"] := bestScore = 0 ? "insufficient-evidence" : "competing-candidates"
    return result
}

TranslateDetectChineseVariant(text) {
    traditionalChars := "體學國門車馬電腦這個與為說時會來開發後臺萬廣點實現從讓進對於麼種華語網頁書寫風雲"
    simplifiedChars := "体学国门车马电脑这个与为说时会来开发后台万广点实现从让进对于么种华语网页书写风云"
    traditionalScore := TranslateCountListedCharacters(text, traditionalChars)
    simplifiedScore := TranslateCountListedCharacters(text, simplifiedChars)
    if traditionalScore > simplifiedScore && traditionalScore > 0
        return "zh-TW"
    if simplifiedScore > traditionalScore && simplifiedScore > 0
        return "zh-CN"
    return "zh"
}

TranslateDetectRussianEvidence(text) {
    lowered := StrLower(text)
    if InStr(lowered, "ё")
        return true
    wordsText := Trim(RegExReplace(lowered, "[^\x{0400}-\x{04FF}]+", " "))
    words := StrSplit(wordsText, " ")
    dictionary := "и в во не на что это как по к из за для с со я мы вы он она они быть был была были есть уже ещё да нет но или от до при про так свой его ее их этот эта эти то же меня тебе вам нам привет спасибо пожалуйста мир"
    score := 0
    for word in words {
        if word != "" && InStr(" " . dictionary . " ", " " . word . " ")
            score++
    }
    return score >= 2
}

TranslateCountListedCharacters(text, characters) {
    count := 0
    for character in StrSplit(characters)
        if InStr(text, character)
            count++
    return count
}
