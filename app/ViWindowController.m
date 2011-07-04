#import "ViWindowController.h"
#import "PSMTabBarControl.h"
#import "ViDocument.h"
#import "ViDocumentView.h"
#import "ViProject.h"
#import "ProjectDelegate.h"
#import "ViJumpList.h"
#import "ViThemeStore.h"
#import "ViBundleStore.h"
#import "ViDocumentController.h"
#import "ViPreferencesController.h"
#import "ViAppController.h"
#import "ViTextStorage.h"
#import "NSObject+SPInvocationGrabbing.h"
#import "ViLayoutManager.h"
#import "ExTextField.h"
#import "ViEventManager.h"
#import "NSURL-additions.h"
#import "ExCommand.h"

static NSMutableArray		*windowControllers = nil;
static ViWindowController	*currentWindowController = nil;

@interface ViWindowController ()
- (void)updateJumplistNavigator;
- (void)didSelectDocument:(ViDocument *)document;
- (void)didSelectViewController:(id<ViViewController>)viewController;
- (ViDocumentTabController *)selectedTabController;
- (void)closeDocumentView:(id<ViViewController>)viewController
	 canCloseDocument:(BOOL)canCloseDocument
	   canCloseWindow:(BOOL)canCloseWindow;
- (void)documentController:(NSDocumentController *)docController
	       didCloseAll:(BOOL)didCloseAll
	     tabController:(void *)tabController;
- (void)unlistDocument:(ViDocument *)document;
@end


#pragma mark -
@implementation ViWindowController

@synthesize documents;
@synthesize project;
@synthesize environment;
@synthesize explorer = projectDelegate;
@synthesize jumpList, jumping;
@synthesize tagStack, tagsDatabase;
@synthesize previousDocument;
@synthesize baseURL;
@synthesize symbolController;

+ (ViWindowController *)currentWindowController
{
	if (currentWindowController == nil)
		[[ViWindowController alloc] init];
	return currentWindowController;
}

+ (NSWindow *)currentMainWindow
{
	if (currentWindowController)
		return [currentWindowController window];
	else if ([windowControllers count] > 0)
		return [[windowControllers objectAtIndex:0] window];
	else
		return nil;
}

- (id)init
{
	self = [super initWithWindowNibName:@"ViDocumentWindow"];
	if (self) {
		isLoaded = NO;
		if (windowControllers == nil)
			windowControllers = [NSMutableArray array];
		[windowControllers addObject:self];
		currentWindowController = self;
		documents = [NSMutableArray array];
		jumpList = [[ViJumpList alloc] init];
		[jumpList setDelegate:self];
		parser = [[ViParser alloc] initWithDefaultMap:[ViMap normalMap]];
		tagStack = [[ViTagStack alloc] init];
		[self setBaseURL:[NSURL fileURLWithPath:NSHomeDirectory()]];
	}

	return self;
}

- (ViTagsDatabase *)tagsDatabase
{
	if (![[tagsDatabase baseURL] isEqualToURL:baseURL])
		tagsDatabase = nil;

	if (tagsDatabase == nil)
		tagsDatabase = [[ViTagsDatabase alloc] initWithBaseURL:baseURL];

	return tagsDatabase;
}

- (ViParser *)parser
{
	return parser;
}

- (void)getMoreBundles:(id)sender
{
	[[ViPreferencesController sharedPreferences] performSelector:@selector(showItem:)
                                                          withObject:@"Bundles"
                                                          afterDelay:0.01];
}

- (void)windowDidResize:(NSNotification *)notification
{
	[[self window] saveFrameUsingName:@"MainDocumentWindow"];
}

- (void)tearDownBundleMenu:(NSNotification *)notification
{
	NSMenu *menu = (NSMenu *)[notification object];

	/*
	 * Must remove the bundle menu items, otherwise the key equivalents
	 * remain active and interfere with the handling in textView.keyDown:.
	 */
	[menu removeAllItems];

	[[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSMenuDidEndTrackingNotification
                                                      object:menu];
}

- (void)setupBundleMenu:(NSNotification *)notification
{
	if (![[self currentView] isKindOfClass:[ViDocumentView class]])
		return;
	ViDocumentView *docView = [self currentView];
	ViTextView *textView = [docView textView];

	NSEvent *ev = [textView popUpContextEvent];
	NSMenu *menu = [textView menuForEvent:ev];
	/* Insert a dummy item at index 0 as the NSPopUpButton title. */
	[menu insertItemWithTitle:@"Action menu" action:NULL keyEquivalent:@"" atIndex:0];
	[menu update];
	[bundleButton setMenu:menu];

	[[NSNotificationCenter defaultCenter] addObserver:self
                                        selector:@selector(tearDownBundleMenu:)
                                            name:NSMenuDidEndTrackingNotification
                                          object:menu];
}

- (void)windowDidLoad
{
	[[NSNotificationCenter defaultCenter] addObserver:self
                                        selector:@selector(firstResponderChanged:)
                                            name:ViFirstResponderChangedNotification
                                          object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self
                                        selector:@selector(caretChanged:)
                                            name:ViCaretChangedNotification
                                          object:nil];

	[[[self window] toolbar] setShowsBaselineSeparator:NO];
	[bookmarksButtonCell setImage:[NSImage imageNamed:@"bookmark"]];

	[bundleButtonCell setImage:[NSImage imageNamed:@"actionmenu"]];
	[[NSNotificationCenter defaultCenter] addObserver:self
                                        selector:@selector(setupBundleMenu:)
                                            name:NSPopUpButtonWillPopUpNotification
                                          object:bundleButton];

	[[tabBar addTabButton] setTarget:self];
	[[tabBar addTabButton] setAction:@selector(addNewDocumentTab:)];
	[tabBar setStyleNamed:@"Metal"];
	[tabBar setCanCloseOnlyTab:NO];
	[tabBar setHideForSingleTab:[[NSUserDefaults standardUserDefaults] boolForKey:@"hidetab"]];
	// FIXME: add KVC observer for the 'hidetab' option
	[tabBar setPartnerView:splitView];
	[tabBar setShowAddTabButton:YES];
	[tabBar setAllowsDragBetweenWindows:NO]; // XXX: Must update for this to work without NSTabview

	[[self window] setDelegate:self];
	[[self window] setFrameUsingName:@"MainDocumentWindow"];

	[splitView addSubview:explorerView positioned:NSWindowBelow relativeTo:mainView];
	[splitView addSubview:symbolsView];

	isLoaded = YES;
	if (initialDocument) {
		[self addNewTab:initialDocument];
		initialDocument = nil;
	}
	if (initialViewController) {
		[self createTabWithViewController:initialViewController];
		initialViewController = nil;
	}

	[[self window] bind:@"title" toObject:self withKeyPath:@"currentView.title" options:nil];

	[[self window] makeKeyAndOrderFront:self];
	[symbolsView setSourceHighlight:YES];
	[explorerView setSourceHighlight:YES];
	[symbolsView setNeedsDisplay:YES];
	[explorerView setNeedsDisplay:YES];

	NSRect frame = [splitView frame];
	[splitView setPosition:NSWidth(frame) ofDividerAtIndex:1]; // Symbol list not shown on first launch
	[splitView setAutosaveName:@"ProjectSymbolSplitView"];

	if ([self project] != nil) {
		[self setBaseURL:[[self project] initialURL]];
		[[projectDelegate nextRunloop] browseURL:[[self project] initialURL]];
		/* This makes repeated open requests for the same URL always open a new window.
		 * With this commented, the "project" is already opened, and no new window will be created.
		[[self project] close];
		project = nil;
		*/
	} else if ([projectDelegate explorerIsOpen])
		[[projectDelegate nextRunloop] browseURL:baseURL];

	[self updateJumplistNavigator];

	[parser setNviStyleUndo:[[[NSUserDefaults standardUserDefaults] stringForKey:@"undostyle"] isEqualToString:@"nvi"]];
	[[NSUserDefaults standardUserDefaults] addObserver:self
						forKeyPath:@"undostyle"
						   options:NSKeyValueObservingOptionNew
						   context:NULL];
}

- (id)windowWillReturnFieldEditor:(NSWindow *)sender toObject:(id)anObject
{
	if ([anObject isKindOfClass:[ExTextField class]]) {
		if (viFieldEditor == nil)
			viFieldEditor = [ViTextView makeFieldEditor];
		return viFieldEditor;
	}
	return nil;
}

- (IBAction)addNewDocumentTab:(id)sender
{
	[[NSDocumentController sharedDocumentController] newDocument:self];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
	if ([keyPath isEqualToString:@"undostyle"]) {
		NSString *newStyle = [change objectForKey:NSKeyValueChangeNewKey];
		[parser setNviStyleUndo:[newStyle isEqualToString:@"nvi"]];
	}
}

- (void)addDocument:(ViDocument *)document
{
	if ([documents containsObject:document])
		return;

	NSArray *items = [[openFilesButton menu] itemArray];
	NSInteger ndx;
	for (ndx = 0; ndx < [items count]; ndx++)
		if ([[document displayName] compare:[[items objectAtIndex:ndx] title]
					    options:NSCaseInsensitiveSearch] == NSOrderedAscending)
			break;
	NSMenuItem *item = [[openFilesButton menu] insertItemWithTitle:[document displayName]
								action:@selector(switchToDocumentAction:)
							 keyEquivalent:@""
							       atIndex:ndx];
	[item setRepresentedObject:document];
	[item bind:@"title" toObject:document withKeyPath:@"title" options:nil];

	[documents addObject:document];

	/* Update symbol table. */
	[symbolController filterSymbols];
	[document addObserver:symbolController forKeyPath:@"symbols" options:0 context:NULL];
}

/* Create a new document tab.
 */
- (void)createTabWithViewController:(id<ViViewController>)viewController
{
	if (!isLoaded) {
		/* Defer until NIB is loaded. */
		initialViewController = viewController;
		return;
	}

	ViDocumentTabController *tabController = [[ViDocumentTabController alloc] initWithViewController:viewController window:[self window]];

	NSTabViewItem *tabItem = [[NSTabViewItem alloc] initWithIdentifier:tabController];
	[tabItem bind:@"label" toObject:tabController withKeyPath:@"selectedView.title" options:nil];
	[tabItem setView:[tabController view]];
	[tabView addTabViewItem:tabItem];
	[tabView selectTabViewItem:tabItem];
	[self focusEditor];
}

- (ViDocumentView *)createTabForDocument:(ViDocument *)document
{
	ViDocumentView *docView = [document makeView];
	[self createTabWithViewController:docView];
	return docView;
}

/* Called by a new ViDocument in its makeWindowControllers method.
 */
- (void)addNewTab:(ViDocument *)document
{
	if (!isLoaded) {
		/* Defer until NIB is loaded. */
		initialDocument = document;
		return;
	}

	/*
	 * If current document is untitled and unchanged and the rightmost tab, replace it.
	 */
	ViDocument *closeThisDocument = nil;
	ViDocumentTabController *lastTabController = [[[tabBar representedTabViewItems] lastObject] identifier];
	if ([self currentDocument] != nil &&
	    [[self currentDocument] fileURL] == nil &&
	    [document fileURL] != nil &&
	    ![[self currentDocument] isDocumentEdited] &&
	    [[lastTabController views] count] == 1 &&
	    [self currentDocument] == [[[lastTabController views] objectAtIndex:0] document]) {
		[tabBar disableAnimations];
		closeThisDocument = [self currentDocument];
	}

	[self addDocument:document];
	if (closeThisDocument == nil && (
	    [[NSUserDefaults standardUserDefaults] boolForKey:@"prefertabs"] ||
	    [tabView numberOfTabViewItems] == 0))
		[self createTabForDocument:document];
	else
		[self switchToDocument:document];

	if (closeThisDocument) {
		[closeThisDocument closeAndWindow:NO];
		[tabBar enableAnimations];
	}
}

- (void)documentChangedAlertDidEnd:(NSAlert *)alert
                        returnCode:(NSInteger)returnCode
                       contextInfo:(void *)contextInfo
{
	ViDocument *document = contextInfo;

	if (returnCode == NSAlertSecondButtonReturn) {
		NSError *error = nil;
		[document revertToContentsOfURL:[document fileURL]
					 ofType:[document fileType]
					  error:&error];
		if (error) {
			[[alert window] orderOut:self];
			NSAlert *revertAlert = [NSAlert alertWithError:error];
			[revertAlert beginSheetModalForWindow:[self window]
					        modalDelegate:nil
					       didEndSelector:nil
						  contextInfo:nil];
			[document updateChangeCount:NSChangeReadOtherContents];
		}
	} else
		document.isTemporary = YES;
}

- (void)checkDocumentChanged:(ViDocument *)document
{
	if (document == nil || [document isTemporary])
		return;

	if ([[document fileURL] isFileURL]) {
		NSError *error = nil;
		NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[[document fileURL] path] error:&error];
		if (error) {
			NSAlert *alert = [NSAlert alertWithError:error];
			[alert beginSheetModalForWindow:[self window] modalDelegate:nil didEndSelector:nil contextInfo:nil];
			[document updateChangeCount:NSChangeReadOtherContents];
			document.isTemporary = YES;
			return;
		}

		NSDate *modificationDate = [attributes fileModificationDate];
		if ([[document fileModificationDate] compare:modificationDate] == NSOrderedAscending) {
			[document updateChangeCount:NSChangeReadOtherContents];

			NSAlert *alert = [[NSAlert alloc] init];
			[alert setMessageText:@"This document’s file has been changed by another application since you opened or saved it."];
			[alert setInformativeText:@"Do you want to keep this version or revert to the document on disk?"];
			[alert addButtonWithTitle:@"Keep open version"];
			[alert addButtonWithTitle:@"Revert"];
			[alert beginSheetModalForWindow:[self window]
					  modalDelegate:self
					 didEndSelector:@selector(documentChangedAlertDidEnd:returnCode:contextInfo:)
					    contextInfo:document];
		}
	}
}

- (void)focusEditorDelayed:(id)sender
{
	if ([self currentView])
		[[self window] makeFirstResponder:[[self currentView] innerView]];
}

- (void)focusEditor
{
	[self performSelector:@selector(focusEditorDelayed:)
	           withObject:nil
	           afterDelay:0.0];
}

- (ViTagStack *)sharedTagStack
{
	if (tagStack == nil)
		tagStack = [[ViTagStack alloc] init];
	return tagStack;
}

- (void)windowDidBecomeMain:(NSNotification *)aNotification
{
	currentWindowController = self;
	[self checkDocumentChanged:[self currentDocument]];
}

- (ViDocument *)currentDocument
{
	id<ViViewController> viewController = [self currentView];
	if ([viewController respondsToSelector:@selector(document)])
		return [viewController document];
	return nil;
}

- (void)caretChanged:(NSNotification *)notification
{
	ViTextView *textView = [notification object];
	if (textView == [[self currentView] innerView])
		[symbolController updateSelectedSymbolForLocation:[textView caret]];
}

- (void)showMessage:(NSString *)string
{
	[messageField setStringValue:string];
}

- (void)message:(NSString *)fmt arguments:(va_list)ap
{
	[messageField setStringValue:[[NSString alloc] initWithFormat:fmt arguments:ap]];
}

- (void)message:(NSString *)fmt, ...
{
	va_list ap;
	va_start(ap, fmt);
	[self message:fmt arguments:ap];
	va_end(ap);
}

#pragma mark -

- (void)browseURL:(NSURL *)url
{
	[projectDelegate browseURL:url];
}

- (void)setBaseURL:(NSURL *)url
{
	if (![[url absoluteString] hasSuffix:@"/"])
		url = [NSURL URLWithString:[[url lastPathComponent] stringByAppendingString:@"/"]
			     relativeToURL:url];

	baseURL = [url absoluteURL];
}

- (void)deferred:(id<ViDeferred>)deferred status:(NSString *)statusMessage
{
	[self message:@"%@", statusMessage];
}

- (void)checkBaseURL:(NSURL *)url onCompletion:(void (^)(NSURL *url, NSError *error))aBlock
{
//	if (error == nil && [[url lastPathComponent] isEqualToString:@""])
//		url = [NSURL URLWithString:[conn home] relativeToURL:url];

	id<ViDeferred> deferred = [[ViURLManager defaultManager] fileExistsAtURL:url onCompletion:^(NSURL *normalizedURL, BOOL isDirectory, NSError *error) {
		if (error)
			[self message:@"%@: %@", [url absoluteString], [error localizedDescription]];
		else if (normalizedURL == nil)
			[self message:@"%@: no such file or directory", [url absoluteString]];
		else if (!isDirectory)
			[self message:@"%@: not a directory", [normalizedURL absoluteString]];
		else {
			aBlock(normalizedURL, error);
			return;
		}
		aBlock(nil, error);
	}];
	[deferred setDelegate:self];
}

- (NSString *)displayBaseURL
{
	if ([baseURL isFileURL])
		return [[baseURL path] stringByAbbreviatingWithTildeInPath];
	return [baseURL absoluteString];
}

#pragma mark -
#pragma mark Document closing

- (void)documentController:(NSDocumentController *)docController
               didCloseAll:(BOOL)didCloseAll
               contextInfo:(void *)contextInfo
{
	DEBUG(@"force closing all views: %s", didCloseAll ? "YES" : "NO");
	if (!didCloseAll)
		return;

	while ([tabView numberOfTabViewItems] > 0) {
		NSTabViewItem *item = [tabView tabViewItemAtIndex:0];
		ViDocumentTabController *tabController = [item identifier];
		[self documentController:[ViDocumentController sharedDocumentController]
			     didCloseAll:YES
			   tabController:tabController];
	}
}

- (BOOL)windowShouldClose:(id)window
{
	DEBUG(@"documents = %@", documents);

#if 0
	/* Close the current document first to avoid unecessary document switching. */
	if ([[self currentDocument] isDocumentEdited]) {
		[[self currentDocument] close];
		if ([documents count] == 0)
			return YES;
	}
#endif

	NSMutableSet *set = [[NSMutableSet alloc] init];
	for (ViDocument *doc in documents) {
		if ([set containsObject:doc])
			continue;
		if (![doc isDocumentEdited])
			continue;

		/* Check if this document is open in another window. */
		BOOL openElsewhere = NO;
		for (NSWindow *window in [NSApp windows]) {
			ViWindowController *wincon = [window windowController];
			if (wincon == self || ![wincon isKindOfClass:[ViWindowController class]])
				continue;
			if ([[wincon documents] containsObject:doc]) {
				openElsewhere = YES;
				break;
			}
		}

		if (!openElsewhere)
			[set addObject:doc];
	}

	[[ViDocumentController sharedDocumentController] closeAllDocumentsInSet:set
								   withDelegate:self
							    didCloseAllSelector:@selector(documentController:didCloseAll:contextInfo:)
								    contextInfo:window];
	return NO;
}

- (void)windowWillClose:(NSNotification *)aNotification
{
	if (currentWindowController == self)
		currentWindowController = nil;
	DEBUG(@"will close, got documents: %@", documents);
	[[self project] close];
	[windowControllers removeObject:self];
	[tabBar setDelegate:nil];

	for (ViDocument *doc in documents)
		[self unlistDocument:doc];
}

- (id<ViViewController>)currentView;
{
	return currentView;
}

- (void)setCurrentView:(id<ViViewController>)viewController
{
	if ([currentView respondsToSelector:@selector(document)])
		previousDocumentView = currentView;
	currentView = viewController;
}

/*
 * Closes a tab. All views in it should be closed already.
 */
- (void)closeTabController:(ViDocumentTabController *)tabController
{
	DEBUG(@"closing tab controller %@", tabController);

	NSInteger ndx = [tabView indexOfTabViewItemWithIdentifier:tabController];
	if (ndx != NSNotFound) {
		NSTabViewItem *item = [tabView tabViewItemAtIndex:ndx];
		[tabView removeTabViewItem:item];
		[self tabView:tabView didCloseTabViewItem:item];
#ifndef NO_DEBUG
		if ([[tabController views] count] > 0)
			DEBUG(@"WARNING: got %lu views left in tab", [[tabController views] count]);
#endif
	}
}

- (void)document:(NSDocument *)doc
     shouldClose:(BOOL)shouldClose
     contextInfo:(void *)contextInfo
{
	if (shouldClose)
		[(ViDocument *)doc closeAndWindow:(intptr_t)contextInfo];
}

/* almost, but not quite, like :quit */
- (IBAction)closeCurrent:(id)sender
{
	id<ViViewController> viewController = [self currentView];

	/* If the current view is a document view, check if it's the last document view. */
	if ([viewController respondsToSelector:@selector(document)]) {
		ViDocument *doc = [viewController document];

		/* Check if this document is open in another window. */
		BOOL openElsewhere = NO;
		for (NSWindow *window in [NSApp windows]) {
			ViWindowController *wincon = [window windowController];
			if (wincon == self || ![wincon isKindOfClass:[ViWindowController class]])
				continue;
			if ([[wincon documents] containsObject:doc]) {
				openElsewhere = YES;
				break;
			}
		}

		if (!openElsewhere && [[doc views] count] == 1) {
			[doc canCloseDocumentWithDelegate:self
				      shouldCloseSelector:@selector(document:shouldClose:contextInfo:)
					      contextInfo:(void *)(intptr_t)1];
			return;
		}
	}

	[self closeDocumentView:viewController
	       canCloseDocument:YES
		 canCloseWindow:YES];
}

- (IBAction)closeCurrentDocument:(id)sender
{
	[self closeCurrentDocumentAndWindow:NO];
}

- (void)closeDocument:(ViDocument *)document andWindow:(BOOL)canCloseWindow
{
	[document canCloseDocumentWithDelegate:self
			   shouldCloseSelector:@selector(document:shouldClose:contextInfo:)
				   contextInfo:(void *)(intptr_t)canCloseWindow];
}

/* :bdelete and ctrl-cmd-w */
- (void)closeCurrentDocumentAndWindow:(BOOL)canCloseWindow
{
	ViDocument *doc = [self currentDocument];
	if (doc)
		[self closeDocument:doc andWindow:canCloseWindow];
	else
		[self closeDocumentView:[self currentView]
		       canCloseDocument:NO
			 canCloseWindow:canCloseWindow];
}

/*
 * Close the current view (but not the document!) unless this is
 * the last view in the window.
 * Called by C-w c.
 */
- (BOOL)closeCurrentViewUnlessLast
{
	ViDocumentView *docView = [self currentView];
	if ([tabView numberOfTabViewItems] > 1 || [[[docView tabController] views] count] > 1) {
		[self closeDocumentView:docView
		       canCloseDocument:NO
			 canCloseWindow:NO];
		return YES;
	}
	return NO;
}

- (void)unlistDocument:(ViDocument *)document
{
	DEBUG(@"unlisting document %@", document);

	NSInteger ndx = [[openFilesButton menu] indexOfItemWithRepresentedObject:document];
	if (ndx != -1)
		[[openFilesButton menu] removeItemAtIndex:ndx];
	[documents removeObject:document];
	[document closeWindowController:self];
	[document removeObserver:symbolController forKeyPath:@"symbols"];
	[[symbolController nextRunloop] symbolsUpdate:nil];
}

- (void)closeDocumentView:(id<ViViewController>)viewController
	 canCloseDocument:(BOOL)canCloseDocument
	   canCloseWindow:(BOOL)canCloseWindow
{
	DEBUG(@"closing view controller %@, and document: %s, and window: %s, from window %@",
		viewController, canCloseDocument ? "YES" : "NO", canCloseWindow ? "YES" : "NO",
		[self window]);

	if (viewController == nil)
		[[self window] close];

	if (viewController == currentView)
		[self setCurrentView:nil];

	[[viewController tabController] closeView:viewController];

	/* If this was the last view of the document, close the document too. */
	if (canCloseDocument && [viewController isKindOfClass:[ViDocumentView class]]) {
		ViDocument *doc = [(ViDocumentView *)viewController document];
		/* Check if this document is open in another window. */
		BOOL openElsewhere = NO;
		for (NSWindow *window in [NSApp windows]) {
			ViWindowController *wincon = [window windowController];
			if (wincon == self || ![wincon isKindOfClass:[ViWindowController class]])
				continue;
			if ([[wincon documents] containsObject:doc]) {
				openElsewhere = YES;
				break;
			}
		}

		if (openElsewhere) {
			DEBUG(@"document %@ open in other windows", doc);
			[self unlistDocument:doc];
		} else {
			if ([[doc views] count] == 0) {
				DEBUG(@"closed last view of document %@, closing document", doc);
				[doc close];
			} else {
				DEBUG(@"document %@ has more views open", doc);
			}
		}
	}

	/* If this was the last view in the tab, close the tab too. */
	ViDocumentTabController *tabController = [viewController tabController];
	if ([[tabController views] count] == 0) {
		if ([tabView numberOfTabViewItems] == 1)
			[tabBar disableAnimations];
		[self closeTabController:tabController];

		if ([tabView numberOfTabViewItems] == 0) {
			DEBUG(@"closed last tab, got documents: %@", documents);
			if ([documents count] > 0)
				[self selectDocument:[documents objectAtIndex:0]];
			else if (canCloseWindow)
				[[self window] close];
			else {
				ViDocument *newDoc = [[ViDocumentController sharedDocumentController] openUntitledDocumentAndDisplay:NO
															       error:nil];
				newDoc.isTemporary = YES;
				[newDoc addWindowController:self];
				[self addDocument:newDoc];
				[self selectDocumentView:[self createTabForDocument:newDoc]];
			}
		}
		[tabBar enableAnimations];
	} else if (tabController == [self selectedTabController]) {
		// Select another document view.
		[self selectDocumentView:tabController.selectedView];
	}
}

/*
 * Called by the document when it closes.
 * Removes all views of the document in this window.
 */
- (void)didCloseDocument:(ViDocument *)document andWindow:(BOOL)canCloseWindow
{
	DEBUG(@"closing document %@, and window: %s", document, canCloseWindow ? "YES" : "NO");

	[self unlistDocument:document];

	/* Close all views of the document in this window. */
	ViDocumentView *docView;
	NSMutableSet *set = [NSMutableSet set];
	for (docView in [document views]) {
		DEBUG(@"docview %@ in window %@", docView, [[docView tabController] window]);
		if ([[docView tabController] window] == [self window])
			[set addObject:docView];
	}

	DEBUG(@"closing remaining views in window %@: %@", [self window], set);
	for (docView in set)
		[self closeDocumentView:docView
		       canCloseDocument:NO
			 canCloseWindow:canCloseWindow];
}

- (void)documentController:(NSDocumentController *)docController
	       didCloseAll:(BOOL)didCloseAll
	     tabController:(void *)tabController
{
	DEBUG(@"force close all views in tab %@: %s", tabController, didCloseAll ? "YES" : "NO");
	if (didCloseAll) {
		/* Close any views left in this tab. Do not ask for confirmation. */
		while ([[(ViDocumentTabController *)tabController views] count] > 0)
			[self closeDocumentView:[[(ViDocumentTabController *)tabController views] objectAtIndex:0]
			       canCloseDocument:YES
				 canCloseWindow:YES];
	}
}

- (BOOL)tabView:(NSTabView *)aTabView shouldCloseTabViewItem:(NSTabViewItem *)tabViewItem
{
	ViDocumentTabController *tabController = [tabViewItem identifier];

	/*
	 * Directly close all views for documents that either
	 *  a) have another view in another tab, or
	 *  b) is not modified
	 *
	 * For any document that can't directly be closed, ask the user.
	 */

	NSMutableSet *set = [[NSMutableSet alloc] init];

	DEBUG(@"closing tab controller %@", tabController);

	/* If closing the last tab, close the window. */
	if ([tabView numberOfTabViewItems] == 1) {
		[[self window] performClose:nil];
		return NO;
	}

	/* Close all documents in this tab. */
	id<ViViewController> viewController;
	for (viewController in [tabController views]) {
		if ([viewController respondsToSelector:@selector(document)]) {
			if ([set containsObject:[viewController document]])
				continue;
			if (![[viewController document] isDocumentEdited])
				continue;

			id<ViViewController> otherDocView;
			for (otherDocView in [[viewController document] views])
				if ([otherDocView tabController] != tabController)
					break;
			if (otherDocView != nil)
				continue;

			[set addObject:[viewController document]];
		}
	}

	[[NSDocumentController sharedDocumentController] closeAllDocumentsInSet:set
								   withDelegate:self
							    didCloseAllSelector:@selector(documentController:didCloseAll:tabController:)
								    contextInfo:tabController];

	return NO;
}

- (void)tabView:(NSTabView *)aTabView willCloseTabViewItem:(NSTabViewItem *)tabViewItem
{
}

- (void)tabView:(NSTabView *)aTabView didCloseTabViewItem:(NSTabViewItem *)tabViewItem
{
	// FIXME: check if there are hidden documents and display them in that case
	if ([tabView numberOfTabViewItems] == 0) {
#if 0
		if ([self project] == nil)
			[[self window] close];
		else
			[self synchronizeWindowTitleWithDocumentName];
#endif
	}
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	NSWindow *keyWindow = [NSApp keyWindow];
	BOOL isDocWindow = [[keyWindow windowController] isKindOfClass:[ViWindowController class]];

	if (isDocWindow || [menuItem action] == @selector(performClose:))
		return YES;
	return NO;
}

#pragma mark -
#pragma mark Switching documents

- (void)firstResponderChanged:(NSNotification *)notification
{
	NSView *view = [notification object];
	id<ViViewController> viewController = [self viewControllerForView:view];
	if (viewController) {
		if (parser.partial) {
			[self message:@"Vi command interrupted."];
			[parser reset];
		}
		[self didSelectViewController:viewController];
	}

	if (ex_modal && view != statusbar) {
		[NSApp abortModal];
		ex_modal = NO;
	}
}

- (void)didSelectDocument:(ViDocument *)document
{
	if (document == nil)
		return;

	// XXX: currentView is the *previously* current view
	id<ViViewController> viewController = [self currentView];
	if ([viewController isKindOfClass:[ViDocumentView class]]) {
		if ([(ViDocumentView *)viewController document] == document)
			return;
	}

	[[ViEventManager defaultManager] emit:ViEventWillSelectDocument for:self with:self, document, nil];
	[[self document] removeWindowController:self];
	[document addWindowController:self];
	[self setDocument:document];

	NSInteger ndx = [[openFilesButton menu] indexOfItemWithRepresentedObject:document];
	if (ndx != -1)
		[openFilesButton selectItemAtIndex:ndx];

	// update symbol list
	[symbolController didSelectDocument:document];

	[[ViEventManager defaultManager] emit:ViEventDidSelectDocument for:self with:self, document, nil];
}

- (void)didSelectViewController:(id<ViViewController>)viewController
{
	DEBUG(@"did select view %@", viewController);

	if (viewController == [self currentView])
		return;

	[[ViEventManager defaultManager] emit:ViEventWillSelectView for:self with:self, viewController, nil];

	/* Update the previous document pointer. */
	id<ViViewController> prevView = [self currentView];
	if ([prevView isKindOfClass:[ViDocumentView class]]) {
		ViDocument *doc = [(ViDocumentView *)prevView document];
		if (doc != previousDocument) {
			DEBUG(@"previous document %@ -> %@", previousDocument, doc);
			previousDocument = doc;
		}
	}

	if ([viewController isKindOfClass:[ViDocumentView class]]) {
		ViDocumentView *docView = viewController;
		if (!jumping)
			[[docView textView] pushCurrentLocationOnJumpList];
		[self didSelectDocument:[docView document]];
		[symbolController updateSelectedSymbolForLocation:[[docView textView] caret]];
	}

	ViDocumentTabController *tabController = [viewController tabController];
	[tabController setSelectedView:viewController];

	if (tabController == [currentView tabController] &&
	    currentView != [tabController previousView]) {
		[tabController setPreviousView:currentView];
	}

	[self setCurrentView:viewController];

	[[ViEventManager defaultManager] emit:ViEventDidSelectView for:self with:self, viewController, nil];
}

/*
 * Selects the tab holding the given document view and focuses the view.
 */
- (id<ViViewController>)selectDocumentView:(id<ViViewController>)viewController
{
	ViDocumentTabController *tabController = [viewController tabController];

	NSInteger ndx = [tabView indexOfTabViewItemWithIdentifier:tabController];
	if (ndx == NSNotFound)
		return nil;

	NSTabViewItem *item = [tabView tabViewItemAtIndex:ndx];
	[tabView selectTabViewItem:item];

	// Focus the text view
	[[self window] makeFirstResponder:[viewController innerView]];

	return viewController;
}

- (void)tabView:(NSTabView *)aTabView willSelectTabViewItem:(NSTabViewItem *)tabViewItem
{
	ViDocumentTabController *tabController = [tabViewItem identifier];
	[[ViEventManager defaultManager] emit:ViEventWillSelectTab for:self with:self, tabController, nil];
}

- (void)tabView:(NSTabView *)aTabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem
{
	ViDocumentTabController *tabController = [tabViewItem identifier];
	[self selectDocumentView:tabController.selectedView];
	[[ViEventManager defaultManager] emit:ViEventDidSelectTab for:self with:self, tabController, nil];
}

/*
 * Returns the most appropriate view for the given document.
 * Returns nil if no view of the document is currently open.
 */
- (ViDocumentView *)viewForDocument:(ViDocument *)document
{
	if (!isLoaded || document == nil)
		return nil;

	ViDocumentView *docView = nil;
	id<ViViewController> viewController = [self currentView];

	/* Check if the current view contains the document. */
	if ([viewController isKindOfClass:[ViDocumentView class]]) {
		docView = viewController;
		if ([docView document] == document)
			return viewController;
	}

	/* Check if current tab has a view of the document. */
	ViDocumentTabController *tabController = [self selectedTabController];
	for (viewController in [tabController views])
		if ([viewController isKindOfClass:[ViDocumentView class]] &&
		    [[(ViDocumentView *)viewController document] isEqual:document])
			return viewController;

	/* Check if the previous document view holds the document. */
	if ([previousDocumentView document] == document) {
		/* Is it still visible? */
		if ([[document views] containsObject:previousDocumentView])
			return previousDocumentView;
	}

	/* Select any existing view of the document. */
	if ([[document views] count] > 0) {
		docView = [[document views] anyObject];
		/*
		 * If the tab with the document view contains more views
		 * of the same document, prefer the selected view in the
		 * (randomly) selected tab controller.
		 */
		id<ViViewController> selView = [[docView tabController] selectedView];
		if ([selView isKindOfClass:[ViDocumentView class]] &&
		    [(ViDocumentView *)selView document] == document)
			return [self selectDocumentView:selView];
		return [self selectDocumentView:docView];
	}

	/* No open view for the given document. */
	return nil;
}

/*
 * Selects the most appropriate view for the given document.
 * Will change current tab if no view of the document is visible in the current tab.
 */
- (ViDocumentView *)selectDocument:(ViDocument *)document
{
	if (!isLoaded || document == nil)
		return nil;

	ViDocumentView *docView = [self viewForDocument:document];
	if (docView)
		return [self selectDocumentView:docView];

	/* No view exists of the document, create a new tab. */
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"prefertabs"] ||
	    [tabView numberOfTabViewItems] == 0)
		docView = [self createTabForDocument:document];
	else
		docView = [self switchToDocument:document];
	return [self selectDocumentView:docView];
}

- (IBAction)selectNextTab:(id)sender
{
	NSArray *tabs = [tabBar representedTabViewItems];
	NSInteger num = [tabs count];
	if (num <= 1)
		return;

	NSInteger i;
	for (i = 0; i < num; i++)
	{
		if ([tabs objectAtIndex:i] == [tabView selectedTabViewItem])
		{
			if (++i >= num)
				i = 0;
			[tabView selectTabViewItem:[tabs objectAtIndex:i]];
			break;
		}
	}
}

- (IBAction)selectPreviousTab:(id)sender
{
	NSArray *tabs = [tabBar representedTabViewItems];
	NSInteger num = [tabs count];
	if (num <= 1)
		return;

	NSInteger i;
	for (i = 0; i < num; i++)
	{
		if ([tabs objectAtIndex:i] == [tabView selectedTabViewItem])
		{
			if (--i < 0)
				i = num - 1;
			[tabView selectTabViewItem:[tabs objectAtIndex:i]];
			break;
		}
	}
}

- (void)selectTabAtIndex:(NSInteger)anIndex
{
	NSArray *tabs = [tabBar representedTabViewItems];
	if (anIndex < [tabs count])
		[tabView selectTabViewItem:[tabs objectAtIndex:anIndex]];
}

- (id<ViViewController>)switchToDocument:(ViDocument *)doc
{
	if (doc == nil)
		return nil;

	if ([[self currentView] isKindOfClass:[ViDocumentView class]] &&
	    [[(ViDocumentView *)[self currentView] document] isEqual:doc])
		return [self currentView];

	ViDocumentTabController *tabController = [self selectedTabController];
	id<ViViewController> viewController = [tabController replaceView:[self currentView]
							    withDocument:doc];
	return [self selectDocumentView:viewController];
}

- (void)switchToLastDocument
{
	/* Make sure the previous document is still registered in the document controller. */
	if (previousDocument == nil)
		return;
	if (![[[ViDocumentController sharedDocumentController] documents] containsObject:previousDocument]) {
		DEBUG(@"previous document %@ not listed", previousDocument);
		previousDocument = [[ViDocumentController sharedDocumentController] openDocumentWithContentsOfURL:[previousDocument fileURL]
													  display:NO
													    error:nil];
	}
	[self switchToDocument:previousDocument];
}

- (void)selectLastDocument
{
	if (previousDocument == nil)
		return;
	if (![[[ViDocumentController sharedDocumentController] documents] containsObject:previousDocument]) {
		DEBUG(@"previous document %@ not listed", previousDocument);
		previousDocument = [[ViDocumentController sharedDocumentController] openDocumentWithContentsOfURL:[previousDocument fileURL]
													  display:NO
													    error:nil];
	}
	[self selectDocument:previousDocument];
}

- (ViDocumentTabController *)selectedTabController
{
	return [[tabView selectedTabViewItem] identifier];
}

/*
 * Called from document popup in the toolbar.
 * Changes the document in the current view to the selected document.
 */
- (void)switchToDocumentAction:(id)sender
{
	ViDocument *doc = [sender representedObject];
	if (doc)
		[self switchToDocument:doc];
}

- (ViDocument *)documentForURL:(NSURL *)url
{
	for (ViDocument *doc in documents)
		if ([url isEqual:[doc fileURL]])
			return doc;
	return nil;
}

- (BOOL)gotoURL:(NSURL *)url
           line:(NSUInteger)line
         column:(NSUInteger)column
           view:(ViDocumentView *)docView
{
	ViDocument *document = [self documentForURL:url];
	if (document == nil) {
		NSError *error = nil;
		ViDocumentController *ctrl = [NSDocumentController sharedDocumentController];
		document = [ctrl openDocumentWithContentsOfURL:url display:YES error:&error];
		if (error) {
			[NSApp presentError:error];
			return NO;
		}
	}

	if (docView == nil)
		docView = [self selectDocument:document];
	else
		[self selectDocumentView:docView];

	if (line > 0)
		[[docView textView] gotoLine:line column:column];

	return YES;
}

- (BOOL)gotoURL:(NSURL *)url line:(NSUInteger)line column:(NSUInteger)column
{
	return [self gotoURL:url line:line column:column view:nil];
}

- (BOOL)gotoURL:(NSURL *)url lineNumber:(NSNumber *)lineNumber
{
	return [self gotoURL:url line:[lineNumber unsignedIntegerValue] column:0];
}

- (BOOL)gotoURL:(NSURL *)url
{
	return [self gotoURL:url line:0 column:0];
}

#pragma mark -
#pragma mark View Splitting

- (IBAction)splitViewHorizontally:(id)sender
{
	id<ViViewController> viewController = [self currentView];
	if (viewController == nil)
		return;

	// Only document views support splitting (?)
	if ([viewController isKindOfClass:[ViDocumentView class]]) {
		ViDocumentTabController *tabController = [viewController tabController];
		[tabController splitView:viewController vertically:NO];
		[self selectDocumentView:viewController];
	}
}

- (IBAction)splitViewVertically:(id)sender
{
	id<ViViewController> viewController = [self currentView];
	if (viewController == nil)
		return;

	// Only document views support splitting (?)
	if ([viewController isKindOfClass:[ViDocumentView class]]) {
		ViDocumentTabController *tabController = [viewController tabController];
		[tabController splitView:viewController vertically:YES];
		[self selectDocumentView:viewController];
	}
}

- (id<ViViewController>)viewControllerForView:(NSView *)aView
{
	if (aView == nil)
		return nil;

	NSArray *tabs = [tabBar representedTabViewItems];
	for (NSTabViewItem *item in tabs) {
		id<ViViewController> viewController = [[item identifier] viewControllerForView:aView];
		if (viewController)
			return viewController;
	}

	if ([aView respondsToSelector:@selector(superview)])
		return [self viewControllerForView:[aView superview]];

	DEBUG(@"***** View %@ not in a view controller", aView);
	return nil;
}

- (BOOL)normalizeSplitViewSizesInCurrentTab
{
	id<ViViewController> viewController = [self currentView];
	if (viewController == nil)
		return NO;

	ViDocumentTabController *tabController = [viewController tabController];
	[tabController normalizeAllViews];
	return YES;
}

- (BOOL)closeOtherViews
{
	id<ViViewController> viewController = [self currentView];
	if (viewController == nil)
		return NO;

	ViDocumentTabController *tabController = [viewController tabController];
	if ([[tabController views] count] == 1) {
		[self message:@"Already only one window"];
		return NO;
	}
	[tabController closeViewsOtherThan:viewController];
	return YES;
}

- (BOOL)moveCurrentViewToNewTab
{
	id<ViViewController> viewController = [self currentView];
	if (viewController == nil)
		return NO;

	ViDocumentTabController *tabController = [viewController tabController];
	if ([[tabController views] count] == 1) {
		[self message:@"Already only one window"];
		return NO;
	}

	[tabController closeView:viewController];
	[self createTabWithViewController:viewController];
	return YES;
}

- (IBAction)moveCurrentViewToNewTabAction:(id)sender
{
	[self moveCurrentViewToNewTab];
}

- (BOOL)selectViewAtPosition:(ViViewOrderingMode)position relativeTo:(id)aView
{
	id<ViViewController> viewController, otherViewController;
	if ([aView conformsToProtocol:@protocol(ViViewController)])
		viewController = aView;
	else
		viewController = [self viewControllerForView:aView];
	otherViewController = [[viewController tabController] viewAtPosition:position
								  relativeTo:[viewController view]];
	if (otherViewController == nil)
		return NO;
	[self selectDocumentView:otherViewController];
	return YES;
}

- (id<ViViewController>)splitVertically:(BOOL)isVertical
                                andOpen:(id)filenameOrURL
                     orSwitchToDocument:(ViDocument *)doc
                        allowReusedView:(BOOL)allowReusedView
{
	ViDocumentController *ctrl = [ViDocumentController sharedDocumentController];
	BOOL newDoc = YES;

	NSError *err = nil;
	if (filenameOrURL) {
		NSURL *url;
		if ([filenameOrURL isKindOfClass:[NSURL class]])
			url = filenameOrURL;
		else
			url = [ctrl normalizePath:filenameOrURL
				       relativeTo:baseURL
					    error:&err];
		if (url && !err) {
			doc = [ctrl documentForURL:url];
			if (doc)
				newDoc = NO;
			else
				doc = [ctrl openDocumentWithContentsOfURL:filenameOrURL
								  display:NO
								    error:&err];
		}
	} else if (doc == nil) {
		doc = [ctrl openUntitledDocumentAndDisplay:NO error:&err];
		doc.isTemporary = YES;
	} else
		newDoc = NO;

	if (err) {
		[self message:@"%@", [err localizedDescription]];
		return nil;
	}

	if (doc) {
		[doc addWindowController:self];
		[self addDocument:doc];

		id<ViViewController> viewController = [self currentView];
		ViDocumentTabController *tabController = [viewController tabController];
		ViDocumentView *newDocView = nil;
		if (allowReusedView && !newDoc) {
			/* Check if the tab already has a view for this document. */
			for (id<ViViewController> v in tabController.views)
				if ([v respondsToSelector:@selector(document)] &&
				    [v document] == doc) {
					newDocView = v;
					break;
				}
		}
		if (newDocView == nil)
			newDocView = [tabController splitView:viewController
						     withView:[doc makeView]
						   vertically:isVertical];
		[self selectDocumentView:newDocView];

		if (!newDoc && [viewController isKindOfClass:[ViDocumentView class]]) {
			/*
			 * If we're splitting a document, position
			 * the caret in the new view appropriately.
			 */
			ViDocumentView *docView = viewController;
			[[newDocView textView] setCaret:[[docView textView] caret]];
			[[newDocView textView] scrollRangeToVisible:NSMakeRange([[docView textView] caret], 0)];
		}

		return newDocView;
	}

	return nil;
}

- (id<ViViewController>)splitVertically:(BOOL)isVertical
                                andOpen:(id)filenameOrURL
                     orSwitchToDocument:(ViDocument *)doc
{
	return [self splitVertically:isVertical
			     andOpen:filenameOrURL
		  orSwitchToDocument:doc
		     allowReusedView:NO];
}

#pragma mark -
#pragma mark Split view delegate methods

- (BOOL)splitView:(NSSplitView *)sender canCollapseSubview:(NSView *)subview
{
	if (sender == splitView)
		return YES;
	return NO;
}

- (BOOL)splitView:(NSSplitView *)sender shouldHideDividerAtIndex:(NSInteger)dividerIndex
{
	if (sender == splitView)
		return YES;
	return NO;
}

- (CGFloat)splitView:(NSSplitView *)sender
constrainMinCoordinate:(CGFloat)proposedMin
         ofSubviewAt:(NSInteger)offset
{
	if (sender == splitView) {
		NSView *view = [[sender subviews] objectAtIndex:offset];
		if (view == explorerView)
			return 100;
		NSRect frame = [sender frame];
		return IMAX(frame.size.width - 500, 0);
	}

	return proposedMin;
}

- (CGFloat)splitView:(NSSplitView *)sender
constrainMaxCoordinate:(CGFloat)proposedMax
         ofSubviewAt:(NSInteger)offset
{
	if (sender == splitView) {
		NSView *view = [[sender subviews] objectAtIndex:offset];
		if (view == explorerView)
			return 500;
		return IMAX(proposedMax - 100, 0);
	} else
		return proposedMax;
}

- (BOOL)splitView:(NSSplitView *)sender
shouldCollapseSubview:(NSView *)subview
forDoubleClickOnDividerAtIndex:(NSInteger)dividerIndex
{
	if (sender == splitView)
	{
		// collapse both side views, but not the edit view
		if (subview == explorerView || subview == symbolsView)
			return YES;
	}
	return NO;
}

- (void)splitView:(id)sender resizeSubviewsWithOldSize:(NSSize)oldSize
{
	if (sender != splitView)
		return;

	NSUInteger nsubviews = [[sender subviews] count];
	if (nsubviews < 2) {
		// the side views have not been added yet
		[sender adjustSubviews];
		return;
	}

	NSRect newFrame = [sender frame];
	float dividerThickness = [sender dividerThickness];

	NSInteger explorerWidth = 0;
	if ([sender isSubviewCollapsed:explorerView])
		explorerWidth = 0;
	else
		explorerWidth = [explorerView frame].size.width;

	NSRect symbolsFrame = [symbolsView frame];
	NSInteger symbolsWidth = symbolsFrame.size.width;
	if ([sender isSubviewCollapsed:symbolsView])
		symbolsWidth = 0;

	/* Keep the symbol sidebar in constant width. */
	NSRect mainFrame = [mainView frame];
	mainFrame.size.width = newFrame.size.width - (explorerWidth + symbolsWidth + (nsubviews-2)*dividerThickness);
	mainFrame.size.height = newFrame.size.height;

	[mainView setFrame:mainFrame];
	[sender adjustSubviews];
}

- (NSRect)splitView:(NSSplitView *)sender
additionalEffectiveRectOfDividerAtIndex:(NSInteger)dividerIndex
{
	if (sender != splitView)
		return NSZeroRect;

	NSView *leftView = [[sender subviews] objectAtIndex:dividerIndex];
	NSView *rightView = [[sender subviews] objectAtIndex:dividerIndex + 1];

	NSRect frame = [sender frame];
	NSRect resizeRect;
	if (leftView == explorerView)
		resizeRect = [projectResizeView frame];
	else if (rightView == symbolsView) {
		resizeRect = [symbolsResizeView frame];
		resizeRect.origin = [sender convertPoint:resizeRect.origin
					        fromView:symbolsResizeView];
	} else
		return NSZeroRect;

	resizeRect.origin.y = NSHeight(frame) - NSHeight(resizeRect);
	return resizeRect;
}

#pragma mark -
#pragma mark Symbol List

- (void)gotoSymbol:(ViSymbol *)aSymbol inView:(ViDocumentView *)docView
{
	NSRange range = aSymbol.range;
	ViTextView *textView = [docView textView];
	[textView setCaret:range.location];
	[textView scrollRangeToVisible:range];
	[[textView nextRunloop] showFindIndicatorForRange:range];
}

- (void)gotoSymbol:(ViSymbol *)aSymbol
{
	id<ViViewController> viewController = [self currentView];
	if ([viewController isKindOfClass:[ViDocumentView class]])
		[[(ViDocumentView *)viewController textView] pushCurrentLocationOnJumpList];

	/* XXX: prevent pushing an extraneous jump on the list. */
	jumping = YES;
	ViDocumentView *docView = [self selectDocument:aSymbol.document];
	jumping = NO;

	[self gotoSymbol:aSymbol inView:docView];
}

- (IBAction)toggleSymbolList:(id)sender
{
	[symbolController toggleSymbolList:sender];
}

- (IBAction)searchSymbol:(id)sender
{
	[symbolController searchSymbol:sender];
}

- (IBAction)focusSymbols:(id)sender
{
	[symbolController focusSymbols:sender];
}

- (NSMutableArray *)symbolsFilteredByPattern:(NSString *)pattern
{
	ViRegexp *rx = [[ViRegexp alloc] initWithString:pattern
						options:ONIG_OPTION_IGNORECASE];

	NSMutableArray *syms = [NSMutableArray array];
	for (ViDocument *doc in documents)
		for (ViSymbol *s in doc.symbols)
			if ([rx matchInString:s.symbol])
				[syms addObject:s];

	return syms;
}

#pragma mark -

- (IBAction)searchFiles:(id)sender
{
	[projectDelegate searchFiles:sender];
}

- (IBAction)focusExplorer:(id)sender
{
	[projectDelegate focusExplorer:sender];
}

- (BOOL)focus_explorer:(ViCommand *)command
{
	[projectDelegate focusExplorer:nil];
	return YES;
}

- (IBAction)toggleExplorer:(id)sender
{
	[projectDelegate toggleExplorer:sender];
}

#pragma mark -
#pragma mark Jumplist navigation

- (IBAction)navigateJumplist:(id)sender
{
	NSURL *url, **urlPtr = nil;
	NSUInteger line, *linePtr = NULL, column, *columnPtr = NULL;
	NSView **viewPtr = NULL;

	id<ViViewController> viewController = [self currentView];
	if ([viewController isKindOfClass:[ViDocumentView class]]) {
		ViTextView *tv = [(ViDocumentView *)viewController textView];
		if (tv == nil)
			return;
		url = [[self document] fileURL];
		line = [[tv textStorage] lineNumberAtLocation:[tv caret]];
		column = [[tv textStorage] columnAtLocation:[tv caret]];
		urlPtr = &url;
		linePtr = &line;
		columnPtr = &column;
		viewPtr = &tv;
	}

	if ([sender selectedSegment] == 0)
		[jumpList backwardToURL:urlPtr line:linePtr column:columnPtr view:viewPtr];
	else
		[jumpList forwardToURL:NULL line:NULL column:NULL view:NULL];
}

- (void)updateJumplistNavigator
{
	[jumplistNavigator setEnabled:![jumpList atEnd] forSegment:1];
	[jumplistNavigator setEnabled:![jumpList atBeginning] forSegment:0];
}

- (void)jumpList:(ViJumpList *)aJumpList added:(ViJump *)jump
{
	[self updateJumplistNavigator];
}

- (void)jumpList:(ViJumpList *)aJumpList goto:(ViJump *)jump
{
	/* XXX: Set a flag telling didSelectDocument: that we're currently navigating the jump list.
	 * This prevents us from pushing an extraneous jump on the list.
	 */
	jumping = YES;
	id<ViViewController> viewController = nil;
	if (jump.view)
		viewController = [self viewControllerForView:jump.view];
	[self gotoURL:jump.url line:jump.line column:jump.column view:viewController];
	jumping = NO;

	ViTextView *tv = [(ViDocumentView *)[self currentView] textView];
	[[tv nextRunloop] showFindIndicatorForRange:NSMakeRange(tv.caret, 1)];
	[self updateJumplistNavigator];
}

#pragma mark -
#pragma mark Vi actions

- (BOOL)increase_fontsize:(ViCommand *)command
{
	NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
	NSInteger fs;
	NSInteger delta = 1;
	if ([command.mapping.parameter respondsToSelector:@selector(integerValue)])
		delta = [command.mapping.parameter integerValue];
	if (delta == 0)
		delta = 1;
	if (command.count == 0)
		fs = [defs integerForKey:@"fontsize"] + delta;
	else
		fs = command.count;
	if (fs <= 1)
		return NO;
	[defs setInteger:fs forKey:@"fontsize"];
	return YES;
}

- (BOOL)window_left:(ViCommand *)command
{
	return [self selectViewAtPosition:ViViewLeft relativeTo:currentView];
}

- (BOOL)window_down:(ViCommand *)command
{
	return [self selectViewAtPosition:ViViewDown relativeTo:currentView];
}

- (BOOL)window_up:(ViCommand *)command
{
	return [self selectViewAtPosition:ViViewUp relativeTo:currentView];
}

- (BOOL)window_right:(ViCommand *)command
{
	return [self selectViewAtPosition:ViViewRight relativeTo:currentView];
}

- (BOOL)window_last:(ViCommand *)command
{
	ViDocumentTabController *tabController = [[self currentView] tabController];
	id<ViViewController> prevView = tabController.previousView;
	if (prevView == nil)
		return NO;
	[self selectDocumentView:prevView];
	return YES;
}

- (BOOL)window_next:(ViCommand *)command
{
	ViDocumentTabController *tabController = [[self currentView] tabController];
	id<ViViewController> nextView = [tabController nextViewClockwise:YES
							      relativeTo:[[self currentView] view]];
	if (nextView == nil)
		return NO;
	[self selectDocumentView:nextView];
	return YES;
}

- (BOOL)window_previous:(ViCommand *)command
{
	ViDocumentTabController *tabController = [[self currentView] tabController];
	id<ViViewController> nextView = [tabController nextViewClockwise:NO
							      relativeTo:[[self currentView] view]];
	if (nextView == nil)
		return NO;
	[self selectDocumentView:nextView];
	return YES;
}

- (BOOL)window_close:(ViCommand *)command
{
	return [self ex_close:nil];
}

- (BOOL)window_split:(ViCommand *)command
{
	return [self ex_split:nil];
}

- (BOOL)window_vsplit:(ViCommand *)command
{
	return [self ex_vsplit:nil];
}

- (BOOL)window_new:(ViCommand *)command
{
	return [self ex_new:nil];
}

- (BOOL)window_totab:(ViCommand *)command
{
	return [self moveCurrentViewToNewTab];
}

- (BOOL)window_normalize:(ViCommand *)command
{
	return [self normalizeSplitViewSizesInCurrentTab];
}

- (BOOL)window_only:(ViCommand *)command
{
	return [self closeOtherViews];
}

- (BOOL)next_tab:(ViCommand *)command
{
	if (command.count)
		[self selectTabAtIndex:command.count - 1];
	else
		[self selectNextTab:nil];
	return YES;
}

- (BOOL)previous_tab:(ViCommand *)command
{
	[self selectPreviousTab:nil];
	return YES;
}

/* syntax: ctrl-^ */
- (BOOL)switch_file:(ViCommand *)command
{
	DEBUG(@"previous document is %@", previousDocument);
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"prefertabs"])
		[self selectLastDocument];
	else
		[self switchToLastDocument];
	return YES;
}

/* syntax: cmd-[0-9] */
- (BOOL)switch_tab:(ViCommand *)command
{
	if (![command.mapping.parameter respondsToSelector:@selector(intValue)]) {
		MESSAGE(@"Unexpected parameter type %@",
		    NSStringFromClass([command.mapping.parameter class]));
		return NO;
	}
	int arg = [command.mapping.parameter intValue];
	[self selectTabAtIndex:arg];
	return YES;
}

#pragma mark -
#pragma mark Input of ex commands

- (void)textField:(ExTextField *)textField executeExCommand:(NSString *)exCommand
{
	if (exCommand) {
		exString = exCommand;
		if (ex_modal)
			[NSApp abortModal];
	} else if (ex_modal)
		[NSApp abortModal];

	ex_busy = NO;
}

- (NSString *)getExStringInteractivelyForCommand:(ViCommand *)command
{
	ViMacro *macro = command.macro;

	if (ex_busy) {
		INFO(@"%s", "can't handle nested ex commands!");
		return nil;
	}

	ex_busy = YES;
	exString = nil;

	[messageField setHidden:YES];
	[statusbar setHidden:NO];
	[statusbar setEditable:YES];
	[statusbar setStringValue:@""];
	[statusbar setFont:[NSFont userFixedPitchFontOfSize:12]];
	/*
	 * The ExTextField resets the field editor when gaining focus (in becomeFirstResponder).
	 */
	[[self window] makeFirstResponder:statusbar];

	if (macro) {
		NSInteger keyCode;
		ViTextView *editor = (ViTextView *)[[self window] fieldEditor:YES forObject:statusbar];
		while (ex_busy && (keyCode = [macro pop]) != -1)
			[editor.keyManager handleKey:keyCode];
	}

	if (ex_busy) {

		ex_modal = YES;
		[NSApp runModalForWindow:[self window]];
		ex_modal = NO;
		ex_busy = NO;
	}

	[statusbar setStringValue:@""];
	[statusbar setEditable:NO];
	[statusbar setHidden:YES];
	[messageField setHidden:NO];
	[self focusEditor];

	return exString;
}


#pragma mark -
#pragma mark Ex actions

- (NSURL *)parseExFilename:(NSString *)filename
{
	NSError *error = nil;
	NSString *trimmed = [filename stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSURL *url = [[ViDocumentController sharedDocumentController] normalizePath:trimmed
									 relativeTo:baseURL
									      error:&error];
	if (error) {
		[self message:@"%@: %@", trimmed, [error localizedDescription]];
		return nil;
	}

	return url;
}

- (BOOL)ex_cd:(ExCommand *)command
{
	NSString *path = command.filename ?: @"~";
	[self checkBaseURL:[self parseExFilename:path] onCompletion:^(NSURL *url, NSError *error) {
		if (url && !error) {
			[self setBaseURL:url];
			[self ex_pwd:nil];
			[projectDelegate browseURL:url andDisplay:NO];
		}
	}];

	return NO; /* XXX: this is wrong, but needed to keep -keyManager:evaluateCommand: in ViTextView overwrite the message with -updateStatus. */
}

- (BOOL)ex_pwd:(ExCommand *)command
{
	MESSAGE(@"%@", [self displayBaseURL]);
	return NO; /* XXX: this is wrong, but needed to keep -keyManager:evaluateCommand: in ViTextView overwrite the message with -updateStatus. */
}

- (BOOL)ex_close:(ExCommand *)command
{
	BOOL didClose = [self closeCurrentViewUnlessLast];
	if (!didClose)
		MESSAGE(@"Cannot close last window");
	return didClose;
}

- (BOOL)ex_edit:(ExCommand *)command
{
	if (command.filename == nil)
		/* Re-open current file. Check E_C_FORCE in flags. */ ;
	else {
		NSURL *url = [self parseExFilename:command.filename];
		if (url) {
			NSError *error = nil;
			ViDocument *doc;
			doc = [[ViDocumentController sharedDocumentController]
				openDocumentWithContentsOfURL:url
						      display:NO
							error:&error];
			if (error)
				MESSAGE(@"%@: %@", url, [error localizedDescription]);
			else {
				[doc addWindowController:self];
				[self addDocument:doc];
				[self switchToDocument:doc];
				return YES;
			}
		}
	}

	return NO;
}

- (BOOL)ex_tabedit:(ExCommand *)command
{
	if (command.filename == nil)
		/* Re-open current file. Check E_C_FORCE in flags. */ ;
	else {
		NSURL *url = [self parseExFilename:command.filename];
		if (url) {
			NSError *error = nil;
			ViDocument *doc;
			doc = [[ViDocumentController sharedDocumentController]
				openDocumentWithContentsOfURL:url
						      display:NO
							error:&error];
			if (error) {
				MESSAGE(@"%@: %@", url, [error localizedDescription]);
			} else if (doc) {
				[doc addWindowController:self];
				[self addDocument:doc];
				[self createTabForDocument:doc];
				return YES;
			}
		}
	}

	return NO;
}

- (BOOL)ex_new:(ExCommand *)command
{
	return [self splitVertically:NO
                             andOpen:[self parseExFilename:command.filename]
                  orSwitchToDocument:nil] != nil;
}

- (BOOL)ex_tabnew:(ExCommand *)command
{
	NSError *error = nil;
	ViDocument *doc = [[ViDocumentController sharedDocumentController]
	    openUntitledDocumentAndDisplay:NO error:&error];
	if (error) {
		MESSAGE(@"%@", [error localizedDescription]);
		return NO;
	}
	doc.isTemporary = YES;
	[doc addWindowController:self];
	[self addDocument:doc];
	[self createTabForDocument:doc];

	return YES;
}

- (BOOL)ex_vnew:(ExCommand *)command
{
	return [self splitVertically:YES
                             andOpen:[self parseExFilename:command.filename]
                  orSwitchToDocument:nil] != nil;
	return NO;
}

- (BOOL)ex_split:(ExCommand *)command
{
	return [self splitVertically:NO
                             andOpen:[self parseExFilename:command.filename]
                  orSwitchToDocument:[self currentDocument]] != nil;
	return NO;
}

- (BOOL)ex_vsplit:(ExCommand *)command
{
	return [self splitVertically:YES
                             andOpen:[self parseExFilename:command.filename]
                  orSwitchToDocument:[self currentDocument]] != nil;
	return NO;
}

- (BOOL)ex_buffer:(ExCommand *)command
{
	if ([command.string length] == 0) {
		[self message:@"Missing buffer name"];
		return NO;
	}

	NSMutableArray *matches = [NSMutableArray array];

	ViDocument *doc = nil;
	for (doc in [self documents]) {
		if ([doc fileURL] &&
		    [[[doc fileURL] absoluteString] rangeOfString:command.string
							  options:NSCaseInsensitiveSearch].location != NSNotFound)
			[matches addObject:doc];
	}

	if ([matches count] == 0) {
		[self message:@"No matching buffer for %@", command.string];
		return NO;
	} else if ([matches count] > 1) {
		[self message:@"More than one match for %@", command.string];
		return NO;
	}

	doc = [matches objectAtIndex:0];
	if ([command.command->name hasPrefix:@"b"]) {
		if ([self currentDocument] != doc)
			[self switchToDocument:doc];
	} else if ([command.command->name isEqualToString:@"tbuffer"]) {
		ViDocumentView *docView = [self viewForDocument:doc];
		if (docView == nil)
			[self createTabForDocument:doc];
		else
			[self selectDocumentView:docView];
	} else
		/* otherwise it's either sbuffer or vbuffer */
		[self splitVertically:[command.command->name isEqualToString:@"vbuffer"]
                              andOpen:nil
                   orSwitchToDocument:doc
                      allowReusedView:NO];

	return YES;
}

- (void)ex_set:(ExCommand *)command
{
	NSDictionary *variables = [NSDictionary dictionaryWithObjectsAndKeys:
		@"shiftwidth", @"sw",
		@"autoindent", @"ai",
		@"smartindent", @"si",
		@"expandtab", @"et",
		@"smartpair", @"smp",
		@"tabstop", @"ts",
		@"wrap", @"wrap",
		@"smarttab", @"sta",

		@"showguide", @"sg",
		@"guidecolumn", @"gc",
		@"prefertabs", @"prefertabs",
		@"ignorecase", @"ic",
		@"smartcase", @"scs",
		@"number", @"nu",
		@"number", @"num",
		@"number", @"numb",
		@"autocollapse", @"ac",  // automatically collapses other documents in the symbol list
		@"hidetab", @"ht",  // hide tab bar for single tabs
		@"fontsize", @"fs",
		@"fontname", @"font",
		@"searchincr", @"searchincr",
		@"antialias", @"antialias",
		@"undostyle", @"undostyle",
		@"list", @"list",
		@"formatprg", @"fp",
		@"cursorline", @"cul",
		nil];

	NSArray *booleans = [NSArray arrayWithObjects:
	    @"autoindent", @"expandtab", @"smartpair", @"ignorecase", @"smartcase", @"number",
	    @"autocollapse", @"hidetab", @"showguide", @"searchincr", @"smartindent",
	    @"wrap", @"antialias", @"list", @"smarttab", @"prefertabs", @"cursorline", nil];
	static NSString *usage = @"usage: se[t] [option[=[value]]...] [nooption ...] [option? ...] [all]";

	NSString *var;
	for (var in command.words) {
		NSUInteger equals = [var rangeOfString:@"="].location;
		NSUInteger qmark = [var rangeOfString:@"?"].location;
		if (equals == 0 || qmark == 0) {
			[self message:usage];
			return;
		}

		NSString *name;
		if (equals != NSNotFound)
			name = [var substringToIndex:equals];
		else if (qmark != NSNotFound)
			name = [var substringToIndex:qmark];
		else
			name = var;

		BOOL turnoff = NO;
		if ([name hasPrefix:@"no"]) {
			name = [name substringFromIndex:2];
			turnoff = YES;
		}

		if ([name isEqualToString:@"all"]) {
			[self message:@"'set all' not implemented."];
			return;
		}

		NSString *defaults_name = [variables objectForKey:name];
		if (defaults_name == nil && [[variables allValues] containsObject:name])
			defaults_name = name;

		if (defaults_name == nil) {
			[self message:@"set: no %@ option: 'set all' gives all option values.", name];
			return;
		}

		if (qmark != NSNotFound) {
			if ([booleans containsObject:defaults_name]) {
				NSInteger val = [[NSUserDefaults standardUserDefaults] integerForKey:defaults_name];
				[self message:[NSString stringWithFormat:@"%@%@", val == NSOffState ? @"no" : @"", defaults_name]];
			} else {
				NSString *val = [[NSUserDefaults standardUserDefaults] stringForKey:defaults_name];
				[self message:[NSString stringWithFormat:@"%@=%@", defaults_name, val]];
			}
			continue;
		}

		if ([booleans containsObject:defaults_name]) {
			if (equals != NSNotFound) {
				[self message:@"set: [no]%@ option doesn't take a value", defaults_name];
				return;
			}

			[[NSUserDefaults standardUserDefaults] setInteger:turnoff ? NSOffState : NSOnState forKey:defaults_name];
		} else {
			if (equals == NSNotFound) {
				NSString *val = [[NSUserDefaults standardUserDefaults] stringForKey:defaults_name];
				[self message:[NSString stringWithFormat:@"%@=%@", defaults_name, val]];
			} else {
				NSString *val = [var substringFromIndex:equals + 1];
				[[NSUserDefaults standardUserDefaults] setObject:val forKey:defaults_name];
			}
		}
	}
}

- (BOOL)ex_export:(ExCommand *)command
{
	if (command.string == nil)
		return NO;

	NSScanner *scan = [NSScanner scannerWithString:command.string];
	NSString *variable, *value = nil;

	if (![scan scanUpToString:@"=" intoString:&variable] ||
	    ![scan scanString:@"=" intoString:nil])
		return NO;

	if (![scan isAtEnd])
		value = [[scan string] substringFromIndex:[scan scanLocation]];

	NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
	NSDictionary *curenv = [defs dictionaryForKey:@"environment"];
	NSMutableDictionary *env = [NSMutableDictionary dictionaryWithDictionary:curenv];

	if (value)
		[env setObject:value forKey:variable];
	else
		[env removeObjectForKey:value];

	[defs setObject:env forKey:@"environment"];

	DEBUG(@"static environment is now %@", env);

	return YES;
}

- (void)ex_quit:(ExCommand *)command
{
	id<ViViewController> viewController = [self currentView];
	if ([tabView numberOfTabViewItems] > 1 || [[[[self currentView] tabController] views] count] > 1) {
		[self closeDocumentView:viewController
		       canCloseDocument:NO
			 canCloseWindow:NO];
	} else {
		if ((command.flags & E_C_FORCE) == E_C_FORCE) {
			ViDocument *doc;
			while ((doc = [documents lastObject]) != nil) {
				/* Check if this document is open in another window. */
				BOOL openElsewhere = NO;
				for (NSWindow *window in [NSApp windows]) {
					ViWindowController *wincon = [window windowController];
					if (wincon == self || ![wincon isKindOfClass:[ViWindowController class]])
						continue;
					if ([[wincon documents] containsObject:doc]) {
						openElsewhere = YES;
						break;
					}
				}

				if (openElsewhere)
					[self unlistDocument:doc];
				else
					[doc closeAndWindow:YES];
			}
			[[self window] close];
		} else
			[[self window] performClose:nil];
	}

	// FIXME: quit/hide app if last window?
}

@end

