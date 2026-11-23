#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Converts librime's UTF-8 byte offset into the UTF-16 offset a client's
/// marked-text selection uses. Exposed so the conversion can be asserted
/// directly against edge cases the live engine does not conveniently produce.
#ifdef __cplusplus
extern "C" {
#endif
NSInteger KeyiUTF16OffsetForUTF8Prefix(NSString *preedit, NSInteger byteOffset);
#ifdef __cplusplus
}
#endif

/// One candidate page returned by the Rime engine.
@interface KeyiRimeResult : NSObject

@property(nonatomic, readonly) BOOL handled;
@property(nonatomic, copy, readonly) NSString *preedit;
@property(nonatomic, copy, readonly) NSArray<NSString *> *candidates;
@property(nonatomic, copy, readonly, nullable) NSString *commitText;
@property(nonatomic, readonly) NSInteger highlightedCandidateIndex;
/// Caret offset inside the preedit, counted in UTF-16 units, or `NSNotFound`
/// when the snapshot carried no composition.
@property(nonatomic, readonly) NSInteger cursorPosition;
/// librime's commit_text_preview: the composition as it would be committed now
/// (highlighted candidate converted, the rest as typed). Empty without a
/// composition. Only the touch keyboard (iOS) draws it inline.
@property(nonatomic, copy, readonly) NSString *commitTextPreview;

/// Builds a result from explicit values. Only the diagnostics use this: the
/// real engine produces its snapshots from librime, but the session's
/// commit-and-remaining-preedit ordering must be covered by a controlled
/// snapshot because this schema never emits both at once in practice.
+ (instancetype)diagnosticResultWithHandled:(BOOL)handled
                                    preedit:(NSString *)preedit
                                 candidates:(NSArray<NSString *> *)candidates
                                 commitText:(nullable NSString *)commitText
                   highlightedCandidateIndex:(NSInteger)highlightedCandidateIndex
                             cursorPosition:(NSInteger)cursorPosition;

/// Swift-friendly wrapper for the same diagnostics-only constructor.
+ (instancetype)diagnosticResultWithHandled:(BOOL)handled
                                    preedit:(NSString *)preedit
                                 candidates:(NSArray<NSString *> *)candidates
                                 commitText:(nullable NSString *)commitText
                   highlightedCandidateIndex:(NSInteger)highlightedCandidateIndex
                             cursorPosition:(NSInteger)cursorPosition
    NS_SWIFT_NAME(diagnosticResult(withHandled:preedit:candidates:commitText:highlightedCandidateIndex:cursorPosition:));

@end

/// Owns a single Rime session. Session state never leaks between instances.
@interface KeyiRimeSession : NSObject

- (instancetype)initWithSharedDataPath:(NSString *)sharedDataPath
                          userDataPath:(NSString *)userDataPath
                      schemaIdentifier:(NSString *)schemaIdentifier;

@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, copy, readonly) NSString *errorMessage;
@property(nonatomic, copy, readonly) NSString *version;
@property(nonatomic, copy, readonly) NSString *rawInput;

- (void)setCandidatePageSize:(NSInteger)pageSize;
- (KeyiRimeResult *)processKey:(NSInteger)keyCode modifiers:(NSUInteger)modifiers;
/// Replaces the whole input (librime set_input), e.g. with a bare web address.
- (KeyiRimeResult *)setInput:(NSString *)input;
- (KeyiRimeResult *)changeCandidatePageBackward:(BOOL)backward;
- (KeyiRimeResult *)moveCandidateHighlight:(NSInteger)delta;
- (KeyiRimeResult *)selectVisibleCandidateAtIndex:(NSInteger)index;
/// Touch keyboards: the candidates after this page, `offset` counted from this
/// page's first candidate (the page size is the next page's first).
- (NSArray<NSString *> *)candidatesFromPageOffset:(NSInteger)offset
                                            limit:(NSInteger)limit
    NS_SWIFT_NAME(candidates(fromPageOffset:limit:));
/// Selects the candidate `index` places after this page's first, also past
/// the end of this page (a candidate swiped into view on a touch keyboard).
- (KeyiRimeResult *)selectCandidateFromPageAtIndex:(NSInteger)index
    NS_SWIFT_NAME(selectCandidateFromPage(at:));
- (KeyiRimeResult *)selectHighlightedCandidate;
/// Commits the composition as librime shows it: converted segments as Chinese,
/// letters it cannot convert as typed.
- (KeyiRimeResult *)commitComposition;
- (void)clear;

/// Empties the user dictionary inside the running input method. Every live
/// session starts over on its next key; the next commit recreates the db.
+ (BOOL)resetUserDictionaryNamed:(NSString *)dictionaryName
                  sharedDataPath:(NSString *)sharedDataPath
                    userDataPath:(NSString *)userDataPath;

/// Recompiles the dictionaries inside the running input method after the user
/// directory's table copies changed. Every live session starts over on its next key.
+ (BOOL)redeployWithSharedDataPath:(NSString *)sharedDataPath
                       userDataPath:(NSString *)userDataPath;

/// Exports a user dictionary as text and returns the entry count, or -1.
/// Only for a process without live sessions, pointed at a copy of the userdb.
+ (NSInteger)exportUserDictionaryNamed:(NSString *)dictionaryName
                          userDataPath:(NSString *)userDataPath
                                toFile:(NSString *)textFile;

@end

NS_ASSUME_NONNULL_END
