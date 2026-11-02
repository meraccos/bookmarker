#import <SafariServices/SafariServices.h>
#import <AppKit/AppKit.h>
#import <os/log.h>

@interface SafariExtensionHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation SafariExtensionHandler
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSExtensionItem *item = context.inputItems.firstObject;
    id message = item.userInfo[SFExtensionMessageKey];
    if (![message isKindOfClass:NSDictionary.class]) { [context completeRequestReturningItems:nil completionHandler:nil]; return; }
    id rawURL = message[@"url"];
    NSURL *pageURL = [rawURL isKindOfClass:NSString.class] ? [NSURL URLWithString:rawURL] : nil;
    if (![@[@"http", @"https"] containsObject:pageURL.scheme.lowercaseString] || !pageURL.host.length || pageURL.user || pageURL.password) {
        [context completeRequestReturningItems:nil completionHandler:nil]; return;
    }
    NSString *title = [message[@"title"] isKindOfClass:NSString.class] ? message[@"title"] : @"";
    if (title.length > 4096) title = [title substringToIndex:4096];
    NSURLComponents *request = [[NSURLComponents alloc] init];
    request.scheme = @"bookmarker";
    request.host = @"save";
    request.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url" value:pageURL.absoluteString],
        [NSURLQueryItem queryItemWithName:@"title" value:title]
    ];
    dispatch_async(dispatch_get_main_queue(), ^{
        // Address our containing app explicitly; a stale URL-scheme registration can
        // otherwise launch another installed development copy of Bookmarker.
        NSURL *appURL = NSBundle.mainBundle.bundleURL;
        while (appURL && ![appURL.pathExtension isEqualToString:@"app"]) {
            NSURL *parent = appURL.URLByDeletingLastPathComponent;
            if ([parent isEqual:appURL]) { appURL = nil; break; }
            appURL = parent;
        }
        if (!appURL) { [context cancelRequestWithError:[NSError errorWithDomain:@"Bookmarker" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not locate the Bookmarker app."}]]; return; }
        NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
        configuration.activates = YES;
        [[NSWorkspace sharedWorkspace] openURLs:@[request.URL] withApplicationAtURL:appURL configuration:configuration completionHandler:^(NSRunningApplication *app, NSError *error) {
            if (error) { os_log_error(OS_LOG_DEFAULT, "Bookmarker save handoff failed: %{public}@", error.localizedDescription); }
            else { os_log_info(OS_LOG_DEFAULT, "Bookmarker save request delivered to containing app."); }
            NSExtensionItem *reply = [[NSExtensionItem alloc] init];
            reply.userInfo = @{ SFExtensionMessageKey: @{ @"ok": @(app != nil && error == nil), @"error": error.localizedDescription ?: @"" } };
            [context completeRequestReturningItems:@[reply] completionHandler:nil];
        }];
    });
}
@end
