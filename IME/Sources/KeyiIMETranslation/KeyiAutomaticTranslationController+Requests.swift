import Foundation
import KEYITranslationClient

// MARK: - 句子的转换请求

extension KeyiAutomaticTranslationController {
  /// 句末或回车：这一句进入等待，开始取译文（无汉字的原样上屏，超长的按失败处理，缓存命中直接到达）。
  func startConversionLocked(at index: Int, byEnter: Bool) {
    sentences[index].cancelWork()
    sentences[index].state = .waiting
    sentences[index].convertedByEnter = byEnter
    sentences[index].retryUsed = false
    let text = sentences[index].text
    if !KeyiAutomaticTranslationText.containsHan(text) {
      sentences[index].state = .arrived(text)
    } else if text.utf8.count > KeyiAutomaticTranslationText.maximumUTF8Bytes {
      keyiAutomaticNotice("sentence over limit utf8=\(text.utf8.count); no request")
      sentences[index].state = .failed
      sentences[index].failureKind = .tooLong
      sentences[index].chineseOnTurn = byEnter
    } else if let cached = cache[text] {
      keyiAutomaticNotice("sentence \(sentences[index].id) reused cached translation")
      sentences[index].state = .arrived(cached)
    } else {
      sendRequestLocked(at: index)
    }
  }

  func sendRequestLocked(at index: Int) {
    nextToken &+= 1
    let token = nextToken
    let sentenceID = sentences[index].id
    let text = sentences[index].text
    let request = TranslationServiceRequest(
      text: text,
      timeoutSeconds: Self.requestTimeoutSeconds,
      id: UUID().uuidString
    )
    sentences[index].token = token
    keyiAutomaticNotice("request sentence=\(sentenceID) utf16=\(KeyiAutomaticTranslationText.utf16Length(text))")
    sentences[index].task = translate(request) { [weak self] result in
      guard let self else { return }
      self.queue.async { self.receiveLocked(result, sentence: sentenceID, token: token) }
    }
    let timeoutError = TranslationServiceClientError.timeout(
      requestID: request.id,
      seconds: Self.requestTimeoutSeconds
    )
    sentences[index].timeout = scheduler.schedule(after: Self.requestTimeoutSeconds) { [weak self] in
      guard let self else { return }
      self.queue.async { self.receiveLocked(.failure(timeoutError), sentence: sentenceID, token: token) }
    }
  }

  func receiveLocked(_ result: Result<String, Error>, sentence sentenceID: UInt64, token: UInt64) {
    if settleForSecureInputLocked(outsideKeyEvent: true) {
      keyiAutomaticNotice("result dropped: secure input sentence=\(sentenceID)")
      return
    }
    guard let index = sentences.firstIndex(where: { $0.id == sentenceID }),
          sentences[index].token == token,
          sentences[index].state == .waiting else {
      keyiAutomaticNotice("late result dropped sentence=\(sentenceID)")
      return
    }
    sentences[index].cancelWork()
    switch translatedText(result) {
    case let .english(english):
      cacheLocked(english, for: sentences[index].text)
      if previewSource == sentences[index].text { cancelPreviewRequestLocked() }
      sentences[index].state = .arrived(english)
      keyiAutomaticNotice("sentence \(sentenceID) arrived utf16=\(KeyiAutomaticTranslationText.utf16Length(english))")
    case let .failed(kind):
      if kind == .serviceUnavailable, !sentences[index].retryUsed {
        sentences[index].retryUsed = true
        scheduleRetryLocked(at: index)
        onFailure(KeyiAutomaticTranslationFailure(kind: kind, willRetry: true))
      } else {
        sentences[index].state = .failed
        sentences[index].failureKind = kind
        keyiAutomaticNotice("sentence \(sentenceID) failed kind=\(kind)")
        onFailure(KeyiAutomaticTranslationFailure(kind: kind, willRetry: false))
      }
    }
    drainLocked()
    settleEnterLocked()
    flushLocked(verifyOwnership: true)
  }

  func scheduleRetryLocked(at index: Int) {
    nextToken &+= 1
    let token = nextToken
    let sentenceID = sentences[index].id
    sentences[index].token = token
    keyiAutomaticNotice("sentence \(sentenceID) retry in \(Self.serviceRetryDelay)s")
    sentences[index].retryTimer = scheduler.schedule(after: Self.serviceRetryDelay) { [weak self] in
      guard let self else { return }
      self.queue.async {
        if self.settleForSecureInputLocked(outsideKeyEvent: true) { return }
        guard let index = self.sentences.firstIndex(where: { $0.id == sentenceID }),
              self.sentences[index].token == token,
              self.sentences[index].state == .waiting else { return }
        self.sentences[index].retryTimer = nil
        self.sendRequestLocked(at: index)
      }
    }
  }

  enum Outcome {
    case english(String)
    case failed(KeyiAutomaticTranslationFailure.Kind)
  }

  func translatedText(_ result: Result<String, Error>) -> Outcome {
    switch result {
    case let .success(text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? .failed(.emptyResult) : .english(trimmed)
    case let .failure(error):
      return .failed(KeyiAutomaticTranslationFailure.kind(for: error))
    }
  }

  func cacheLocked(_ english: String, for source: String) {
    if cache.updateValue(english, forKey: source) == nil {
      cacheOrder.append(source)
    }
    while cacheOrder.count > Self.cacheCapacity {
      cache.removeValue(forKey: cacheOrder.removeFirst())
    }
  }
}
