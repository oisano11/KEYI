#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the concrete Objective-C InputMethodKit controller class. Calling
/// this before IMKServer is created also keeps the class linked even though
/// InputMethodKit only discovers it through Info.plist.
FOUNDATION_EXPORT Class KeyiInputControllerClass(void);

/// Column name used for the InputMethodKit connection that this input method
/// serves. Kept next to the controller so the plist value has one source.
FOUNDATION_EXPORT NSString *KeyiInputMethodConnectionName(void);

/// Bundle identifier of the KEYI input method, distinct from the KEYI
/// translation assistant so both can be installed side by side.
FOUNDATION_EXPORT NSString *KeyiInputMethodBundleIdentifier(void);

/// Primary input mode identifier for the simplified Chinese Pinyin mode.
FOUNDATION_EXPORT NSString *KeyiInputMethodPrimaryModeIdentifier(void);

NS_ASSUME_NONNULL_END
