//
//  main.swift
//  KEYI 拼音输入法 — 自动翻译控制器检查
//
//  直接驱动**生产** `KeyiAutomaticTranslationController`；`Harness` 扮演会话，
//  把控制器通过 `KeyiAutomaticTranslationSink` 给出的改动画到替身输入框上。
//  不需要翻译服务、不注册输入源、不写用户词库。
//

import Foundation

print("== KEYI automatic translation checks ==")

checkPinyinEnterAndNavigation()
checkHoldAndPreview()
checkPreviewCancelledByTyping()
checkLocalStylePreviewsImmediately()
checkDigitsAndEnglishJoin()
checkSentenceTerminators()
checkParagraphHold()
checkParagraphHintAfterFailure()
checkEnterConvertsThenPasses()
checkTypingDuringEnterWait()
checkFailureKeepsHeld()
checkServiceDownRetry()
checkBackspaceAfterEnglish()
checkCommitChineseTriggers()
checkLeavingCommitsReadyEnglish()
checkPlainPinyinModes()
checkCommitOrderAndStaleResults()
checkOwnershipMismatch()
checkLimitsSpacingAndCache()
checkCommandEnterSwallowed()
checkDirectPrefixWithCachedSentence()
checkOverlayHidesWhenHoldingEnds()
checkSecureInputTurnsOnWhileHeld()
checkSecureInputOtherKeysWhileHeld()
checkSecureInputRespectsOwnership()
checkTranslatedWordCount()
checkAppCandidateLearning()
checkDictionaryUpdate()

print("")
if failures.isEmpty {
    print("KEYI_AUTOMATIC_CHECKS=pass (\(passed) checks)")
    exit(EXIT_SUCCESS)
} else {
    print("KEYI_AUTOMATIC_CHECKS=fail")
    for failure in failures { print("  - \(failure)") }
    exit(EXIT_FAILURE)
}
