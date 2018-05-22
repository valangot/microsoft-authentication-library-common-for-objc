//------------------------------------------------------------------------------
//
// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
//------------------------------------------------------------------------------

#import "MSIDOAuth2EmbeddedWebviewController.h"
#import "MSIDTelemetry+Internal.h"
#import "MSIDTelemetryUIEvent.h"
#import "MSIDTelemetryEventStrings.h"
#import "MSIDAadAuthorityCache.h"
#import "MSIDError.h"
#import "MSIDWebOAuth2Response.h"
#import "MSIDWebviewAuthorization.h"
#import "MSIDChallengeHandler.h"
#import "MSIDNTLMHandler.h"
#import "MSIDAuthority.h"
#import "MSIDWorkPlaceJoinConstants.h"

#if TARGET_OS_IPHONE
#import "MSIDAppExtensionUtil.h"
#import "MSIDPKeyAuthHandler.h"
#else
#define DEFAULT_WINDOW_WIDTH 420
#define DEFAULT_WINDOW_HEIGHT 650
#endif

@implementation MSIDOAuth2EmbeddedWebviewController
{
    NSURL *_startUrl;
    NSURL *_endUrl;
    void (^_completionHandler)(MSIDWebOAuth2Response *response, NSError *error);
    
    NSLock *_completionLock;
    NSTimer *_spinnerTimer; // Used for managing the activity spinner
}

- (id)initWithStartUrl:(NSURL *)startUrl
                endURL:(NSURL *)endUrl
               webview:(WKWebView *)webview
               context:(id<MSIDRequestContext>)context
{
    self = [super initWithContext:context];
    
    if (self)
    {
        self.webView = webview;
        _startUrl = startUrl;
        _endUrl = endUrl;
        
        _completionLock = [[NSLock alloc] init];
        self.complete = NO;
    }
    
    return self;
}

-(void)dealloc
{
    [self.webView setNavigationDelegate:nil];
    self.webView = nil;
}

- (BOOL)startWithCompletionHandler:(MSIDWebUICompletionHandler)completionHandler
{
    // If we're not on the main thread when trying to kick up the UI then
    // dispatch over to the main thread.
    if (![NSThread isMainThread])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startWithCompletionHandler:completionHandler];
        });
        return YES;
    }
    
    // Save the completion block
    _completionHandler = [completionHandler copy];
    
    NSError *error = nil;
    [self loadView:&error];
    if (error)
    {
        [self endWebAuthenticationWithError:error orURL:nil];
        return YES;
    }
    
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:_startUrl];
#if TARGET_OS_IPHONE
    // Currently Apple has a bug in iOS about WKWebview handling NSURLAuthenticationMethodClientCertificate.
    // It swallows the challenge response rather than sending it to server.
    // Therefore we work around the bug by using PKeyAuth for WPJ challenge in iOS
    [request addValue:kMSIDPKeyAuthHeaderVersion forHTTPHeaderField:kMSIDPKeyAuthHeader];
#endif
    [self startRequest:request];
    return YES;
}

- (void)cancel
{
    MSID_LOG_INFO(self.context, @"Cancel Web Auth...");
    
    // Dispatch the completion block
    NSError *error = MSIDCreateError(MSIDErrorDomain, MSIDErrorUserCancel, @"The user/application has cancelled the authorization.", nil, nil, nil, self.context.correlationId, nil);
    [self endWebAuthenticationWithError:error orURL:nil];
}

- (BOOL)loadView:(NSError **)error
{
    // create and load the view if not provided
    BOOL result = [super loadView:error];
    
    self.webView.navigationDelegate = self;
    
    return result;
}

- (BOOL)endWebAuthenticationWithError:(NSError *)error
                                orURL:(NSURL *)endURL
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self dismissWebview:^{[self dispatchCompletionBlock:error URL:endURL];}];
    });
    
    return YES;
}

- (void)dispatchCompletionBlock:(NSError *)error URL:(NSURL *)url
{
    // NOTE: It is possible that competition between a successful completion
    //       and the user cancelling the authentication dialog can
    //       occur causing this method to be called twice. The competition
    //       cannot be blocked at its root, and so this method must
    //       be resilient to this condition and should not generate
    //       two callbacks.
    [_completionLock lock];
    
    [MSIDChallengeHandler resetHandlers];
    
    if ( _completionHandler )
    {
        void (^completionHandler)(MSIDWebOAuth2Response *response, NSError *error) = _completionHandler;
        _completionHandler = nil;
        
        MSIDWebOAuth2Response *response = nil;
        NSError *systemError = error;
        if (!systemError)
        {
            response = [MSIDWebviewAuthorization responseWithURL:url
                                                    requestState:self.requestState
                                                   stateVerifier:self.stateVerifier
                                                         context:self.context
                                                           error:&systemError];
        }
        
        dispatch_async( dispatch_get_main_queue(), ^{
            completionHandler(response, error);
        });
    }
    
    [_completionLock unlock];
}

- (void)startRequest:(NSURLRequest *)request
{
    [self loadRequest:request];
    [self presentView];
}

- (void)loadRequest:(NSURLRequest *)request
{
    [self.webView loadRequest:request];
}

#pragma mark - WKNavigationDelegate Protocol

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL *requestUrl = navigationAction.request.URL;
    NSString *requestUrlString = [requestUrl.absoluteString lowercaseString];
    
    MSID_LOG_VERBOSE(self.context, @"-decidePolicyForNavigationAction host: %@", [MSIDAuthority isKnownHost:requestUrl] ? requestUrl.host : @"unknown host");
    MSID_LOG_VERBOSE_PII(self.context, @"-decidePolicyForNavigationAction host: %@", requestUrl.host);
    
    // Stop at the end URL.
    if ([requestUrlString hasPrefix:[_endUrl.absoluteString lowercaseString]] ||
        [[[requestUrl scheme] lowercaseString] isEqualToString:@"msauth"])
    {
        self.complete = YES;
        
        NSURL *url = navigationAction.request.URL;
        [self webAuthDidCompleteWithURL:url];
        
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    
    if ([requestUrlString isEqualToString:@"about:blank"])
    {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    
    if ([[[requestUrl scheme] lowercaseString] isEqualToString:@"browser"])
    {
        self.complete = YES;
        requestUrlString = [requestUrlString stringByReplacingOccurrencesOfString:@"browser://" withString:@"https://"];
        
#if TARGET_OS_IPHONE
        if (![MSIDAppExtensionUtil isExecutingInAppExtension])
        {
            [self cancel];
            [MSIDAppExtensionUtil sharedApplicationOpenURL:[[NSURL alloc] initWithString:requestUrlString]];
        }
        else
        {
            MSID_LOG_INFO(self.context, @"unable to redirect to browser from extension");
        }
#else
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:requestUrlString]];
#endif
        
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    
#if TARGET_OS_IPHONE
    // check for pkeyauth challenge.
    if ([requestUrlString hasPrefix:[kMSIDPKeyAuthUrn lowercaseString]])
    {
        decisionHandler(WKNavigationActionPolicyCancel);
        [MSIDPKeyAuthHandler handleChallenge:requestUrl.absoluteString
                                     context:self.context
                           completionHandler:^(NSURLRequest *challengeResponse, NSError *error) {
                               if (!challengeResponse)
                               {
                                   [self endWebAuthenticationWithError:error orURL:nil];
                                   return;
                               }
                               [self loadRequest:challengeResponse];
                           }];
        return;
    }
#endif
    
    // redirecting to non-https url is not allowed
    if (![[[requestUrl scheme] lowercaseString] isEqualToString:@"https"])
    {
        MSID_LOG_INFO(self.context, @"Server is redirecting to a non-https url");
        self.complete = YES;
        
        NSError *error = MSIDCreateError(MSIDErrorDomain, MSIDServerNonHttpsRedirect, @"The server has redirected to a non-https url.", nil, nil, nil, self.context.correlationId, nil);
        [self endWebAuthenticationWithError:error orURL:nil];
        
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(null_unspecified WKNavigation *)navigation
{
    if (!self.loading)
    {
        self.loading = YES;
        if (_spinnerTimer)
        {
            [_spinnerTimer invalidate];
        }
        _spinnerTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                         target:self
                                                       selector:@selector(onStartLoadingIndicator:)
                                                       userInfo:nil
                                                        repeats:NO];
        [_spinnerTimer setTolerance:0.3];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(null_unspecified WKNavigation *)navigation
{
    NSURL *url = webView.URL;
    MSID_LOG_VERBOSE(self.context, @"-didFinishNavigation host: %@", [MSIDAuthority isKnownHost:url] ? url.host : @"unknown host");
    MSID_LOG_VERBOSE_PII(self.context, @"-didFinishNavigation host: %@", url.host);
    
    [self stopSpinner];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(null_unspecified WKNavigation *)navigation withError:(NSError *)error
{
    [self webAuthFailWithError:error];
}

- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(ChallengeCompletionHandler)completionHandler
{
    NSString *authMethod = [challenge.protectionSpace.authenticationMethod lowercaseString];
    
    MSID_LOG_VERBOSE(self.context,
                     @"%@ - %@. Previous challenge failure count: %ld",
                     @"webView:didReceiveAuthenticationChallenge:completionHandler",
                     authMethod, (long)challenge.previousFailureCount);
    
    [MSIDChallengeHandler handleChallenge:challenge
                                  webview:webView
                                  context:self.context
                        completionHandler:completionHandler];
}

- (void)webAuthDidCompleteWithURL:(NSURL *)endURL
{
    MSID_LOG_INFO(self.context, @"-webAuthDidCompleteWithURL: %@", [MSIDAuthority isKnownHost:endURL] ? endURL.host : @"unknown host");
    MSID_LOG_INFO_PII(self.context, @"-webAuthDidCompleteWithURL: %@", endURL);
    
    [self endWebAuthenticationWithError:nil orURL:endURL];
}

// Authentication failed somewhere
- (void)webAuthFailWithError:(NSError *)error
{
    if (self.complete)
    {
        return;
    }
    
    // Ignore WebKitError 102 for OAuth 2.0 flow.
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102)
    {
        return;
    }
    
    [self stopSpinner];
    
    if([error.domain isEqual:@"WebKitErrorDomain"])
    {
        return;
    }
    
    MSID_LOG_ERROR(self.context, @"-webAuthFailWithError error code %ld", (long)error.code);
    MSID_LOG_ERROR_PII(self.context, @"-webAuthFailWithError: %@", error);
    
    [self endWebAuthenticationWithError:error orURL:nil];
}

#pragma mark - Loading Indicator

- (void)onStartLoadingIndicator:(id)sender
{
    (void)sender;
    
    if (self.loading)
    {
        [self showLoadingIndicator];
    }
    _spinnerTimer = nil;
}

- (void)stopSpinner
{
    if (!self.loading)
    {
        return;
    }
    
    self.loading = NO;
    if (_spinnerTimer)
    {
        [_spinnerTimer invalidate];
        _spinnerTimer = nil;
    }
    
    [self dismissLoadingIndicator];
}

@end

