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

#import "MSIDAADV2IdTokenWrapper.h"

#define ID_TOKEN_ISSUER              @"iss"
#define ID_TOKEN_OBJECT_ID           @"oid"
#define ID_TOKEN_TENANT_ID           @"tid"
#define ID_TOKEN_VERSION             @"ver"
#define ID_TOKEN_HOME_OBJECT_ID      @"home_oid"

@implementation MSIDAADV2IdTokenWrapper

MSID_JSON_ACCESSOR(ID_TOKEN_ISSUER, issuer)
MSID_JSON_ACCESSOR(ID_TOKEN_OBJECT_ID, objectId)
MSID_JSON_ACCESSOR(ID_TOKEN_TENANT_ID, tenantId)
MSID_JSON_ACCESSOR(ID_TOKEN_VERSION, version)
MSID_JSON_ACCESSOR(ID_TOKEN_HOME_OBJECT_ID, homeObjectId)

- (instancetype)initWithRawIdToken:(NSString *)rawIdTokenString
{
    self = [super initWithRawIdToken:rawIdTokenString];
    
    if (self)
    {
        // Set uniqueId
        NSString *uniqueId = self.objectId;
        
        if ([NSString msidIsStringNilOrBlank:uniqueId])
        {
            uniqueId = self.subject;
        }
        
        _uniqueId = [MSIDIdTokenWrapper normalizeUserId:uniqueId];
        _userId = [MSIDIdTokenWrapper normalizeUserId:self.preferredUsername];
        _userIdDisplayable = YES;
    }
    
    return self;
}

- (BOOL)matchesLegacyUserId:(NSString *)legacyUserId
{
    return [super matchesLegacyUserId:legacyUserId]
        || [self.objectId isEqualToString:legacyUserId];
}

@end