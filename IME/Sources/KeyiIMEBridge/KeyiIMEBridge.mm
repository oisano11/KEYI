#import "KeyiIMEBridge.h"

#include <memory>
#include <string>

#include "KeyiIMECore/RimeEngine.hpp"

namespace {

NSString *ToNSString(const std::string& value) {
  return [[NSString alloc] initWithBytes:value.data()
                                  length:value.size()
                                encoding:NSUTF8StringEncoding] ?: @"";
}

/// Converts librime's UTF-8 byte offset into the UTF-16 offset a client's
/// marked-text selection uses. The prefix is really decoded (rather than
/// counted) so multi-byte scalars and surrogate pairs stay correct.
NSInteger UTF16OffsetForUTF8Prefix(const std::string& text,
                                   std::size_t byte_offset) {
  if (byte_offset == 0) {
    return 0;
  }
  std::size_t limit = MIN(byte_offset, text.size());
  // A byte offset that lands inside a scalar cannot be decoded; step back to
  // the start of that scalar so the prefix stays valid UTF-8.
  while (limit > 0 &&
         (static_cast<unsigned char>(text[limit]) & 0xC0) == 0x80) {
    --limit;
  }
  if (limit == 0) {
    return 0;
  }
  NSString *prefix = [[NSString alloc] initWithBytes:text.data()
                                              length:limit
                                            encoding:NSUTF8StringEncoding];
  if (prefix == nil) {
    return static_cast<NSInteger>(limit);
  }
  return static_cast<NSInteger>(prefix.length);
}

}  // namespace

extern "C" NSInteger KeyiUTF16OffsetForUTF8Prefix(NSString *preedit,
                                              NSInteger byteOffset) {
  if (preedit == nil || byteOffset <= 0) {
    return 0;
  }
  const std::string text(preedit.UTF8String ?: "");
  return UTF16OffsetForUTF8Prefix(
      text, static_cast<std::size_t>(byteOffset));
}

@interface KeyiRimeResult ()

@property(nonatomic, readwrite) BOOL handled;
@property(nonatomic, copy, readwrite) NSString *preedit;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *candidates;
@property(nonatomic, copy, readwrite, nullable) NSString *commitText;
@property(nonatomic, readwrite) NSInteger highlightedCandidateIndex;
@property(nonatomic, readwrite) NSInteger cursorPosition;

@end


@implementation KeyiRimeResult

+ (instancetype)diagnosticResultWithHandled:(BOOL)handled
                                    preedit:(NSString *)preedit
                                 candidates:(NSArray<NSString *> *)candidates
                                 commitText:(NSString *)commitText
                   highlightedCandidateIndex:(NSInteger)highlightedCandidateIndex
                             cursorPosition:(NSInteger)cursorPosition {
  KeyiRimeResult *result = [[KeyiRimeResult alloc] init];
  result.handled = handled;
  result.preedit = preedit ?: @"";
  result.candidates = candidates ?: @[];
  result.commitText = commitText;
  result.highlightedCandidateIndex = highlightedCandidateIndex;
  result.cursorPosition = cursorPosition;
  return result;
}

@end

static KeyiRimeResult *BridgeResult(const keyi::RimeResult& result) {
  KeyiRimeResult *bridged = [[KeyiRimeResult alloc] init];
  bridged.handled = result.handled;
  bridged.preedit = ToNSString(result.preedit);

  NSMutableArray<NSString *> *candidates =
      [NSMutableArray arrayWithCapacity:result.candidates.size()];
  for (const std::string& candidate : result.candidates) {
    [candidates addObject:ToNSString(candidate)];
  }
  bridged.candidates = candidates;
  if (result.commit.has_value()) {
    bridged.commitText = ToNSString(*result.commit);
  }
  bridged.highlightedCandidateIndex = result.highlighted_candidate_index;
  if (!result.has_cursor) {
    bridged.cursorPosition = NSNotFound;
  } else {
    const NSInteger utf16Length = static_cast<NSInteger>(bridged.preedit.length);
    bridged.cursorPosition = MIN(
        UTF16OffsetForUTF8Prefix(result.preedit, result.cursor_byte_offset),
        utf16Length);
  }
  return bridged;
}

static KeyiRimeResult *EmptyResult(void) {
  return BridgeResult(keyi::RimeResult());
}


@implementation KeyiRimeSession {
  std::unique_ptr<keyi::RimeEngine> _engine;
}

- (instancetype)initWithSharedDataPath:(NSString *)sharedDataPath
                          userDataPath:(NSString *)userDataPath
                      schemaIdentifier:(NSString *)schemaIdentifier {
  self = [super init];
  if (self) {
    _engine = std::make_unique<keyi::RimeEngine>(
        sharedDataPath.UTF8String ?: "",
        userDataPath.UTF8String ?: "",
        schemaIdentifier.UTF8String ?: "keyi_pinyin");
  }
  return self;
}

- (BOOL)ready {
  return _engine && _engine->ready();
}

- (NSString *)errorMessage {
  return _engine ? ToNSString(_engine->error_message())
                 : @"Rime is unavailable";
}

- (NSString *)version {
  return _engine ? ToNSString(_engine->version()) : @"";
}

- (NSString *)rawInput {
  return _engine ? ToNSString(_engine->RawInput()) : @"";
}

- (void)setCandidatePageSize:(NSInteger)pageSize {
  if (_engine) {
    _engine->SetCandidatePageSize(static_cast<int>(pageSize));
  }
}

- (KeyiRimeResult *)processKey:(NSInteger)keyCode
                     modifiers:(NSUInteger)modifiers {
  if (!_engine) {
    return EmptyResult();
  }
  return BridgeResult(_engine->ProcessKey(static_cast<int>(keyCode),
                                          static_cast<int>(modifiers)));
}

- (KeyiRimeResult *)changeCandidatePageBackward:(BOOL)backward {
  return _engine ? BridgeResult(_engine->ChangeCandidatePage(backward))
                 : EmptyResult();
}

- (KeyiRimeResult *)selectVisibleCandidateAtIndex:(NSInteger)index {
  return _engine
             ? BridgeResult(_engine->SelectVisibleCandidate(
                   static_cast<int>(index)))
             : EmptyResult();
}

- (KeyiRimeResult *)moveCandidateHighlight:(NSInteger)delta {
  return _engine
             ? BridgeResult(
                   _engine->MoveCandidateHighlight(static_cast<int>(delta)))
             : EmptyResult();
}

- (KeyiRimeResult *)selectHighlightedCandidate {
  return _engine ? BridgeResult(_engine->SelectHighlightedCandidate())
                 : EmptyResult();
}

- (KeyiRimeResult *)commitComposition {
  return _engine ? BridgeResult(_engine->CommitComposition()) : EmptyResult();
}

- (void)clear {
  if (_engine) {
    _engine->Clear();
  }
}

+ (BOOL)resetUserDictionaryNamed:(NSString *)dictionaryName
                  sharedDataPath:(NSString *)sharedDataPath
                    userDataPath:(NSString *)userDataPath {
  return keyi::RimeEngine::ResetUserDictionary(
      sharedDataPath.UTF8String, userDataPath.UTF8String,
      dictionaryName.UTF8String);
}

+ (BOOL)redeployWithSharedDataPath:(NSString *)sharedDataPath
                       userDataPath:(NSString *)userDataPath {
  return keyi::RimeEngine::Redeploy(sharedDataPath.UTF8String,
                                    userDataPath.UTF8String);
}

+ (NSInteger)exportUserDictionaryNamed:(NSString *)dictionaryName
                          userDataPath:(NSString *)userDataPath
                                toFile:(NSString *)textFile {
  return keyi::RimeEngine::ExportUserDictionary(
      userDataPath.UTF8String, dictionaryName.UTF8String, textFile.UTF8String);
}

@end
