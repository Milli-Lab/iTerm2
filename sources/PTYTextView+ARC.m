//
//  PTYTextView+ARC.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 4/15/19.
//

#import "PTYTextView+ARC.h"

#import "DebugLogging.h"
#import "FileTransferManager.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermController.h"
#import "iTermImageInfo.h"
#import "iTermLaunchServices.h"
#import "iTermLocalHostNameGuesser.h"
#import "iTermMouseCursor.h"
#import "iTermPreferences.h"
#import "iTermTextExtractor.h"
#import "iTermURLActionFactory.h"
#import "iTermURLStore.h"
#import "iTermWebViewWrapperViewController.h"
#import "NSColor+iTerm.h"
#import "NSDictionary+iTerm.h"
#import "NSObject+iTerm.h"
#import "NSURL+iTerm.h"
#import "PTYTextView+Private.h"
#import "SCPPath.h"
#import "URLAction.h"
#import "VT100Terminal.h"

#import <WebKit/WebKit.h>

static const NSUInteger kDragPaneModifiers = (NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagShift);
static const NSUInteger kRectangularSelectionModifiers = (NSEventModifierFlagCommand | NSEventModifierFlagOption);
static const NSUInteger kRectangularSelectionModifierMask = (kRectangularSelectionModifiers | NSEventModifierFlagControl);

@implementation PTYTextView (ARC)

#pragma mark - Attributes

- (NSColor *)selectionBackgroundColor {
    CGFloat alpha = [self useTransparency] ? 1 - self.transparency : 1;
    return [[self.colorMap processedBackgroundColorForBackgroundColor:[self.colorMap colorForKey:kColorMapSelection]] colorWithAlphaComponent:alpha];
}

- (NSColor *)selectedTextColor {
    return [self.colorMap processedTextColorForTextColor:[self.colorMap colorForKey:kColorMapSelectedText]
                                     overBackgroundColor:[self selectionBackgroundColor]
                                  disableMinimumContrast:NO];
}

#pragma mark - Coordinate Space Conversions

- (NSPoint)clickPoint:(NSEvent *)event allowRightMarginOverflow:(BOOL)allowRightMarginOverflow {
    NSPoint locationInWindow = [event locationInWindow];
    return [self windowLocationToRowCol:locationInWindow
               allowRightMarginOverflow:allowRightMarginOverflow];
}

// TODO: this should return a VT100GridCoord but it confusingly returns an NSPoint.
//
// If allowRightMarginOverflow is YES then the returned value's x coordinate may be equal to
// dataSource.width. If NO, then it will always be less than dataSource.width.
- (NSPoint)windowLocationToRowCol:(NSPoint)locationInWindow
         allowRightMarginOverflow:(BOOL)allowRightMarginOverflow {
    NSPoint locationInTextView = [self convertPoint:locationInWindow fromView: nil];

    VT100GridCoord coord = [self coordForPoint:locationInTextView allowRightMarginOverflow:allowRightMarginOverflow];
    return NSMakePoint(coord.x, coord.y);
}

- (VT100GridCoord)coordForPoint:(NSPoint)locationInTextView
       allowRightMarginOverflow:(BOOL)allowRightMarginOverflow {
    int x, y;
    int width = [self.dataSource width];

    x = (locationInTextView.x - [iTermAdvancedSettingsModel terminalMargin] + self.charWidth * [iTermAdvancedSettingsModel fractionOfCharacterSelectingNextNeighbor]) / self.charWidth;
    if (x < 0) {
        x = 0;
    }
    y = locationInTextView.y / self.lineHeight;

    int limit;
    if (allowRightMarginOverflow) {
        limit = width;
    } else {
        limit = width - 1;
    }
    x = MIN(x, limit);
    y = MIN(y, [self.dataSource numberOfLines] - 1);

    return VT100GridCoordMake(x, y);
}

// Returns VT100GridCoordInvalid if event not on any cell
- (VT100GridCoord)coordForEvent:(NSEvent *)event {
    const NSPoint screenPoint = [NSEvent mouseLocation];
    return [self coordForMouseLocation:screenPoint];
}

- (VT100GridCoord)coordForMouseLocation:(NSPoint)screenPoint {
    const NSRect windowRect = [[self window] convertRectFromScreen:NSMakeRect(screenPoint.x,
                                                                              screenPoint.y,
                                                                              0,
                                                                              0)];
    const NSPoint locationInTextView = [self convertPoint:windowRect.origin fromView: nil];
    if (!NSPointInRect(locationInTextView, [self bounds])) {
        return VT100GridCoordInvalid;
    }

    NSPoint viewPoint = [self windowLocationToRowCol:windowRect.origin allowRightMarginOverflow:NO];
    return VT100GridCoordMake(viewPoint.x, viewPoint.y);
}

- (NSPoint)pointForCoord:(VT100GridCoord)coord {
    return NSMakePoint([iTermAdvancedSettingsModel terminalMargin] + coord.x * self.charWidth,
                       coord.y * self.lineHeight);
}

- (VT100GridCoord)coordForPointInWindow:(NSPoint)point {
    // TODO: Merge this function with windowLocationToRowCol.
    NSPoint p = [self windowLocationToRowCol:point allowRightMarginOverflow:NO];
    return VT100GridCoordMake(p.x, p.y);
}

#pragma mark - Query Coordinates

- (iTermImageInfo *)imageInfoAtCoord:(VT100GridCoord)coord {
    if (coord.x < 0 ||
        coord.y < 0 ||
        coord.x >= [self.dataSource width] ||
        coord.y >= [self.dataSource numberOfLines]) {
        return nil;
    }
    screen_char_t* theLine = [self.dataSource getLineAtIndex:coord.y];
    if (theLine && theLine[coord.x].image) {
        return GetImageInfo(theLine[coord.x].code);
    } else {
        return nil;
    }
}

#pragma mark - URL Actions

- (BOOL)ignoreHardNewlinesInURLs {
    if ([iTermAdvancedSettingsModel ignoreHardNewlinesInURLs]) {
        return YES;
    }
    return [self.delegate textViewInInteractiveApplication];
}

- (void)computeURLActionForCoord:(VT100GridCoord)coord
                      completion:(void (^)(URLAction *))completion {
    [self urlActionForClickAtX:coord.x
                             y:coord.y
        respectingHardNewlines:![self ignoreHardNewlinesInURLs]
                    completion:completion];
}

- (URLAction *)urlActionForClickAtX:(int)x y:(int)y {
    // I tried respecting hard newlines if that is a legal URL, but that's such a broad definition
    // that it doesn't work well. Hard EOLs mid-url are very common. Let's try always ignoring them.
    __block URLAction *action = nil;
    [self urlActionForClickAtX:x
                             y:y
        respectingHardNewlines:![self ignoreHardNewlinesInURLs]
                    completion:^(URLAction *result) {
                        action = result;
                    }];
    return action;
}

- (void)urlActionForClickAtX:(int)x
                           y:(int)y
      respectingHardNewlines:(BOOL)respectHardNewlines
                  completion:(void (^)(URLAction *))completion {
    DLog(@"urlActionForClickAt:%@,%@ respectingHardNewlines:%@",
         @(x), @(y), @(respectHardNewlines));
    if (y < 0) {
        completion(nil);
        return;
    }
    const VT100GridCoord coord = VT100GridCoordMake(x, y);
    iTermImageInfo *imageInfo = [self imageInfoAtCoord:coord];
    if (imageInfo) {
        completion([URLAction urlActionToOpenImage:imageInfo]);
        return;
    }
    iTermTextExtractor *extractor = [iTermTextExtractor textExtractorWithDataSource:self.dataSource];
    if ([extractor characterAt:coord].code == 0) {
        completion(nil);
        return;
    }
    [extractor restrictToLogicalWindowIncludingCoord:coord];

    NSString *workingDirectory = [self.dataSource workingDirectoryOnLine:y];
    DLog(@"According to data source, the working directory on line %d is %@", y, workingDirectory);
    if (!workingDirectory) {
        // Well, just try the current directory then.
        DLog(@"That failed, so try to get the current working directory...");
        workingDirectory = [self.delegate textViewCurrentWorkingDirectory];
        DLog(@"It is %@", workingDirectory);
    }

    [iTermURLActionFactory urlActionAtCoord:VT100GridCoordMake(x, y)
                        respectHardNewlines:respectHardNewlines
                           workingDirectory:workingDirectory ?: @""
                                 remoteHost:[self.dataSource remoteHostOnLine:y]
                                  selectors:[self smartSelectionActionSelectorDictionary]
                                      rules:self.smartSelectionRules
                                  extractor:extractor
                  semanticHistoryController:self.semanticHistoryController
                                pathFactory:^SCPPath *(NSString *path, int line) {
                                    return [self.dataSource scpPathForFile:path onLine:line];
                                }
                                 completion:completion];
}

- (void)openTargetWithEvent:(NSEvent *)event inBackground:(BOOL)openInBackground {
    // Command click in place.
    NSPoint clickPoint = [self clickPoint:event allowRightMarginOverflow:NO];
    const VT100GridCoord coord = VT100GridCoordMake(clickPoint.x, clickPoint.y);
    __weak __typeof(self) weakSelf = self;
    NSInteger generation = ++_openTargetGeneration;
    DLog(@"Look up URL action for coord %@, generation %@", VT100GridCoordDescription(coord), @(generation));
    [self computeURLActionForCoord:coord
                        completion:^(URLAction *action) {
                            [weakSelf finishOpeningTargetWithEvent:event
                                                             coord:coord
                                                      inBackground:openInBackground
                                                            action:action
                                                        generation:generation];
                        }];
}

- (void)finishOpeningTargetWithEvent:(NSEvent *)event
                               coord:(VT100GridCoord)coord
                        inBackground:(BOOL)openInBackground
                              action:(URLAction *)action
                          generation:(NSInteger)generation {
    if (generation != _openTargetGeneration) {
        DLog(@"Canceled open target for generation %@", @(generation));
        return;
    }

    iTermTextExtractor *extractor = [iTermTextExtractor textExtractorWithDataSource:self.dataSource];
    DLog(@"openTargetWithEvent generation %@ has action=%@", @(generation), action);
    if (action) {
        switch (action.actionType) {
            case kURLActionOpenExistingFile: {
                NSString *extendedPrefix = [extractor wrappedStringAt:coord
                                                              forward:NO
                                                  respectHardNewlines:![self ignoreHardNewlinesInURLs]
                                                             maxChars:[iTermAdvancedSettingsModel maxSemanticHistoryPrefixOrSuffix]
                                                    continuationChars:nil
                                                  convertNullsToSpace:YES
                                                               coords:nil];
                NSString *extendedSuffix = [extractor wrappedStringAt:coord
                                                              forward:YES
                                                  respectHardNewlines:![self ignoreHardNewlinesInURLs]
                                                             maxChars:[iTermAdvancedSettingsModel maxSemanticHistoryPrefixOrSuffix]
                                                    continuationChars:nil
                                                  convertNullsToSpace:YES
                                                               coords:nil];
                if (![self openSemanticHistoryPath:action.fullPath
                                     orRawFilename:action.rawFilename
                                  workingDirectory:action.workingDirectory
                                        lineNumber:action.lineNumber
                                      columnNumber:action.columnNumber
                                            prefix:extendedPrefix
                                            suffix:extendedSuffix]) {
                    [self findUrlInString:action.string andOpenInBackground:openInBackground];
                }
                break;
            }
            case kURLActionOpenURL: {
                NSURL *url = [NSURL URLWithUserSuppliedString:action.string];
                if ([url.scheme isEqualToString:@"file"] &&
                    url.host.length > 0 &&
                    ![url.host isEqualToString:[[iTermLocalHostNameGuesser sharedInstance] name]]) {
                    SCPPath *path = [[SCPPath alloc] init];
                    path.path = url.path;
                    path.hostname = url.host;
                    path.username = [PTYTextView usernameToDownloadFileOnHost:url.host];
                    if (path.username == nil) {
                        return;
                    }
                    [self downloadFileAtSecureCopyPath:path
                                           displayName:url.path.lastPathComponent
                                        locationInView:action.range.coordRange];
                } else {
                    [self openURL:url inBackground:openInBackground];
                }
                break;
            }

            case kURLActionSmartSelectionAction: {
                DLog(@"Run smart selection selector %@", NSStringFromSelector(action.selector));
                [self it_performNonObjectReturningSelector:action.selector withObject:action];
                break;
            }

            case kURLActionOpenImage:
                DLog(@"Open image");
                [[NSWorkspace sharedWorkspace] openFile:[(iTermImageInfo *)action.identifier nameForNewSavedTempFile]];
                break;

            case kURLActionSecureCopyFile:
                DLog(@"Secure copy file.");
                [self downloadFileAtSecureCopyPath:action.identifier
                                       displayName:action.string
                                    locationInView:action.range.coordRange];
                break;
        }
    }
}

- (void)findUrlInString:(NSString *)aURLString andOpenInBackground:(BOOL)background {
    DLog(@"findUrlInString:%@", aURLString);
    NSRange range = [aURLString rangeOfURLInString];
    if (range.location == NSNotFound) {
        DLog(@"No URL found");
        return;
    }
    NSString *trimmedURLString = [aURLString substringWithRange:range];
    if (!trimmedURLString) {
        DLog(@"string is empty");
        return;
    }
    NSString* escapedString = [trimmedURLString stringByEscapingForURL];

    NSURL *url = [NSURL URLWithString:escapedString];
    [self openURL:url inBackground:background];
}

#pragma mark Secure Copy

+ (NSString *)usernameToDownloadFileOnHost:(NSString *)host {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Enter username for host %@ to download file with scp", host];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    [input setStringValue:NSUserName()];
    [alert setAccessoryView:input];
    [alert layout];
    [[alert window] makeFirstResponder:input];
    NSInteger button = [alert runModal];
    if (button == NSAlertFirstButtonReturn) {
        [input validateEditing];
        return [[input stringValue] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    }
    return nil;
}

- (void)downloadFileAtSecureCopyPath:(SCPPath *)scpPath
                         displayName:(NSString *)name
                      locationInView:(VT100GridCoordRange)range {
    [self.delegate startDownloadOverSCP:scpPath];

    NSDictionary *attributes =
    @{ NSForegroundColorAttributeName: [self selectedTextColor],
       NSBackgroundColorAttributeName: [self selectionBackgroundColor],
       NSFontAttributeName: self.primaryFont.font };
    NSSize size = [name sizeWithAttributes:attributes];
    size.height = self.lineHeight;
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];
    [name drawAtPoint:NSMakePoint(0, 0) withAttributes:attributes];
    [image unlockFocus];

    NSRect windowRect = [self convertRect:NSMakeRect(range.start.x * self.charWidth + [iTermAdvancedSettingsModel terminalMargin],
                                                     range.start.y * self.lineHeight,
                                                     0,
                                                     0)
                                   toView:nil];
    NSPoint point = [[self window] convertRectToScreen:windowRect].origin;
    point.y -= self.lineHeight;
    [[FileTransferManager sharedInstance] animateImage:image
                            intoDownloadsMenuFromPoint:point
                                              onScreen:[[self window] screen]];
}

#pragma mark - Open URL

// If iTerm2 is the handler for the scheme, then the profile is launched directly.
// Otherwise it's passed to the OS to launch.
- (void)openURL:(NSURL *)url inBackground:(BOOL)background {
    DLog(@"openURL:%@ inBackground:%@", url, @(background));

    Profile *profile = [[iTermLaunchServices sharedInstance] profileForScheme:[url scheme]];
    if (profile) {
        [self.delegate launchProfileInCurrentTerminal:profile withURL:url.absoluteString];
    } else if (background) {
        [[NSWorkspace sharedWorkspace] openURLs:@[ url ]
                        withAppBundleIdentifier:nil
                                        options:NSWorkspaceLaunchWithoutActivation
                 additionalEventParamDescriptor:nil
                              launchIdentifiers:nil];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

#pragma mark - Semantic History

- (void)handleSemanticHistoryItemDragWithEvent:(NSEvent *)event
                                         coord:(VT100GridCoord)coord {
    DLog(@"do semantic history check");
    // Only one Semantic History check per drag
    _semanticHistoryDragged = YES;

    // Drag a file handle (only possible when there is no selection).
    [self computeURLActionForCoord:coord completion:^(URLAction *action) {
        [self finishHandlingSemanticHistoryItemDragWithEvent:event action:action];
    }];
}

- (void)finishHandlingSemanticHistoryItemDragWithEvent:(NSEvent *)event
                                                action:(URLAction *)action {
    if (!_semanticHistoryDragged) {
        return;
    }
    const VT100GridCoord coord = [self coordForMouseLocation:[NSEvent mouseLocation]];
    if (!VT100GridWindowedRangeContainsCoord(action.range, coord)) {
        return;
    }
    NSString *path = action.fullPath;
    if (path == nil) {
        DLog(@"path is nil");
        return;
    }

    NSPoint dragPosition;
    NSImage *dragImage;

    dragImage = [[NSWorkspace sharedWorkspace] iconForFile:path];
    dragPosition = [self convertPoint:[event locationInWindow] fromView:nil];
    dragPosition.x -= [dragImage size].width / 2;

    NSURL *url = [NSURL fileURLWithPath:path];

    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setString:[url absoluteString] forType:(NSString *)kUTTypeFileURL];
    NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];
    [dragItem setDraggingFrame:NSMakeRect(dragPosition.x, dragPosition.y, dragImage.size.width, dragImage.size.height)
                      contents:dragImage];
    NSDraggingSession *draggingSession = [self beginDraggingSessionWithItems:@[ dragItem ]
                                                                       event:event
                                                                      source:self];

    draggingSession.animatesToStartingPositionsOnCancelOrFail = YES;
    draggingSession.draggingFormation = NSDraggingFormationNone;
    _committedToDrag = YES;

    // Valid drag, so we reset the flag because mouseUp doesn't get called when a drag is done
    _semanticHistoryDragged = NO;
    DLog(@"did semantic history drag");
}

#pragma mark - Underlined Actions

// Update range of underlined chars indicating cmd-clickable url.
- (void)updateUnderlinedURLs:(NSEvent *)event {
    const BOOL commandPressed = ([event modifierFlags] & NSEventModifierFlagCommand) != 0;
    const BOOL semanticHistoryAllowed = (self.window.isKeyWindow ||
                                         [iTermAdvancedSettingsModel cmdClickWhenInactiveInvokesSemanticHistory]);
    const VT100GridCoord coord = [self coordForEvent:event];

    if (!commandPressed ||
        !semanticHistoryAllowed ||
        VT100GridCoordEquals(coord, VT100GridCoordInvalid) ||
        ![iTermPreferences boolForKey:kPreferenceKeyCmdClickOpensURLs] ||
        coord.y < 0) {
        [self removeUnderline];
        [self updateCursor:event action:nil];
        [self setNeedsDisplay:YES];
        return;
    }

    __weak __typeof(self) weakSelf = self;
    [self urlActionForClickAtX:coord.x
                             y:coord.y
        respectingHardNewlines:![self ignoreHardNewlinesInURLs]
                    completion:^(URLAction *result) {
                        [weakSelf finishUpdatingUnderlinesWithAction:result
                                                               event:event];
                    }];
}

- (void)finishUpdatingUnderlinesWithAction:(URLAction *)action
                                     event:(NSEvent *)event {
    if (!action) {
        [self removeUnderline];
        [self updateCursor:event action:action];
        return;
    }

    const VT100GridCoord coord = [self coordForMouseLocation:[NSEvent mouseLocation]];
    if (!VT100GridWindowedRangeContainsCoord(action.range, coord)) {
        return;
    }

    if ([iTermAdvancedSettingsModel enableUnderlineSemanticHistoryOnCmdHover]) {
        self.drawingHelper.underlinedRange = VT100GridAbsWindowedRangeFromRelative(action.range,
                                                                                   [self.dataSource totalScrollbackOverflow]);
    }

    [self setNeedsDisplay:YES];  // It would be better to just display the underlined/formerly underlined area.
    [self updateCursor:event action:action];
}

#pragma mark - Smart Selection

- (NSDictionary<NSNumber *, NSString *> *)smartSelectionActionSelectorDictionary {
    // The selector's name must begin with contextMenuAction to
    // pass validateMenuItem.
    return @{ @(kOpenFileContextMenuAction): NSStringFromSelector(@selector(contextMenuActionOpenFile:)),
              @(kOpenUrlContextMenuAction): NSStringFromSelector(@selector(contextMenuActionOpenURL:)),
              @(kRunCommandContextMenuAction): NSStringFromSelector(@selector(contextMenuActionRunCommand:)),
              @(kRunCoprocessContextMenuAction): NSStringFromSelector(@selector(contextMenuActionRunCoprocess:)),
              @(kSendTextContextMenuAction): NSStringFromSelector(@selector(contextMenuActionSendText:)),
              @(kRunCommandInWindowContextMenuAction): NSStringFromSelector(@selector(contextMenuActionRunCommandInWindow:)) };
}

#pragma mark - Context Menu Actions

- (void)contextMenuActionOpenFile:(id)sender {
    DLog(@"Open file: '%@'", [sender representedObject]);
    [[NSWorkspace sharedWorkspace] openFile:[[sender representedObject] stringByExpandingTildeInPath]];
}

- (void)contextMenuActionOpenURL:(id)sender {
    NSURL *url = [NSURL URLWithUserSuppliedString:[sender representedObject]];
    if (url) {
        DLog(@"Open URL: %@", [sender representedObject]);
        [[NSWorkspace sharedWorkspace] openURL:url];
    } else {
        DLog(@"%@ is not a URL", [sender representedObject]);
    }
}

- (void)contextMenuActionRunCommand:(id)sender {
    NSString *command = [sender representedObject];
    DLog(@"Run command: %@", command);
    [NSThread detachNewThreadSelector:@selector(runCommand:)
                             toTarget:[self class]
                           withObject:command];
}

- (void)contextMenuActionRunCommandInWindow:(id)sender {
    NSString *command = [sender representedObject];
    DLog(@"Run command in window: %@", command);
    [[iTermController sharedInstance] openSingleUseWindowWithCommand:command];
}

+ (void)runCommand:(NSString *)command {
    @autoreleasepool {
        system([command UTF8String]);
    }
}

- (void)contextMenuActionRunCoprocess:(id)sender {
    NSString *command = [sender representedObject];
    DLog(@"Run coprocess: %@", command);
    [self.delegate launchCoprocessWithCommand:command];
}

- (void)contextMenuActionSendText:(id)sender {
    NSString *command = [sender representedObject];
    DLog(@"Send text: %@", command);
    [self.delegate insertText:command];
}

#pragma mark - Mouse Cursor

- (void)updateCursor:(NSEvent *)event action:(URLAction *)action {
    NSString *hover = nil;
    BOOL changed = NO;
    if (([event modifierFlags] & kDragPaneModifiers) == kDragPaneModifiers) {
        changed = [self setCursor:[NSCursor openHandCursor]];
    } else if (([event modifierFlags] & kRectangularSelectionModifierMask) == kRectangularSelectionModifiers) {
        changed = [self setCursor:[NSCursor crosshairCursor]];
    } else if (action &&
               ([event modifierFlags] & (NSEventModifierFlagOption | NSEventModifierFlagCommand)) == NSEventModifierFlagCommand) {
        changed = [self setCursor:[NSCursor pointingHandCursor]];
        if (action.hover && action.string.length) {
            hover = action.string;
        }
    } else if ([self mouseIsOverImageInEvent:event]) {
        changed = [self setCursor:[NSCursor arrowCursor]];
    } else if ([self xtermMouseReporting] &&
               [self terminalWantsMouseReports]) {
        changed = [self setCursor:[iTermMouseCursor mouseCursorOfType:iTermMouseCursorTypeIBeamWithCircle]];
    } else {
        changed = [self setCursor:[iTermMouseCursor mouseCursorOfType:iTermMouseCursorTypeIBeam]];
    }
    if (changed) {
        [self.enclosingScrollView setDocumentCursor:cursor_];
    }
    [self.delegate textViewShowHoverURL:hover];
}

- (BOOL)setCursor:(NSCursor *)cursor {
    if (cursor == cursor_) {
        return NO;
    }
    cursor_ = cursor;
    return YES;
}

- (BOOL)mouseIsOverImageInEvent:(NSEvent *)event {
    NSPoint point = [self clickPoint:event allowRightMarginOverflow:NO];
    return [self imageInfoAtCoord:VT100GridCoordMake(point.x, point.y)] != nil;
}

#pragma mark - Mouse Reporting

// WARNING: This indicates if mouse reporting is a possibility. -terminalWantsMouseReports indicates
// if the reporting mode would cause any action to be taken if this returns YES. They should be used
// in conjunction most of the time.
- (BOOL)xtermMouseReporting {
    NSEvent *event = [NSApp currentEvent];
    return (([[self delegate] xtermMouseReporting]) &&        // Xterm mouse reporting is on
            !([event modifierFlags] & NSEventModifierFlagOption));   // Not holding Opt to disable mouse reporting
}

- (BOOL)xtermMouseReportingAllowMouseWheel {
    return [[self delegate] xtermMouseReportingAllowMouseWheel];
}

// If mouse reports are sent to the delegate, will it use them? Use with -xtermMouseReporting, which
// understands Option to turn off reporting.
- (BOOL)terminalWantsMouseReports {
    MouseMode mouseMode = [[self.dataSource terminal] mouseMode];
    return ([self.delegate xtermMouseReporting] &&
            mouseMode != MOUSE_REPORTING_NONE &&
            mouseMode != MOUSE_REPORTING_HIGHLIGHT);
}

#pragma mark - Quicklook

- (void)handleQuickLookWithEvent:(NSEvent *)event {
    DLog(@"Quick look with event %@\n%@", event, [NSThread callStackSymbols]);
    const NSPoint clickPoint = [self clickPoint:event allowRightMarginOverflow:YES];
    const VT100GridCoord coord = VT100GridCoordMake(clickPoint.x, clickPoint.y);
    [self computeURLActionForCoord:coord completion:^(URLAction *action) {
        [self finishHandlingQuickLookWithEvent:event action:action];
    }];
}

- (void)finishHandlingQuickLookWithEvent:(NSEvent *)event
                                  action:(URLAction *)urlAction {
    if (!urlAction && [iTermAdvancedSettingsModel performDictionaryLookupOnQuickLook]) {
        NSPoint clickPoint = [self clickPoint:event allowRightMarginOverflow:YES];
        [self showDefinitionForWordAt:clickPoint];
        return;
    }
    const VT100GridCoord coord = [self coordForMouseLocation:[NSEvent mouseLocation]];
    if (!VT100GridWindowedRangeContainsCoord(urlAction.range, coord)) {
        return;
    }
    NSURL *url = nil;
    switch (urlAction.actionType) {
        case kURLActionSecureCopyFile:
            url = [urlAction.identifier URL];
            break;

        case kURLActionOpenExistingFile:
            url = [NSURL fileURLWithPath:urlAction.fullPath];
            break;

        case kURLActionOpenImage:
            url = [NSURL fileURLWithPath:[urlAction.identifier nameForNewSavedTempFile]];
            break;

        case kURLActionOpenURL: {
            if (!urlAction.string) {
                break;
            }
            url = [NSURL URLWithUserSuppliedString:urlAction.string];
            if (url && [self showWebkitPopoverAtPoint:event.locationInWindow url:url]) {
                return;
            }
            break;
        }

        case kURLActionSmartSelectionAction:
            break;
    }

    if (url) {
        NSPoint windowPoint = event.locationInWindow;
        NSRect windowRect = NSMakeRect(windowPoint.x - self.charWidth / 2,
                                       windowPoint.y - self.lineHeight / 2,
                                       self.charWidth,
                                       self.lineHeight);

        NSRect screenRect = [self.window convertRectToScreen:windowRect];
        self.quickLookController = [[iTermQuickLookController alloc] init];
        [self.quickLookController addURL:url];
        [self.quickLookController showWithSourceRect:screenRect controller:self.window.delegate];
    }
}

- (void)showDefinitionForWordAt:(NSPoint)clickPoint {
    if (clickPoint.y < 0) {
        return;
    }
    iTermTextExtractor *extractor = [iTermTextExtractor textExtractorWithDataSource:self.dataSource];
    VT100GridWindowedRange range =
    [extractor rangeForWordAt:VT100GridCoordMake(clickPoint.x, clickPoint.y)
                maximumLength:kReasonableMaximumWordLength];
    NSAttributedString *word = [extractor contentInRange:range
                                       attributeProvider:^NSDictionary *(screen_char_t theChar) {
                                           return [self charAttributes:theChar];
                                       }
                                              nullPolicy:kiTermTextExtractorNullPolicyMidlineAsSpaceIgnoreTerminal
                                                     pad:NO
                                      includeLastNewline:NO
                                  trimTrailingWhitespace:YES
                                            cappedAtSize:self.dataSource.width
                                            truncateTail:YES
                                       continuationChars:nil
                                                  coords:nil];
    if (word.length) {
        NSPoint point = [self pointForCoord:range.coordRange.start];
        point.y += self.lineHeight;
        NSDictionary *attributes = [word attributesAtIndex:0 effectiveRange:nil];
        if (attributes[NSFontAttributeName]) {
            NSFont *font = attributes[NSFontAttributeName];
            point.y += font.descender;
        }
        [self showDefinitionForAttributedString:word
                                        atPoint:point];
    }
}

- (BOOL)showWebkitPopoverAtPoint:(NSPoint)pointInWindow url:(NSURL *)url {
    WKWebView *webView = [[iTermWebViewFactory sharedInstance] webViewWithDelegate:nil];
    if (webView) {
        if ([[url.scheme lowercaseString] isEqualToString:@"http"]) {
            [webView loadHTMLString:@"This site cannot be displayed in QuickLook because of Application Transport Security. Only HTTPS URLs can be previewed." baseURL:nil];
        } else {
            NSURLRequest *request = [[NSURLRequest alloc] initWithURL:url];
            [webView loadRequest:request];
        }
        NSPopover *popover = [[NSPopover alloc] init];
        NSViewController *viewController = [[iTermWebViewWrapperViewController alloc] initWithWebView:webView
                                                                                            backupURL:url];
        popover.contentViewController = viewController;
        popover.contentSize = viewController.view.frame.size;
        NSRect rect = NSMakeRect(pointInWindow.x - self.charWidth / 2,
                                 pointInWindow.y - self.lineHeight / 2,
                                 self.charWidth,
                                 self.lineHeight);
        rect = [self convertRect:rect fromView:nil];
        popover.behavior = NSPopoverBehaviorSemitransient;
        popover.delegate = self;
        [popover showRelativeToRect:rect
                             ofView:self
                      preferredEdge:NSRectEdgeMinY];
        return YES;
    } else {
        return NO;
    }
}

#pragma mark - Copy to Pasteboard

// Returns a dictionary to pass to NSAttributedString.
- (NSDictionary *)charAttributes:(screen_char_t)c {
    BOOL isBold = c.bold;
    BOOL isFaint = c.faint;
    NSColor *fgColor = [self colorForCode:c.foregroundColor
                                    green:c.fgGreen
                                     blue:c.fgBlue
                                colorMode:c.foregroundColorMode
                                     bold:isBold
                                    faint:isFaint
                             isBackground:NO];
    NSColor *bgColor = [self colorForCode:c.backgroundColor
                                    green:c.bgGreen
                                     blue:c.bgBlue
                                colorMode:c.backgroundColorMode
                                     bold:NO
                                    faint:NO
                             isBackground:YES];
    fgColor = [fgColor colorByPremultiplyingAlphaWithColor:bgColor];

    int underlineStyle = (c.urlCode || c.underline) ? (NSUnderlineStyleSingle | NSUnderlineByWord) : 0;

    BOOL isItalic = c.italic;
    PTYFontInfo *fontInfo = [self getFontForChar:c.code
                                       isComplex:c.complexChar
                                      renderBold:&isBold
                                    renderItalic:&isItalic];
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineBreakMode = NSLineBreakByCharWrapping;

    NSFont *font = fontInfo.font;
    if (!font) {
        // Ordinarily fontInfo would never be nil, but it is in unit tests. It's useful to distinguish
        // bold from regular in tests, so we ensure that attribute is correctly set in this test-only
        // path.
        const CGFloat size = [NSFont systemFontSize];
        if (c.bold) {
            font = [NSFont boldSystemFontOfSize:size];
        } else {
            font = [NSFont systemFontOfSize:size];
        }
    }
    NSDictionary *attributes = @{ NSForegroundColorAttributeName: fgColor,
                                  NSBackgroundColorAttributeName: bgColor,
                                  NSFontAttributeName: font,
                                  NSParagraphStyleAttributeName: paragraphStyle,
                                  NSUnderlineStyleAttributeName: @(underlineStyle) };
    if ([iTermAdvancedSettingsModel excludeBackgroundColorsFromCopiedStyle]) {
        attributes = [attributes dictionaryByRemovingObjectForKey:NSBackgroundColorAttributeName];
    }
    if (c.urlCode) {
        NSURL *url = [[iTermURLStore sharedInstance] urlForCode:c.urlCode];
        if (url != nil) {
            attributes = [attributes dictionaryBySettingObject:url forKey:NSLinkAttributeName];
        }
    }

    return attributes;
}

@end