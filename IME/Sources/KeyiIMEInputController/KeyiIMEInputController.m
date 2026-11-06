#import "KeyiIMEInputController.h"

#import <AppKit/AppKit.h>
#import <InputMethodKit/InputMethodKit.h>
#import <os/log.h>

// The bundle identifier must contain an `.inputmethod.` component that is not
// the final component, which is what macOS requires before it will register a
// third-party input method. `com.keyi.input-method` never appeared in any TIS
// enumeration; this form does.
static NSString *const kKeyiConnectionName =
    @"com.keyi.inputmethod.keyi_Connection";
static NSString *const kKeyiBundleIdentifier = @"com.keyi.inputmethod.keyi";
static NSString *const kKeyiPrimaryModeIdentifier =
    @"com.keyi.inputmethod.keyi.pinyin";

static os_log_t KeyiControllerLog(void) {
  static os_log_t log;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    log = os_log_create("com.keyi.inputmethod.keyi", "ObjCController");
  });
  return log;
}

/// The Swift side owns all engine and UI state. This controller exists only so
/// InputMethodKit, which allocates its controller from Info.plist, can drive an
/// Objective-C lifecycle while the session object stays plain Swift.
@protocol KeyiInputSessionHandling <NSObject>

- (void)keyiActivateWithClient:(nullable id)client;
- (void)keyiDeactivateWithClient:(nullable id)client;
- (void)keyiCommitWithClient:(nullable id)client;
- (NSUInteger)keyiRecognizedEventsForClient:(nullable id)client;
- (BOOL)keyiHandleEvent:(nullable NSEvent *)event client:(nullable id)client;
- (BOOL)keyiInputText:(nullable NSString *)text client:(nullable id)client;
- (BOOL)keyiInputText:(nullable NSString *)text
                  key:(NSInteger)keyCode
            modifiers:(NSUInteger)flags
               client:(nullable id)client;
- (BOOL)keyiCommandNamed:(NSString *)selectorName client:(nullable id)client;
- (void)keyiHidePalettes;
- (BOOL)keyiToggleAutomaticTranslation;
- (BOOL)keyiIsAutomaticTranslationEnabled;
- (void)keyiOpenTranslationSettings;
- (NSArray<NSString *> *)keyiTranslationStyleTitles;
- (NSArray<NSNumber *> *)keyiTranslationStyleGroups;
- (NSArray<NSString *> *)keyiTranslationStyleGroupTitles;
- (NSInteger)keyiSelectedTranslationStyleIndex;
- (void)keyiSelectTranslationStyleAtIndex:(NSInteger)index;

@end

@interface KeyiInputController : IMKInputController {
 @private
  id<KeyiInputSessionHandling> _inputSession;
  NSUInteger _observedKeyDownCount;
  BOOL _loggedFirstKeyDown;
  BOOL _loggedFirstFlagsChanged;
}
@end

@implementation KeyiInputController

- (instancetype)initWithServer:(IMKServer *)server
                       delegate:(id)delegate
                         client:(id)inputClient {
  self = [super initWithServer:server delegate:delegate client:inputClient];
  if (self) {
    Class sessionClass = NSClassFromString(@"KeyiInputSession");
    if (sessionClass == Nil) {
      os_log_fault(KeyiControllerLog(),
                   "Swift input session class is unavailable");
      [self release];
      return nil;
    }
    _inputSession = [[sessionClass alloc] init];
    if (_inputSession == nil) {
      os_log_fault(KeyiControllerLog(),
                   "Swift input session could not be initialized");
      [self release];
      return nil;
    }
    os_log_info(KeyiControllerLog(),
                "Objective-C input controller initialized");
    // A client can only reach this controller through the InputMethodKit
    // connection for the mode it selected. Logging the mode makes a routing
    // failure (keys never arrive, or arrive for the wrong mode) visible in the
    // system log instead of silently producing plain ASCII passthrough.
    os_log_info(KeyiControllerLog(),
                "controller mode=%{public}@",
                kKeyiPrimaryModeIdentifier);
  }
  return self;
}

- (void)dealloc {
  [_inputSession release];
  _inputSession = nil;
  [super dealloc];
}

- (id)effectiveClient:(id)sender {
  return sender != nil ? sender : [self client];
}

- (void)activateServer:(id)sender {
  [super activateServer:sender];
  os_log_info(KeyiControllerLog(), "activateServer called");
  [_inputSession keyiActivateWithClient:[self effectiveClient:sender]];
}

- (void)deactivateServer:(id)sender {
  os_log_info(KeyiControllerLog(), "deactivateServer called");
  [_inputSession keyiDeactivateWithClient:[self effectiveClient:sender]];
  [super deactivateServer:sender];
}

- (void)commitComposition:(id)sender {
  [_inputSession keyiCommitWithClient:[self effectiveClient:sender]];
  [super commitComposition:sender];
}

- (NSUInteger)recognizedEvents:(id)sender {
  if (_inputSession == nil) {
    return NSEventMaskKeyDown;
  }
  return [_inputSession
      keyiRecognizedEventsForClient:[self effectiveClient:sender]];
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)sender {
  BOOL handled = [_inputSession keyiHandleEvent:event
                                         client:[self effectiveClient:sender]];
  // Routing evidence only. This deliberately does not log characters and does
  // not log every key code: the first key proves the client reached us, and the
  // running count stays as a health signal without becoming a keystroke log.
  if (event.type == NSEventTypeFlagsChanged && !_loggedFirstFlagsChanged) {
    _loggedFirstFlagsChanged = YES;
    os_log_info(KeyiControllerLog(), "first flags changed received");
  }
  if (event.type == NSEventTypeKeyDown) {
    _observedKeyDownCount += 1;
    if (!_loggedFirstKeyDown) {
      _loggedFirstKeyDown = YES;
      os_log_info(KeyiControllerLog(),
                  "first key down received keyCode=%ld handled=%{public}s",
                  (long)event.keyCode,
                  handled ? "yes" : "no");
    } else if (_observedKeyDownCount % 100 == 0) {
      os_log_info(KeyiControllerLog(),
                  "key downs routed=%lu",
                  (unsigned long)_observedKeyDownCount);
    }
  }
  return handled;
}

// Only handleEvent:client: is implemented (IMKServerInput's "handle all events"
// approach, as Squirrel does). When a controller also implements
// inputText:key:modifiers:client: or inputText:client:, InputMethodKit delivers
// keys through those instead and never calls handleEvent:, so flagsChanged (the
// Shift tap) never arrives. Real-host logs of 10-31 showed exactly that: no
// "first key down received" line in any session.

- (void)hidePalettes {
  // InputMethodKit calls this when focus moves. Only the candidate panel is a
  // palette for KEYI, so the Swift session decides what to hide.
  [_inputSession keyiHidePalettes];
}

// Automatic translation is a product requirement of the KEYI input source:确认的
// 中文整段留在下划线里，回车换成英文上屏。本菜单项只做暂停/恢复，不改变
// recognizedEvents，也不给普通输入增加任何额外步骤。
- (NSMenu *)menu {
  NSMenu *menu = [[[NSMenu alloc] init] autorelease];

  // 必须在构建时读取当前值：IMK 每次弹菜单都会重新调用本方法。
  BOOL enabled = YES;
  if ([_inputSession respondsToSelector:@selector(keyiIsAutomaticTranslationEnabled)]) {
    enabled = [_inputSession keyiIsAutomaticTranslationEnabled];
  }
  NSMenuItem *automatic = [[[NSMenuItem alloc]
      initWithTitle:NSLocalizedStringFromTableInBundle(
                        @"自动翻译 ⌃⌥T",
                        nil,
                        [NSBundle bundleForClass:[self class]],
                        @"KEYI input method menu item")
             action:@selector(toggleAutomaticTranslation:)
      keyEquivalent:@""] autorelease];
  automatic.target = self;
  automatic.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
  [menu addItem:automatic];

  // 翻译风格直接列在这里，点一下就换；用哪个翻译引擎由 KEYI 可译按风格决定。
  // 分「本机翻译」「大模型 API」两组，组名里写此刻用的模型或服务名。
  if ([_inputSession respondsToSelector:@selector(keyiTranslationStyleTitles)]) {
    NSArray<NSString *> *titles = [_inputSession keyiTranslationStyleTitles];
    NSArray<NSNumber *> *groups = nil;
    NSArray<NSString *> *groupTitles = nil;
    if ([_inputSession respondsToSelector:@selector(keyiTranslationStyleGroups)] &&
        [_inputSession respondsToSelector:@selector(keyiTranslationStyleGroupTitles)]) {
      groups = [_inputSession keyiTranslationStyleGroups];
      groupTitles = [_inputSession keyiTranslationStyleGroupTitles];
    }
    NSInteger selected = [_inputSession keyiSelectedTranslationStyleIndex];
    NSInteger currentGroup = -1;
    for (NSInteger index = 0; index < (NSInteger)titles.count; index++) {
      NSInteger group = index < (NSInteger)groups.count ? groups[index].integerValue : 0;
      if (group != currentGroup) {
        currentGroup = group;
        [menu addItem:[NSMenuItem separatorItem]];
        NSString *groupTitle = group < (NSInteger)groupTitles.count
            ? groupTitles[group]
            : NSLocalizedStringFromTableInBundle(
                  @"翻译风格",
                  nil,
                  [NSBundle bundleForClass:[self class]],
                  @"KEYI input method menu section");
        NSMenuItem *header = [[[NSMenuItem alloc] initWithTitle:groupTitle
                                                         action:nil
                                                  keyEquivalent:@""] autorelease];
        header.enabled = NO;
        [menu addItem:header];
      }
      NSMenuItem *item = [[[NSMenuItem alloc]
          initWithTitle:titles[index]
                 action:@selector(selectTranslationStyle:)
          keyEquivalent:@""] autorelease];
      item.target = self;
      item.tag = index;
      item.indentationLevel = 1;
      item.state = index == selected ? NSControlStateValueOn : NSControlStateValueOff;
      [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
  }

  // 语言、服务和高级设置在 KEYI 可译里；从输入法菜单一步打开，不用再找菜单栏图标。
  NSMenuItem *settings = [[[NSMenuItem alloc]
      initWithTitle:NSLocalizedStringFromTableInBundle(
                        @"打开 KEYI 可译设置…",
                        nil,
                        [NSBundle bundleForClass:[self class]],
                        @"KEYI input method menu item")
             action:@selector(openTranslationSettings:)
      keyEquivalent:@""] autorelease];
  settings.target = self;
  [menu addItem:settings];

  return menu;
}

- (void)openTranslationSettings:(NSMenuItem *)sender {
  if ([_inputSession respondsToSelector:@selector(keyiOpenTranslationSettings)]) {
    [_inputSession keyiOpenTranslationSettings];
  }
}

// IMK 调菜单动作时，sender 不是菜单项本身，而是一个字典，菜单项在 kIMKCommandMenuItemName 下；
// 直接对 sender 取 tag 会抛异常、被 IMK 吞掉，点了没反应。
- (void)selectTranslationStyle:(id)sender {
  NSMenuItem *item = nil;
  if ([sender isKindOfClass:[NSMenuItem class]]) {
    item = sender;
  } else if ([sender isKindOfClass:[NSDictionary class]]) {
    id candidate = [(NSDictionary *)sender objectForKey:kIMKCommandMenuItemName];
    if ([candidate isKindOfClass:[NSMenuItem class]]) {
      item = candidate;
    }
  }
  if (item == nil ||
      ![_inputSession respondsToSelector:@selector(keyiSelectTranslationStyleAtIndex:)]) {
    return;
  }
  // 按标题找，菜单经 IMK 转发后 tag 也可能丢失。
  NSInteger index = item.tag;
  if ([_inputSession respondsToSelector:@selector(keyiTranslationStyleTitles)]) {
    NSUInteger found = [[_inputSession keyiTranslationStyleTitles] indexOfObject:item.title];
    if (found != NSNotFound) {
      index = (NSInteger)found;
    }
  }
  [_inputSession keyiSelectTranslationStyleAtIndex:index];
}

- (void)toggleAutomaticTranslation:(NSMenuItem *)sender {
  if ([_inputSession respondsToSelector:@selector(keyiToggleAutomaticTranslation)]) {
    [_inputSession keyiToggleAutomaticTranslation];
  }
}

@end

Class KeyiInputControllerClass(void) {
  return [KeyiInputController class];
}

NSString *KeyiInputMethodConnectionName(void) {
  return kKeyiConnectionName;
}

NSString *KeyiInputMethodBundleIdentifier(void) {
  return kKeyiBundleIdentifier;
}

NSString *KeyiInputMethodPrimaryModeIdentifier(void) {
  return kKeyiPrimaryModeIdentifier;
}
