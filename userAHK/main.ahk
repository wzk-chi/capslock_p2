; User extension point for the AHK v2 build.
; Custom functions referenced by [Keys] must start with keyFunc_.

keyFunc_example1(*) {
    MsgBox("example1")
}

keyFunc_example2(*) {
    MsgBox("example2")
}

