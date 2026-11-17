#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#include "IllucetWebKitBridge.h"
#include <stdlib.h>
#include <string.h>

// All WebKit access stays on the main queue. The interpreter waits off-main;
// only bounded UTF-8 output and redacted status cross the native boundary.
@interface IllucetWebKitEvaluation : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSString *script;
@property(nonatomic, strong) NSString *result;
@property(nonatomic, strong) dispatch_semaphore_t semaphore;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL failed;
@end

@implementation IllucetWebKitEvaluation
- (void)finish:(NSString *)result failed:(BOOL)failed {
    @synchronized(self) {
        if (self.finished) return;
        self.result = result;
        self.failed = failed;
        self.finished = YES;
    }
    [self.webView stopLoading];
    self.webView.navigationDelegate = nil;
    self.webView = nil;
    dispatch_semaphore_signal(self.semaphore);
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSString *wrapper = @"return await new Promise((resolve,reject)=>{"
        "globalThis.console={log:(...v)=>resolve(v.join(' ')),error:()=>reject('evaluation_failed')};"
        "globalThis.print=console.log;globalThis.scriptArgs=[];"
        "try{(0,eval)(script);}catch(e){reject('evaluation_failed');}});";
    [webView callAsyncJavaScript:wrapper arguments:@{@"script":self.script}
        inFrame:nil inContentWorld:WKContentWorld.pageWorld
        completionHandler:^(id result, NSError *error) {
            [self finish:[result isKindOfClass:NSString.class] ? result : nil failed:error != nil];
        }];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finish:nil failed:YES];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { [self finish:nil failed:YES]; }
@end

int32_t illucet_webkit_evaluate(const char *source, size_t source_length,
    uint32_t timeout_milliseconds, size_t output_limit,
    bool (*is_cancelled)(void *), void *context,
    char **output, size_t *output_length, char **error_message) {
    *output = NULL; *output_length = 0; *error_message = NULL;
    if ([NSThread isMainThread] || !source || source_length == 0 || source_length > 16*1024*1024 ||
        timeout_milliseconds == 0 || timeout_milliseconds > 60000 || output_limit > 16*1024*1024 || output_limit == 0) {
        *error_message = strdup("Invalid WebKit evaluation request.");
        return ILLUCET_QUICKJS_ERROR;
    }
    @autoreleasepool {
        IllucetWebKitEvaluation *evaluation = [IllucetWebKitEvaluation new];
        evaluation.script = [[NSString alloc] initWithBytes:source length:source_length encoding:NSUTF8StringEncoding];
        evaluation.semaphore = dispatch_semaphore_create(0);
        if (!evaluation.script) return ILLUCET_QUICKJS_ERROR;
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized(evaluation) { if (evaluation.finished) return; }
            WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
            configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
            evaluation.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
            evaluation.webView.navigationDelegate = evaluation;
            [evaluation.webView loadHTMLString:@"<!doctype html><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; connect-src 'none'\">" baseURL:nil];
        });
        uint32_t elapsed = 0;
        int32_t status = ILLUCET_QUICKJS_OK;
        while (dispatch_semaphore_wait(evaluation.semaphore, dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC)) != 0) {
            elapsed += 50;
            if (is_cancelled && is_cancelled(context)) { status = ILLUCET_QUICKJS_CANCELLED; break; }
            if (elapsed >= timeout_milliseconds) { status = ILLUCET_QUICKJS_TIMEOUT; break; }
        }
        if (status != ILLUCET_QUICKJS_OK) {
            @synchronized(evaluation) { evaluation.finished = YES; }
            dispatch_async(dispatch_get_main_queue(), ^{
                [evaluation.webView stopLoading]; evaluation.webView.navigationDelegate = nil; evaluation.webView = nil;
            });
            *error_message = strdup(status == ILLUCET_QUICKJS_CANCELLED ? "WebKit evaluation cancelled." : "WebKit evaluation timed out.");
            return status;
        }
        NSData *data = [evaluation.result dataUsingEncoding:NSUTF8StringEncoding];
        if (evaluation.failed || !data) {
            *error_message = strdup("WebKit evaluation failed; script details redacted.");
            return ILLUCET_QUICKJS_ERROR;
        }
        if (data.length > output_limit) {
            *error_message = strdup("WebKit output exceeded its limit.");
            return ILLUCET_QUICKJS_OUTPUT_LIMIT;
        }
        *output = malloc(data.length+1);
        if (!*output) return ILLUCET_QUICKJS_ERROR;
        memcpy(*output, data.bytes, data.length); (*output)[data.length] = 0; *output_length = data.length;
        return ILLUCET_QUICKJS_OK;
    }
}
