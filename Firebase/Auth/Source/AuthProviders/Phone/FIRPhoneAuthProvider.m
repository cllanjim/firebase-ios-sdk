/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FIRPhoneAuthProvider.h"

#import "FIRLogger.h"
#import "FIRPhoneAuthCredential_Internal.h"
#import "NSString+FIRAuth.h"
#import "FIRAuthAPNSToken.h"
#import "FIRAuthAPNSTokenManager.h"
#import "FIRAuthAppCredential.h"
#import "FIRAuthAppCredentialManager.h"
#import "FIRAuthGlobalWorkQueue.h"
#import "FIRApp.h"
#import "FIRAuth_Internal.h"
#import "FIRAuthNotificationManager.h"
#import "FIRAuthErrorUtils.h"
#import "FIRAuthBackend.h"
#import "FirebaseAuthVersion.h"
#import "FIROptions.h"
#import "FIRGetProjectConfigRequest.h"
#import "FIRGetProjectConfigResponse.h"
#import "FIRSendVerificationCodeRequest.h"
#import "FIRSendVerificationCodeResponse.h"
#import "FIRVerifyClientRequest.h"
#import "FIRVerifyClientResponse.h"

NS_ASSUME_NONNULL_BEGIN

/** @typedef FIRVerifyClientCallback
    @brief The callback invoked at the end of a client verification flow.
    @param appCredential credential that proves the identity of the app during a phone
        authentication flow.
    @param error The error that occured while verifying the app, if any.
 */
typedef void (^FIRVerifyClientCallback)(FIRAuthAppCredential *_Nullable appCredential,
                                        NSError *_Nullable error);

/** @typedef FIRReCAPTCHAURLCallBack
    @brief The callback invoked at the end of the flow to fetch a reCAPTCHA URL.
    @param reCAPTCHAURL The reCAPTCHA URL.
    @param error The error that occured while fetching the reCAPTCHAURL, if any.
 */
typedef void (^FIRReCAPTCHAURLCallBack)(NSURL *_Nullable reCAPTCHAURL,
                                        NSError *_Nullable error);

/** @typedef FIRFetchAuthDomainCallback
    @brief The callback invoked at the end of the flow to fetch the Auth domain.
    @param authDomain The Auth domain.
    @param error The error that occured while fetching the auth domain, if any.
 */
typedef void (^FIRFetchAuthDomainCallback)(NSString *_Nullable authDomain,
                                        NSError *_Nullable error);
/** @var kAuthDomainSuffix
    @brief The suffix of the auth domain pertiaining to a given Firebase project.
 */
static NSString *const kAuthDomainSuffix = @"firebaseapp.com";

/** @var kauthTypeVerifyApp
    @brief The auth type to be specified in the app verification request.
 */
static NSString *const kAuthTypeVerifyApp = @"verifyApp";

/** @var kReCAPTCHAURLStringFormat
    @brief The format of the URL used to open the reCAPTCHA page during app verification.
 */
NSString *const kReCAPTCHAURLStringFormat =
    @"https://%@/__/auth/handler?apiKey=%@&authType=%@&ibi=%@&clientID=%@&hl=%@&v=iOS-Firebase-"
    "Auth/%s";

@implementation FIRPhoneAuthProvider {

  /** @var _auth
      @brief The auth instance used to for verifying the phone number.
   */
  FIRAuth *_auth;
}

/** @fn initWithAuth:
    @brief returns an instance of @c FIRPhoneAuthProvider assocaited with the provided auth
          instance.
    @return An Instance of @c FIRPhoneAuthProvider.
   */
- (nullable instancetype)initWithAuth:(FIRAuth *)auth {
  self = [super init];
  if (self) {
    _auth = auth;
  }
  return self;
}

- (void)verifyPhoneNumber:(NSString *)phoneNumber
               completion:(nullable FIRVerificationResultCallback)completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    FIRVerificationResultCallback callBackOnMainThread = ^(NSString *_Nullable verificationID,
                                                           NSError *_Nullable error) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(verificationID, error);
        });
      }
    };

    if (!phoneNumber.length) {
      callBackOnMainThread(nil,
                           [FIRAuthErrorUtils missingPhoneNumberErrorWithMessage:nil]);
      return;
    }
    [_auth.notificationManager checkNotificationForwardingWithCallback:
        ^(BOOL isNotificationBeingForwarded) {
      if (!isNotificationBeingForwarded) {
        callBackOnMainThread(nil, [FIRAuthErrorUtils notificationNotForwardedError]);
        return;
      }
      [self verifyClientAndSendVerificationCodeToPhoneNumber:phoneNumber
                                 retryOnInvalidAppCredential:YES
                                                    callback:callBackOnMainThread];
    }];
  });
}

- (void)verifyPhoneNumber:(NSString *)phoneNumber
               UIDelegate:(nullable id<FIRAuthUIDelegate>)UIDelegate
               completion:(nullable FIRVerificationResultCallback)completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    FIRVerificationResultCallback callBackOnMainThread = ^(NSString *_Nullable verificationID,
                                                           NSError *_Nullable error) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(verificationID, error);
        });
      }
    };

    [self reCAPTCHAURLWithCompletion:^(NSURL *_Nullable reCAPTCHAURL,
                                    NSError *_Nullable error) {
      if (error) {
        callBackOnMainThread(nil, error);
        return;
      }
      [_auth verifyAppWithURL:reCAPTCHAURL
                   UIDelegate:UIDelegate
                   completion:^(NSString *_Nullable reCAPTCHAToken,
                                NSError *_Nullable error) {
        if (error) {
          callBackOnMainThread(nil, error);
          return;
        }
        FIRSendVerificationCodeRequest *request =
          [[FIRSendVerificationCodeRequest alloc] initWithPhoneNumber:phoneNumber
                                                        appCredential:nil
                                                       reCAPTCHAToken:reCAPTCHAToken
                                                 requestConfiguration:_auth.requestConfiguration];
        [FIRAuthBackend sendVerificationCode:request
                                    callback:^(FIRSendVerificationCodeResponse *_Nullable response,
                                               NSError *_Nullable error) {
          if (error) {
            callBackOnMainThread(nil, error);
            return;
          }
          // Associate the phone number with the verification ID.
          response.verificationID.fir_authPhoneNumber = phoneNumber;
          callBackOnMainThread(response.verificationID, nil);
        }];
      }];
    }];
  });
}

- (FIRPhoneAuthCredential *)credentialWithVerificationID:(NSString *)verificationID
                                        verificationCode:(NSString *)verificationCode {
  return [[FIRPhoneAuthCredential alloc] initWithProviderID:FIRPhoneAuthProviderID
                                             verificationID:verificationID
                                           verificationCode:verificationCode];
}

+ (instancetype)provider {
  return [[self alloc]initWithAuth:[FIRAuth auth]];
}

+ (instancetype)providerWithAuth:(FIRAuth *)auth {
  return [[self alloc]initWithAuth:auth];
}

#pragma mark - Internal Methods

/** @fn verifyClientAndSendVerificationCodeToPhoneNumber:retryOnInvalidAppCredential:callback:
    @brief Starts the flow to verify the client via silent push notification.
    @param retryOnInvalidAppCredential Whether of not the flow should be retried if an
        FIRAuthErrorCodeInvalidAppCredential error is returned from the backend.
    @param phoneNumber The phone number to be verified.
    @param callback The callback to be invoked on the global work queue when the flow is
        finished.
 */
- (void)verifyClientAndSendVerificationCodeToPhoneNumber:(NSString *)phoneNumber
                             retryOnInvalidAppCredential:(BOOL)retryOnInvalidAppCredential
                                                callback:(FIRVerificationResultCallback)callback {
  [self verifyClientWithCompletion:^(FIRAuthAppCredential *_Nullable appCredential,
                                     NSError *_Nullable error) {
    if (error) {
      callback(nil, error);
      return;
    }
    FIRSendVerificationCodeRequest *request =
        [[FIRSendVerificationCodeRequest alloc] initWithPhoneNumber:phoneNumber
                                                     appCredential:appCredential
                                                    reCAPTCHAToken:nil
                                              requestConfiguration:_auth.requestConfiguration];
    [FIRAuthBackend sendVerificationCode:request
                                callback:^(FIRSendVerificationCodeResponse *_Nullable response,
                                           NSError *_Nullable error) {
      if (error) {
        if (error.code == FIRAuthErrorCodeInvalidAppCredential) {
          if (retryOnInvalidAppCredential) {
            [_auth.appCredentialManager clearCredential];
            [self verifyClientAndSendVerificationCodeToPhoneNumber:phoneNumber
                                       retryOnInvalidAppCredential:NO
                                                          callback:callback];
            return;
          }
          callback(nil, [FIRAuthErrorUtils unexpectedResponseWithDeserializedResponse:nil
                                                                      underlyingError:error]);
          return;
        }
        callback(nil, error);
        return;
      }
      // Associate the phone number with the verification ID.
      response.verificationID.fir_authPhoneNumber = phoneNumber;
      callback(response.verificationID, nil);
    }];
  }];
}

/** @fn verifyClientWithCompletion:completion:
    @brief Continues the flow to verify the client via silent push notification.
    @param completion The callback to be invoked when the client verification flow is finished.
 */
- (void)verifyClientWithCompletion:(FIRVerifyClientCallback)completion {
  if (_auth.appCredentialManager.credential) {
    completion(_auth.appCredentialManager.credential, nil);
    return;
  }
  [_auth.tokenManager getTokenWithCallback:^(FIRAuthAPNSToken *_Nullable token) {
    FIRVerifyClientRequest *request =
        [[FIRVerifyClientRequest alloc] initWithAppToken:token.string
                                               isSandbox:token.type == FIRAuthAPNSTokenTypeSandbox
                                    requestConfiguration:_auth.requestConfiguration];
    [FIRAuthBackend verifyClient:request callback:^(FIRVerifyClientResponse *_Nullable response,
                                                    NSError *_Nullable error) {
      if (error) {
        completion(nil, error);
        return;
      }
      NSTimeInterval timeout = [response.suggestedTimeOutDate timeIntervalSinceNow];
      [_auth.appCredentialManager
          didStartVerificationWithReceipt:response.receipt
                                  timeout:timeout
                                 callback:^(FIRAuthAppCredential *credential) {
        if (!credential.secret) {
          FIRLogWarning(kFIRLoggerAuth, @"I-AUT000014",
                        @"Failed to receive remote notification to verify app identity within "
                        @"%.0f second(s)", timeout);
        }
        completion(credential, nil);
      }];
    }];
  }];
}

- (void)reCAPTCHAURLWithCompletion:(FIRReCAPTCHAURLCallBack)completion {
  [self fetchAuthDomainWithCompletion:^(NSString *_Nullable authDomain,
                                        NSError *_Nullable error) {
    if (error) {
      completion(nil, error);
      return;
    }
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    NSString *clienID = _auth.app.options.clientID;
    NSString *apiKey = _auth.requestConfiguration.APIKey;
    NSString *languageCode = _auth.requestConfiguration.languageCode ?: @"en";
    NSString *URLString =
        [NSString stringWithFormat:kReCAPTCHAURLStringFormat,authDomain,
                                                             apiKey,
                                                             kAuthTypeVerifyApp,
                                                             bundleID,
                                                             clienID,
                                                             languageCode,
                                                             FirebaseAuthVersionString];

    completion([NSURL URLWithString:URLString], nil);
  }];
}

- (void)fetchAuthDomainWithCompletion:(FIRFetchAuthDomainCallback)completion {
  FIRGetProjectConfigRequest *request =
      [[FIRGetProjectConfigRequest alloc] initWithRequestConfiguration:_auth.requestConfiguration];

  [FIRAuthBackend getProjectConfig:request
                          callback:^(FIRGetProjectConfigResponse *_Nullable response,
                                     NSError *_Nullable error) {
    if (error) {
      completion(nil, error);
      return;
    }
    NSString *authDomain;
    for (NSString *domain in response.authorizedDomains) {
      NSInteger index = domain.length - kAuthDomainSuffix.length;
      if (index >= 2) {
        if ([kAuthDomainSuffix isEqualToString:[domain substringFromIndex:index]]) {
          authDomain = domain;
          break;
        }
      }
    }
    if (!authDomain.length) {
      completion(nil, [FIRAuthErrorUtils unexpectedErrorResponseWithDeserializedResponse:response]);
      return;
    }
    completion(authDomain, nil);
  }];
}

@end

NS_ASSUME_NONNULL_END
