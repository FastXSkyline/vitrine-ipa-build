// Authorized music downloader backed by Openverse's openly licensed audio index.
// Only high-confidence title/artist/duration matches with an allowlisted license are downloaded.
#import "Core/SGCore.h"
#import "SGRTrackLinks.h"
#import <math.h>
#import <Security/Security.h>

static NSString *SGRNormalizedMusicText(NSString *value) {
    NSString *folded = [[(value ?: @"") stringByFoldingWithOptions:NSDiacriticInsensitiveSearch
                                                            locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]] lowercaseString];
    NSCharacterSet *separators = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSArray<NSString *> *rawTokens = [folded componentsSeparatedByCharactersInSet:separators];
    NSSet<NSString *> *noise = [NSSet setWithArray:@[
        @"official", @"audio", @"video", @"lyrics", @"lyric", @"remastered", @"remaster",
        @"visualizer", @"visualiser", @"topic", @"hd", @"uhd", @"full", @"version"
    ]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in rawTokens) {
        if (!token.length || [noise containsObject:token]) continue;
        [tokens addObject:token];
    }
    return [tokens componentsJoinedByString:@" "];
}

static double SGRTextSimilarityForStrings(NSString *left, NSString *right) {
    NSString *a = SGRNormalizedMusicText(left);
    NSString *b = SGRNormalizedMusicText(right);
    if (!a.length || !b.length) return 0.0;
    if ([a isEqualToString:b]) return 1.0;

    NSArray<NSString *> *aTokens = [a componentsSeparatedByString:@" "];
    NSArray<NSString *> *bTokens = [b componentsSeparatedByString:@" "];
    NSSet<NSString *> *aSet = [NSSet setWithArray:aTokens];
    NSSet<NSString *> *bSet = [NSSet setWithArray:bTokens];
    NSUInteger shared = 0;
    for (NSString *token in aSet) {
        if ([bSet containsObject:token]) shared++;
    }
    NSUInteger denominator = MAX(aSet.count, bSet.count);
    return denominator ? (double)shared / (double)denominator : 0.0;
}

static double SGRTitleSimilarity(NSString *requestedTitle, NSString *candidateTitle) {
    double best = SGRTextSimilarityForStrings(requestedTitle, candidateTitle);
    // Some open-music sources prepend the creator to the title.
    for (NSString *separator in @[@" - ", @" – ", @" — ", @" | "]) {
        NSArray<NSString *> *parts = [candidateTitle componentsSeparatedByString:separator];
        for (NSString *part in parts) {
            best = MAX(best, SGRTextSimilarityForStrings(requestedTitle, part));
        }
    }
    return best;
}

static double SGRArtistSimilarity(NSString *requestedArtist, NSString *candidateCreator) {
    double best = SGRTextSimilarityForStrings(requestedArtist, candidateCreator);
    for (NSString *separator in @[@", ", @" & ", @" and ", @" feat. ", @" featuring ", @" ft. "]) {
        NSArray<NSString *> *parts = [candidateCreator componentsSeparatedByString:separator];
        for (NSString *part in parts) {
            best = MAX(best, SGRTextSimilarityForStrings(requestedArtist, part));
        }
    }
    return best;
}

static BOOL SGRHasAllowedOpenLicense(NSDictionary *item) {
    id licenseValue = item[@"license"];
    NSString *license = [licenseValue isKindOfClass:NSString.class] ? [(NSString *)licenseValue lowercaseString] : @"";
    NSString *licenseURL = [item[@"license_url"] isKindOfClass:NSString.class] ? item[@"license_url"] : @"";
    NSURLComponents *components = [NSURLComponents componentsWithString:licenseURL];
    if (![components.scheme.lowercaseString isEqualToString:@"https"] ||
        ![components.host.lowercaseString isEqualToString:@"creativecommons.org"]) {
        return NO;
    }

    if ([license isEqualToString:@"cc0"]) {
        return [licenseURL containsString:@"/publicdomain/zero/"];
    }
    if ([license isEqualToString:@"pdm"]) {
        return [licenseURL containsString:@"/publicdomain/mark/"];
    }
    if ([license isEqualToString:@"by"]) {
        return [licenseURL containsString:@"/licenses/by/"];
    }
    if ([license isEqualToString:@"by-sa"]) {
        return [licenseURL containsString:@"/licenses/by-sa/"];
    }
    return NO;
}

static NSString *SGRFileTypeFromURL(NSString *urlString) {
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString ?: @""];
    NSString *extension = components.URL.path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"aif"]) return @"aiff";
    if ([extension isEqualToString:@"oga"]) return @"ogg";
    return extension ?: @"";
}

static NSString *SGRNormalizedFileType(NSString *type, NSString *urlString) {
    NSString *extension = [[(type ?: @"") stringByTrimmingCharactersInSet:
                            [NSCharacterSet characterSetWithCharactersInString:@". "]] lowercaseString];
    if (!extension.length) extension = SGRFileTypeFromURL(urlString);
    if ([extension isEqualToString:@"aif"]) extension = @"aiff";
    if ([extension isEqualToString:@"oga"]) extension = @"ogg";
    NSSet<NSString *> *allowed = [NSSet setWithArray:@[@"flac", @"wav", @"aiff", @"alac", @"ape", @"wv",
                                                         @"mp3", @"m4a", @"aac", @"ogg", @"opus"]];
    return [allowed containsObject:extension] ? extension : @"";
}

static NSInteger SGRFormatTier(NSString *type) {
    if ([type isEqualToString:@"flac"] || [type isEqualToString:@"alac"] ||
        [type isEqualToString:@"ape"] || [type isEqualToString:@"wv"]) return 3;
    if ([type isEqualToString:@"wav"] || [type isEqualToString:@"aiff"]) return 3;
    return 1;
}

static NSString *SGRSafeFilenameComponent(NSString *value) {
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    NSArray<NSString *> *parts = [(value ?: @"") componentsSeparatedByCharactersInSet:invalid];
    NSString *safe = [[parts componentsJoinedByString:@"-"]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([safe containsString:@"  "]) safe = [safe stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    if (safe.length > 100) safe = [safe substringToIndex:100];
    return safe.length ? safe : @"Track";
}

static NSArray<NSDictionary *> *SGRDownloadOptionsForItem(NSDictionary *item) {
    NSMutableArray<NSDictionary *> *options = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *rawOptions = [NSMutableArray array];

    if ([item[@"url"] isKindOfClass:NSString.class]) {
        [rawOptions addObject:@{
            @"url": item[@"url"],
            @"filetype": [item[@"filetype"] isKindOfClass:NSString.class] ? item[@"filetype"] : @"",
            @"bit_rate": [item[@"bit_rate"] respondsToSelector:@selector(doubleValue)] ? item[@"bit_rate"] : @0,
            @"sample_rate": [item[@"sample_rate"] respondsToSelector:@selector(doubleValue)] ? item[@"sample_rate"] : @0
        }];
    }
    if ([item[@"alt_files"] isKindOfClass:NSArray.class]) {
        for (id candidate in (NSArray *)item[@"alt_files"]) {
            if (![candidate isKindOfClass:NSDictionary.class] || ![candidate[@"url"] isKindOfClass:NSString.class]) continue;
            [rawOptions addObject:@{
                @"url": candidate[@"url"],
                @"filetype": [candidate[@"filetype"] isKindOfClass:NSString.class] ? candidate[@"filetype"] : @"",
                @"bit_rate": [candidate[@"bit_rate"] respondsToSelector:@selector(doubleValue)] ? candidate[@"bit_rate"] : @0,
                @"sample_rate": [candidate[@"sample_rate"] respondsToSelector:@selector(doubleValue)] ? candidate[@"sample_rate"] : @0
            }];
        }
    }

    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];
    for (NSDictionary *raw in rawOptions) {
        NSString *urlString = raw[@"url"];
        NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
        NSString *type = SGRNormalizedFileType(raw[@"filetype"], urlString);
        if (!components.URL || ![components.scheme.lowercaseString isEqualToString:@"https"] ||
            !components.host.length || !type.length || [seenURLs containsObject:urlString]) {
            continue;
        }
        [seenURLs addObject:urlString];
        [options addObject:@{
            @"url": urlString,
            @"filetype": type,
            @"bit_rate": raw[@"bit_rate"] ?: @0,
            @"sample_rate": raw[@"sample_rate"] ?: @0
        }];
    }

    [options sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger tierA = SGRFormatTier(a[@"filetype"]);
        NSInteger tierB = SGRFormatTier(b[@"filetype"]);
        if (tierA != tierB) return tierA > tierB ? NSOrderedAscending : NSOrderedDescending;
        double bitrateA = [a[@"bit_rate"] doubleValue];
        double bitrateB = [b[@"bit_rate"] doubleValue];
        if (bitrateA != bitrateB) return bitrateA > bitrateB ? NSOrderedAscending : NSOrderedDescending;
        double sampleA = [a[@"sample_rate"] doubleValue];
        double sampleB = [b[@"sample_rate"] doubleValue];
        if (sampleA != sampleB) return sampleA > sampleB ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return options;
}


static NSString * const kSGROpenverseKeychainService = @"com.fastx.vitrine.openverse";
static NSString * const kSGROpenverseClientIDAccount = @"client-id";
static NSString * const kSGROpenverseClientSecretAccount = @"client-secret";

static NSString *SGROpenverseKeychainRead(NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kSGROpenverseKeychainService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL SGROpenverseKeychainWrite(NSString *account, NSString *value) {
    NSData *data = [(value ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return NO;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kSGROpenverseKeychainService,
        (__bridge id)kSecAttrAccount: account
    };
    NSDictionary *updates = @{(__bridge id)kSecValueData: data};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)updates);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *attributes = [query mutableCopy];
        attributes[(__bridge id)kSecValueData] = data;
        attributes[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        status = SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
    }
    return status == errSecSuccess;
}

static NSString *SGRFormURLEncode(NSString *value) {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"-._*"];
    NSString *encoded = [(value ?: @"") stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    return [encoded stringByReplacingOccurrencesOfString:@"%20" withString:@"+"];
}

@interface SGRTrackLinksController : UITableViewController
- (instancetype)initWithTitle:(NSString *)title
                        artist:(NSString *)artist
                      trackURI:(NSString *)trackURI
                      duration:(NSTimeInterval)duration;
@end

@implementation SGRTrackLinksController {
    NSString *_trackTitle;
    NSString *_artistName;
    NSString *_trackURI;
    NSTimeInterval _duration;
    NSURLSession *_session;
    NSURLSessionTask *_task;
    NSUInteger _generation;
    BOOL _loading;
    BOOL _started;
    NSString *_statusMessage;
    NSDictionary *_selectedTrack;
    NSArray<NSDictionary *> *_downloadFiles;
    NSURL *_downloadedFileURL;
    NSURL *_sourceURL;
    NSURL *_licenseURL;
    NSString *_downloadedDisplayName;
    NSString *_openverseClientID;
    NSString *_openverseClientSecret;
    NSString *_openverseAccessToken;
    NSDate *_openverseTokenExpiry;
    BOOL _credentialPromptVisible;
}

- (instancetype)initWithTitle:(NSString *)title
                        artist:(NSString *)artist
                      trackURI:(NSString *)trackURI
                      duration:(NSTimeInterval)duration {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _trackTitle = [title copy] ?: @"";
    _artistName = [artist copy] ?: @"";
    _trackURI = [trackURI copy] ?: @"";
    _duration = duration;
    _statusMessage = @"Ready to find an openly licensed copy.";
    _openverseClientID = SGROpenverseKeychainRead(kSGROpenverseClientIDAccount);
    _openverseClientSecret = SGROpenverseKeychainRead(kSGROpenverseClientSecretAccount);
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 45.0;
    configuration.timeoutIntervalForResource = 900.0;
    _session = [NSURLSession sessionWithConfiguration:configuration];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Authorized Download";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76.0;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Retry"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(resolveCurrentTrack)];

    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 320, 112)];
    footer.text = @"Only close title, artist and duration matches with CC0, CC BY, CC BY-SA or Public Domain metadata are downloaded. The best available listed audio format is selected, and attribution is saved beside the file. Openverse indexes third-party uploads and cannot independently guarantee every license claim; use Source & License to review the original record.";
    footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footer.textColor = UIColor.secondaryLabelColor;
    footer.numberOfLines = 0;
    footer.textAlignment = NSTextAlignmentCenter;
    footer.frame = CGRectMake(0, 0, MAX(0, CGRectGetWidth(self.tableView.bounds) - 36), 112);
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableFooterView = footer;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_started) return;
    _started = YES;
    [self resolveCurrentTrack];
}

- (void)close {
    _generation++;
    [_task cancel];
    [_session invalidateAndCancel];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)presentOpenverseCredentialPrompt {
    if (_credentialPromptVisible || self.isBeingDismissed || self.isBeingPresented) return;
    _credentialPromptVisible = YES;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Openverse API setup"
                         message:@"Openverse returned HTTP 401. Register a free API application, verify your email, then paste its Client ID and Client Secret here. The secret is stored in the iOS Keychain, not in the repository."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Client ID";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Client Secret";
        field.secureTextEntry = YES;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Open API docs" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) self = weakSelf;
        if (!self) return;
        self->_credentialPromptVisible = NO;
        NSURL *url = [NSURL URLWithString:@"https://api.openverse.org/v1/"];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        typeof(self) self = weakSelf;
        if (!self) return;
        self->_credentialPromptVisible = NO;
        self->_loading = NO;
        self->_statusMessage = @"Openverse requires API credentials for this request. Tap Retry after setup.";
        [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save & Retry" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) self = weakSelf;
        if (!self) return;
        self->_credentialPromptVisible = NO;
        NSString *clientID = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
                             NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *clientSecret = [alert.textFields.lastObject.text stringByTrimmingCharactersInSet:
                                  NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!clientID.length || !clientSecret.length) {
            self->_loading = NO;
            self->_statusMessage = @"Both Openverse credential fields are required.";
            [self.tableView reloadData];
            return;
        }

        self->_openverseClientID = clientID;
        self->_openverseClientSecret = clientSecret;
        self->_openverseAccessToken = nil;
        self->_openverseTokenExpiry = nil;
        BOOL idSaved = SGROpenverseKeychainWrite(kSGROpenverseClientIDAccount, clientID);
        BOOL secretSaved = SGROpenverseKeychainWrite(kSGROpenverseClientSecretAccount, clientSecret);
        if (!idSaved || !secretSaved) {
            UIAlertController *notice = [UIAlertController
                alertControllerWithTitle:@"Keychain storage unavailable"
                                 message:@"The credentials will be used for this session only. If setup is required again after restarting the app, enter them again."
                          preferredStyle:UIAlertControllerStyleAlert];
            [notice addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:notice animated:YES completion:^{
                [self resolveCurrentTrack];
            }];
            return;
        }
        [self resolveCurrentTrack];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)requestOpenverseTokenForGeneration:(NSUInteger)generation
                                completion:(void (^)(NSString *token, NSTimeInterval expiresIn, NSString *errorMessage))completion {
    if (!_openverseClientID.length || !_openverseClientSecret.length) {
        completion(nil, 0, @"Openverse API credentials are missing.");
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://api.openverse.org/v1/auth_tokens/token/"];
    if (!url) {
        completion(nil, 0, @"Could not create the Openverse authentication request.");
        return;
    }

    NSString *body = [NSString stringWithFormat:@"grant_type=client_credentials&client_id=%@&client_secret=%@",
                      SGRFormURLEncode(_openverseClientID), SGRFormURLEncode(_openverseClientSecret)];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:30.0];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    __weak typeof(self) weakSelf = self;
    _task = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self->_generation != generation) return;
            if (error) {
                if (error.code == NSURLErrorCancelled) return;
                completion(nil, 0, @"Could not reach Openverse's authentication endpoint. Check the connection and retry.");
                return;
            }

            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            NSError *jsonError = nil;
            id payload = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
            NSDictionary *dictionary = [payload isKindOfClass:NSDictionary.class] ? payload : nil;
            NSString *token = [dictionary[@"access_token"] isKindOfClass:NSString.class] ? dictionary[@"access_token"] : @"";
            NSTimeInterval expiresIn = [dictionary[@"expires_in"] respondsToSelector:@selector(doubleValue)]
                ? [dictionary[@"expires_in"] doubleValue] : 36000.0;
            if (!http || http.statusCode < 200 || http.statusCode >= 300 || jsonError || !token.length) {
                NSString *detail = [dictionary[@"detail"] isKindOfClass:NSString.class] ? dictionary[@"detail"] :
                                    ([dictionary[@"error_description"] isKindOfClass:NSString.class] ? dictionary[@"error_description"] : @"");
                NSString *message = detail.length
                    ? [NSString stringWithFormat:@"Openverse authentication failed (HTTP %ld): %@. Check the Client ID/Secret and verify the registered email.", (long)(http.statusCode), detail]
                    : [NSString stringWithFormat:@"Openverse authentication failed (HTTP %ld). Check the Client ID/Secret and verify the registered email.", (long)(http.statusCode)];
                completion(nil, 0, message);
                return;
            }
            completion(token, MAX(60.0, expiresIn), nil);
        });
    }];
    [_task resume];
}

- (void)resolveCurrentTrack {
    _generation++;
    NSUInteger generation = _generation;
    [_task cancel];
    _task = nil;
    _loading = YES;
    _selectedTrack = nil;
    _downloadFiles = @[];
    _downloadedFileURL = nil;
    _sourceURL = nil;
    _licenseURL = nil;
    _downloadedDisplayName = nil;
    _statusMessage = @"Searching the open-license audio index…";
    [self.tableView reloadData];

    if (!SGRNormalizedMusicText(_trackTitle).length || !SGRNormalizedMusicText(_artistName).length) {
        _loading = NO;
        _statusMessage = @"The current track is missing its title or artist. Nothing was downloaded.";
        [self.tableView reloadData];
        return;
    }

    if (_openverseClientID.length && _openverseClientSecret.length &&
        (!_openverseAccessToken.length || !_openverseTokenExpiry || _openverseTokenExpiry.timeIntervalSinceNow < 60.0)) {
        _statusMessage = @"Authenticating with Openverse…";
        [self.tableView reloadData];
        __weak typeof(self) weakSelf = self;
        [self requestOpenverseTokenForGeneration:generation completion:^(NSString *token, NSTimeInterval expiresIn, NSString *errorMessage) {
            typeof(self) self = weakSelf;
            if (!self || self->_generation != generation) return;
            if (!token.length) {
                self->_loading = NO;
                self->_statusMessage = errorMessage ?: @"Openverse authentication failed.";
                [self.tableView reloadData];
                return;
            }
            self->_openverseAccessToken = token;
            self->_openverseTokenExpiry = [NSDate dateWithTimeIntervalSinceNow:expiresIn - 60.0];
            [self resolveCurrentTrack];
        }];
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://api.openverse.org/v1/audio/"];
    NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"title" value:_trackTitle],
        [NSURLQueryItem queryItemWithName:@"creator" value:_artistName],
        [NSURLQueryItem queryItemWithName:@"license" value:@"cc0,by,by-sa,pdm"],
        [NSURLQueryItem queryItemWithName:@"category" value:@"music"],
        [NSURLQueryItem queryItemWithName:@"page_size" value:@"50"],
        [NSURLQueryItem queryItemWithName:@"filter_dead" value:@"true"],
        [NSURLQueryItem queryItemWithName:@"excluded_source" value:@"jamendo,audius"]
    ]];
    components.queryItems = query;
    if (!components.URL) {
        _loading = NO;
        _statusMessage = @"Could not create the search request. Nothing was downloaded.";
        [self.tableView reloadData];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:45.0];
    request.HTTPMethod = @"GET";
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"VitrineAuthorizedMusic/1.0" forHTTPHeaderField:@"User-Agent"];
    if (_openverseAccessToken.length && _openverseTokenExpiry.timeIntervalSinceNow > 0) {
        [request setValue:[@"Bearer " stringByAppendingString:_openverseAccessToken] forHTTPHeaderField:@"Authorization"];
    }

    __weak typeof(self) weakSelf = self;
    _task = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self->_generation != generation) return;
            if (error) {
                if (error.code == NSURLErrorCancelled) return;
                self->_loading = NO;
                self->_statusMessage = @"The open-license index is unavailable right now. Retry later; no file was downloaded.";
                [self.tableView reloadData];
                return;
            }

            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            NSError *jsonError = nil;
            id payload = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
            NSArray *results = [payload isKindOfClass:NSDictionary.class] && [payload[@"results"] isKindOfClass:NSArray.class]
                ? payload[@"results"] : nil;
            if (http.statusCode == 401) {
                self->_loading = NO;
                if (self->_openverseClientID.length && self->_openverseClientSecret.length) {
                    self->_openverseAccessToken = nil;
                    self->_openverseTokenExpiry = nil;
                    self->_statusMessage = @"Openverse rejected the access token. Tap Retry to refresh it; if this repeats, verify your API credentials and email.";
                    [self.tableView reloadData];
                } else {
                    self->_statusMessage = @"Openverse returned HTTP 401. API credentials are needed to continue.";
                    [self.tableView reloadData];
                    [self presentOpenverseCredentialPrompt];
                }
                return;
            }
            if (!http || http.statusCode < 200 || http.statusCode >= 300 || jsonError || !results) {
                self->_loading = NO;
                NSString *detail = [payload[@"detail"] isKindOfClass:NSString.class] ? payload[@"detail"] : @"";
                self->_statusMessage = detail.length
                    ? [NSString stringWithFormat:@"Openverse returned HTTP %ld: %@.", (long)(http.statusCode), detail]
                    : [NSString stringWithFormat:@"The open-license index returned no usable results (HTTP %ld). Retry later.", (long)(http.statusCode)];
                [self.tableView reloadData];
                return;
            }

            NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
            for (id candidate in results) {
                if (![candidate isKindOfClass:NSDictionary.class]) continue;
                NSDictionary *item = candidate;
                NSString *provider = [item[@"provider"] isKindOfClass:NSString.class] ? [item[@"provider"] lowercaseString] : @"";
                NSString *source = [item[@"source"] isKindOfClass:NSString.class] ? [item[@"source"] lowercaseString] : @"";
                if ([provider containsString:@"jamendo"] || [source containsString:@"jamendo"] ||
                    [provider containsString:@"audius"] || [source containsString:@"audius"]) continue;
                if (!SGRHasAllowedOpenLicense(item)) continue;

                NSString *candidateTitle = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
                NSString *candidateCreator = [item[@"creator"] isKindOfClass:NSString.class] ? item[@"creator"] : @"";
                double titleScore = SGRTitleSimilarity(self->_trackTitle, candidateTitle);
                double artistScore = SGRArtistSimilarity(self->_artistName, candidateCreator);
                if (titleScore < 0.88 || artistScore < 0.72) continue;

                double candidateDuration = [item[@"duration"] respondsToSelector:@selector(doubleValue)]
                    ? [item[@"duration"] doubleValue] / 1000.0 : 0.0;
                if (self->_duration > 0.0 && candidateDuration > 0.0) {
                    double allowedDelta = MAX(12.0, self->_duration * 0.07);
                    if (fabs(candidateDuration - self->_duration) > allowedDelta) continue;
                }

                NSArray<NSDictionary *> *fileOptions = SGRDownloadOptionsForItem(item);
                if (!fileOptions.count) continue;
                [matches addObject:@{
                    @"item": item,
                    @"titleScore": @(titleScore),
                    @"artistScore": @(artistScore),
                    @"score": @(titleScore * 0.58 + artistScore * 0.42),
                    @"files": fileOptions
                }];
            }

            [matches sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                double scoreA = [a[@"score"] doubleValue];
                double scoreB = [b[@"score"] doubleValue];
                if (scoreA != scoreB) return scoreA > scoreB ? NSOrderedAscending : NSOrderedDescending;
                double artistA = [a[@"artistScore"] doubleValue];
                double artistB = [b[@"artistScore"] doubleValue];
                if (artistA != artistB) return artistA > artistB ? NSOrderedAscending : NSOrderedDescending;
                return NSOrderedSame;
            }];

            NSDictionary *best = matches.firstObject;
            if (!best) {
                self->_loading = NO;
                self->_statusMessage = @"No exact openly licensed download matched this song. Nothing was downloaded; unrelated tracks are never substituted.";
                [self.tableView reloadData];
                return;
            }

            self->_selectedTrack = best[@"item"];
            self->_downloadFiles = best[@"files"];
            NSString *landingURL = [self->_selectedTrack[@"foreign_landing_url"] isKindOfClass:NSString.class]
                ? self->_selectedTrack[@"foreign_landing_url"] : @"";
            NSURLComponents *landingComponents = [NSURLComponents componentsWithString:landingURL];
            if ([landingComponents.scheme.lowercaseString isEqualToString:@"https"] && landingComponents.host.length) {
                self->_sourceURL = landingComponents.URL;
            }
            NSString *licenseURL = self->_selectedTrack[@"license_url"];
            NSURLComponents *licenseComponents = [NSURLComponents componentsWithString:licenseURL ?: @""];
            if ([licenseComponents.scheme.lowercaseString isEqualToString:@"https"] && licenseComponents.host.length) {
                self->_licenseURL = licenseComponents.URL;
            }

            NSString *matchedTitle = [self->_selectedTrack[@"title"] isKindOfClass:NSString.class]
                ? self->_selectedTrack[@"title"] : self->_trackTitle;
            NSString *matchedArtist = [self->_selectedTrack[@"creator"] isKindOfClass:NSString.class]
                ? self->_selectedTrack[@"creator"] : self->_artistName;
            NSString *format = self->_downloadFiles.firstObject[@"filetype"] ?: @"audio";
            self->_statusMessage = [NSString stringWithFormat:@"Exact licensed match: %@ — %@. Downloading best listed quality (%@)…",
                                    matchedArtist, matchedTitle, format.uppercaseString];
            [self.tableView reloadData];
            [self downloadFileAtIndex:0 generation:generation];
        });
    }];
    [_task resume];
}

- (void)downloadFileAtIndex:(NSUInteger)index generation:(NSUInteger)generation {
    if (generation != _generation) return;
    if (index >= _downloadFiles.count || !_selectedTrack) {
        _loading = NO;
        _statusMessage = @"The source did not provide a working direct download. No incomplete file was kept.";
        [self.tableView reloadData];
        return;
    }

    NSDictionary *fileOption = _downloadFiles[index];
    NSString *downloadString = fileOption[@"url"];
    NSURLComponents *downloadComponents = [NSURLComponents componentsWithString:downloadString ?: @""];
    if (![downloadComponents.scheme.lowercaseString isEqualToString:@"https"] || !downloadComponents.host.length) {
        [self downloadFileAtIndex:index + 1 generation:generation];
        return;
    }

    NSError *directoryError = nil;
    NSURL *supportURL = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                               inDomain:NSUserDomainMask
                                                      appropriateForURL:nil
                                                                 create:YES
                                                                  error:&directoryError];
    if (!supportURL) {
        _loading = NO;
        _statusMessage = @"Could not create the local download folder. Check available storage and retry.";
        [self.tableView reloadData];
        return;
    }
    NSURL *directoryURL = [[supportURL URLByAppendingPathComponent:@"Vitrine" isDirectory:YES]
                           URLByAppendingPathComponent:@"Music Downloads" isDirectory:YES];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        _loading = NO;
        _statusMessage = @"Could not create the local download folder. Check available storage and retry.";
        [self.tableView reloadData];
        return;
    }

    NSString *title = [self->_selectedTrack[@"title"] isKindOfClass:NSString.class]
        ? self->_selectedTrack[@"title"] : _trackTitle;
    NSString *creator = [self->_selectedTrack[@"creator"] isKindOfClass:NSString.class]
        ? self->_selectedTrack[@"creator"] : _artistName;
    NSString *safeBase = SGRSafeFilenameComponent([NSString stringWithFormat:@"%@ - %@", creator, title]);
    NSString *extension = fileOption[@"filetype"] ?: @"mp3";
    NSString *filename = [NSString stringWithFormat:@"%@.%@", safeBase, extension];
    NSURL *destinationURL = [directoryURL URLByAppendingPathComponent:filename];
    NSUInteger suffix = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:destinationURL.path]) {
        filename = [NSString stringWithFormat:@"%@ (%lu).%@", safeBase, (unsigned long)suffix, extension];
        destinationURL = [directoryURL URLByAppendingPathComponent:filename];
        suffix++;
    }

    NSDictionary *trackSnapshot = [_selectedTrack copy];
    NSString *licenseText = [trackSnapshot[@"license"] isKindOfClass:NSString.class] ? trackSnapshot[@"license"] : @"";
    NSString *licenseURLText = [trackSnapshot[@"license_url"] isKindOfClass:NSString.class] ? trackSnapshot[@"license_url"] : @"";
    NSString *landingURLText = [trackSnapshot[@"foreign_landing_url"] isKindOfClass:NSString.class] ? trackSnapshot[@"foreign_landing_url"] : @"";
    NSString *creatorURLText = [trackSnapshot[@"creator_url"] isKindOfClass:NSString.class] ? trackSnapshot[@"creator_url"] : @"";
    NSString *trackURIText = [_trackURI copy] ?: @"";
    NSString *attribution = [NSString stringWithFormat:
        @"Title: %@\nCreator: %@\nOriginal source: %@\nCreator page: %@\nLicense: %@\nLicense URL: %@\nOriginal Spotify track URI: %@\nIndexed by: Openverse (https://openverse.org/)\n\nOpenverse does not independently verify license claims. Review the original source and license before reusing this audio.",
        title, creator, landingURLText, creatorURLText, licenseText, licenseURLText, trackURIText];
    NSURL *attributionURL = [[directoryURL URLByAppendingPathComponent:[destinationURL.lastPathComponent stringByAppendingString:@".txt"] isDirectory:NO] copy];

    _statusMessage = [NSString stringWithFormat:@"Downloading %@ at the best listed quality…", filename];
    _loading = YES;
    [self.tableView reloadData];

    NSURLRequest *request = [NSURLRequest requestWithURL:downloadComponents.URL
                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                         timeoutInterval:90.0];
    __weak typeof(self) weakSelf = self;
    _task = [_session downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        BOOL success = NO;
        NSError *finalError = error;
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (!finalError && (!http || http.statusCode < 200 || http.statusCode >= 300)) {
            finalError = [NSError errorWithDomain:@"SGRTrackDownload"
                                             code:http ? http.statusCode : -1
                                         userInfo:@{NSLocalizedDescriptionKey: @"The source did not return a downloadable audio file."}];
        }
        if (!finalError && location) {
            NSError *moveError = nil;
            if ([[NSFileManager defaultManager] moveItemAtURL:location toURL:destinationURL error:&moveError]) {
                NSError *attributionError = nil;
                [attribution writeToURL:attributionURL atomically:YES encoding:NSUTF8StringEncoding error:&attributionError];
                success = YES;
            } else {
                finalError = moveError;
            }
        } else if (!finalError) {
            finalError = [NSError errorWithDomain:@"SGRTrackDownload"
                                             code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"The download returned no file."}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self->_generation != generation) return;
            if (!success) {
                if (error.code == NSURLErrorCancelled) return;
                [self downloadFileAtIndex:index + 1 generation:generation];
                return;
            }

            self->_task = nil;
            self->_loading = NO;
            self->_downloadedFileURL = destinationURL;
            self->_downloadedDisplayName = filename;
            self->_statusMessage = [NSString stringWithFormat:@"Downloaded %@. Tap the file row to export or save it to Files.", filename];
            [self.tableView reloadData];
        });
    }];
    [_task resume];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _downloadedFileURL ? 2 : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseID = @"authorizedAudioDownload";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];

    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 3;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    if (_downloadedFileURL && indexPath.row == 0) {
        cell.textLabel.text = @"Download complete";
        cell.detailTextLabel.text = _downloadedDisplayName ?: _downloadedFileURL.lastPathComponent;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (_downloadedFileURL && indexPath.row == 1) {
        cell.textLabel.text = @"Source & license";
        NSString *creator = [_selectedTrack[@"creator"] isKindOfClass:NSString.class] ? _selectedTrack[@"creator"] : _artistName;
        NSString *license = [_selectedTrack[@"license"] isKindOfClass:NSString.class] ? _selectedTrack[@"license"] : @"open license";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@. Tap to review the original upload and license.", creator, license.uppercaseString];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    cell.textLabel.text = _loading ? @"Finding and downloading…" : @"No download available";
    cell.detailTextLabel.text = _statusMessage ?: @"Nothing has been downloaded.";
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_downloadedFileURL && indexPath.row == 0) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:_downloadedFileURL.path]) return;
        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[_downloadedFileURL]
                                                                             applicationActivities:nil];
        UIPopoverPresentationController *popover = activity.popoverPresentationController;
        if (popover) {
            popover.sourceView = self.view;
            popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        }
        [self presentViewController:activity animated:YES completion:nil];
        return;
    }
    if (_downloadedFileURL && indexPath.row == 1) {
        NSURL *target = _sourceURL ?: _licenseURL;
        if (target) [UIApplication.sharedApplication openURL:target options:@{} completionHandler:nil];
    }
}

@end

void SGRTrackLinksPresent(UIView *source, NSString *trackTitle, NSString *artistName, NSString *trackURI, NSTimeInterval duration) {
    // Wait for the player's UIMenu dismissal before starting another UIKit presentation.
    __weak UIView *weakSource = source;
    NSString *title = [trackTitle copy] ?: @"";
    NSString *artist = [artistName copy] ?: @"";
    NSString *uri = [trackURI copy] ?: @"";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *anchor = weakSource;
        UIWindow *window = anchor.window;
        UIViewController *presenter = window.rootViewController;
        if (!window || !presenter || presenter.isBeingDismissed) return;

        NSMutableSet<NSValue *> *visited = [NSMutableSet set];
        while (presenter.presentedViewController) {
            NSValue *identity = [NSValue valueWithNonretainedObject:presenter];
            if ([visited containsObject:identity]) break;
            [visited addObject:identity];
            presenter = presenter.presentedViewController;
        }
        if (presenter.isBeingDismissed || presenter.isBeingPresented) return;

        SGRTrackLinksController *page = [[SGRTrackLinksController alloc] initWithTitle:title
                                                                               artist:artist
                                                                             trackURI:uri
                                                                             duration:duration];
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        if (@available(iOS 15.0, *)) {
            navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
            navigation.sheetPresentationController.prefersGrabberVisible = YES;
        }
        SGPresentDark(navigation);
        [presenter presentViewController:navigation animated:YES completion:nil];
    });
}
