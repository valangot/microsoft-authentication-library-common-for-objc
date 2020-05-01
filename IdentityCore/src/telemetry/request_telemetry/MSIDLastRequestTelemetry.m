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
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "MSIDLastRequestTelemetry.h"

@implementation MSIDRequestTelemetryErrorInfo
@end

@interface MSIDLastRequestTelemetry()

@property (nonatomic) NSInteger schemaVersion;
@property (nonatomic) NSInteger silentSuccessfulCount;
@property (nonatomic) NSArray<MSIDRequestTelemetryErrorInfo *> *errorsInfo;

@end

@implementation MSIDLastRequestTelemetry

#pragma mark - Init

- (id)initInternal
{
    self = [super init];
    if (self)
    {
        _schemaVersion = 2;
    }
    return self;
}

+ (instancetype)sharedInstance
{
    static dispatch_once_t once;
    static MSIDLastRequestTelemetry *singleton = nil;
    
    dispatch_once(&once, ^{
        singleton = [[MSIDLastRequestTelemetry alloc] initInternal];
    });
    
    return singleton;
}
- (void)updateWithApiId:(NSInteger)apiId
            errorString:(NSString *)errorString
                context:(id<MSIDRequestContext>)context
{
    if (errorString)
    {
        NSMutableArray *errorsInfo = self.errorsInfo ? [self.errorsInfo mutableCopy] : [NSMutableArray new];
        
        __auto_type errorInfo = [MSIDRequestTelemetryErrorInfo new];
        errorInfo.apiId = apiId;
        errorInfo.error = errorString;
        errorInfo.correlationId = context.correlationId;
        
        [errorsInfo addObject:errorInfo];
        
        self.errorsInfo = errorsInfo;
    }
    else
    {
        self.silentSuccessfulCount = 0;
        self.errorsInfo = nil;
    }
}

- (void)increaseSilentSuccessfulCount
{
    self.silentSuccessfulCount = self.silentSuccessfulCount + 1;
}

#pragma mark - MSIDTelemetryStringSerializable

- (NSString *)telemetryString
{
    return [self serializeCurrentTelemetryString];
}

- (instancetype)initWithTelemetryString:(__unused NSString *)telemetryString error:(__unused NSError **)error
{
    self = [super init];
    if (self)
    {
        NSError *internalError;
        [self deserializeLastTelemetryString:telemetryString error:&internalError];
        
        if (internalError) {
            MSID_LOG_WITH_CTX_PII(MSIDLogLevelError, nil, @"Failed to initialize server telemetry, error: %@", MSID_PII_LOG_MASKABLE(internalError));
            if (error) *error = internalError;
            return nil;
        }
    }
    return self;
}

#pragma mark - Private

-(NSString *)serializeCurrentTelemetryString
{
    // Errors are serialized in chronological order. Least recently logged errors are removed when string reaches
    // 4kB limit
    NSString *telemetryString = [NSString stringWithFormat:@"%ld|%ld|", self.schemaVersion, self.silentSuccessfulCount];
    NSString *failedRequestsString = @"";
    NSString *errorMessagesString = @"";
    
    if (self.errorsInfo.count > 0)
    {
        NSUInteger startLength = [telemetryString lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        int lastIndex = (int)self.errorsInfo.count - 1;
        
        // Set first post in fencepost structure -- last item in string doesn't have comma at the end
        NSString *currentFailedRequest = [NSString stringWithFormat:@"%ld,%@", self.errorsInfo[lastIndex].apiId, self.errorsInfo[lastIndex].correlationId];
        NSString *currentErrorMessage = [NSString stringWithFormat:@"%@", self.errorsInfo[lastIndex].error];
        
        // Only add error info into string if the resulting string smaller than 4KB
        if ([currentFailedRequest lengthOfBytesUsingEncoding:NSUTF8StringEncoding] +
                [currentErrorMessage lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + startLength < 4000)
        {
            failedRequestsString = [currentFailedRequest stringByAppendingString:failedRequestsString];
            errorMessagesString = [currentErrorMessage stringByAppendingString:errorMessagesString];
        }

        // Fill in remaining errors with comma at the end of each error
        for (int i = lastIndex - 1; i >= 0; i--)
        {
            NSString *currentFailedRequest = [NSString stringWithFormat:@"%ld,%@,", self.errorsInfo[i].apiId, self.errorsInfo[i].correlationId];
            NSString *currentErrorMessage = [NSString stringWithFormat:@"%@,", self.errorsInfo[i].error];
            
            NSString *newFailedRequestsString = [currentFailedRequest stringByAppendingString:failedRequestsString];
            NSString *newErrorMessagesString = [currentErrorMessage stringByAppendingString:errorMessagesString];
            
            // Only add next error into string if the resulting string smaller than 4KB, otherwise stop building
            // the string
            if ([newFailedRequestsString lengthOfBytesUsingEncoding:NSUTF8StringEncoding] +
                    [newErrorMessagesString lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + startLength < 4000)
            {
                failedRequestsString = newFailedRequestsString;
                errorMessagesString = newErrorMessagesString;
            }
            else
            {
                break;
            }
        }
    }
    
    telemetryString = [telemetryString stringByAppendingFormat:@"%@|%@|", failedRequestsString, errorMessagesString];
    return telemetryString;
}

-(void)deserializeLastTelemetryString:(NSString *)telemetryString error:(NSError **)error
{
    if ([telemetryString length] == 0)
    {
        NSString *errorDescription = @"Initialized server telemetry string with nil or empty string";
        *error = MSIDCreateError(MSIDErrorDomain, MSIDErrorInternal, errorDescription, nil, nil, nil, nil, nil, NO);
        return;
    }
    
    NSArray *telemetryItems = [telemetryString componentsSeparatedByString:@"|"];
    
    // Pipe symbol in final position creates one extra element at the end of componentsSeparatedByString array
    // Hardcoded value of 5 will be changed based on the number of platform fields added in future releases
    if ([telemetryItems count] == 5)
    {
        self.schemaVersion = [telemetryItems[0] intValue];
        self.silentSuccessfulCount = [telemetryItems[1] intValue];
        
        NSArray *failedRequests = [telemetryItems[2] componentsSeparatedByString:@","];
        NSArray *errors = [telemetryItems[3] componentsSeparatedByString:@","];
        NSMutableArray *errorsInfo = [NSMutableArray<MSIDRequestTelemetryErrorInfo *> new];
        
        // Each failed request has 2 types ID and 1 error code
        if ([failedRequests count] == 2 * [errors count])
        {
            
            int i; int j;
            for (i = 0, j = 0; i < [errors count] && j < [failedRequests count]; i++, j+=2)
            {
                __auto_type errorInfo = [MSIDRequestTelemetryErrorInfo new];
                errorInfo.apiId = [failedRequests[j] intValue];
                errorInfo.correlationId = failedRequests[j+1];
                errorInfo.error = errors[i];
                [errorsInfo addObject:errorInfo];
            }
            
            self.errorsInfo = errorsInfo;
            
        }
        else
        {
            NSString *errorDescription = @"String used for server telemetry initialization missing delimiters";
            *error = MSIDCreateError(MSIDErrorDomain, MSIDErrorInternal, errorDescription, nil, nil, nil, nil, nil, NO);
            return;
        }
        
    }
    else
    {
        NSString *errorDescription = @"Initialized server telemetry string with invalid string format";
        *error = MSIDCreateError(MSIDErrorDomain, MSIDErrorInternal, errorDescription, nil, nil, nil, nil, nil, NO);
        return;
    }
}

@end