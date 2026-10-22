// Searches Internet Archive for tracks with explicit Creative Commons/public-domain metadata
// and downloads original MP3 files only. No YouTube stream extraction or format conversion.
#import "Core/SGCore.h"
#import "SGRTrackLinks.h"
#import <Security/Security.h>

static NSString * const kSGROldOpenverseKeychainService = @"com.fastx.vitrine.openverse";

static void SGRClearLegacyOpenverseCredentials(void) {
    for (NSString *account in @[@"client-id", @"client-secret"]) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: kSGROldOpenverseKeychainService,
            (__bridge id)kSecAttrAccount: account
        };
        SecItemDelete((__bridge CFDictionaryRef)query);
    }
}

static NSString *SGRStringValue(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            if ([item isKindOfClass:NSString.class] && [item length]) [parts addObject:item];
        }
        return [parts componentsJoinedByString:@", "];
    }
    return @"";
}

static NSString *SGRNormalizedMusicText(NSString *value) {
    NSString *folded = [[(value ?: @"") stringByFoldingWithOptions:NSDiacriticInsensitiveSearch
                                                           locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]] lowercaseString];
    NSCharacterSet *separators = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSArray<NSString *> *rawTokens = [folded componentsSeparatedByCharactersInSet:separators];
    NSSet<NSString *> *noise = [NSSet setWithArray:@[
        @"official", @"audio", @"video", @"lyrics", @"lyric", @"remastered", @"remaster",
        @"visualizer", @"visualiser", @"topic", @"hd", @"uhd", @"full", @"version",
        @"music", @"track", @"explicit", @"clean"
    ]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in rawTokens) {
        if (!token.length || [noise containsObject:token]) continue;
        [tokens addObject:token];
    }
    return [tokens componentsJoinedByString:@" "];
}

static double SGRTextSimilarity(NSString *left, NSString *right) {
    NSString *a = SGRNormalizedMusicText(left);
    NSString *b = SGRNormalizedMusicText(right);
    if (!a.length || !b.length) return 0.0;
    if ([a isEqualToString:b]) return 1.0;

    NSSet<NSString *> *aTokens = [NSSet setWithArray:[a componentsSeparatedByString:@" "]];
    NSSet<NSString *> *bTokens = [NSSet setWithArray:[b componentsSeparatedByString:@" "]];
    NSUInteger shared = 0;
    for (NSString *token in aTokens) if ([bTokens containsObject:token]) shared++;
    NSUInteger denominator = MAX(aTokens.count, bTokens.count);
    return denominator ? (double)shared / (double)denominator : 0.0;
}

static NSArray<NSString *> *SGRSearchTokens(NSString *value) {
    NSString *normalized = SGRNormalizedMusicText(value);
    if (!normalized.length) return @[];
    NSMutableArray<NSString *> *tokens = [[normalized componentsSeparatedByString:@" "] mutableCopy];
    NSIndexSet *shortTokens = [tokens indexesOfObjectsPassingTest:^BOOL(NSString *token, NSUInteger idx, BOOL *stop) {
        return token.length == 1;
    }];
    [tokens removeObjectsAtIndexes:shortTokens];
    return tokens;
}

static BOOL SGRHasAllowedLicenseURL(NSString *licenseURL) {
    NSURLComponents *components = [NSURLComponents componentsWithString:licenseURL ?: @""];
    NSString *scheme = components.scheme.lowercaseString;
    NSString *host = components.host.lowercaseString;
    NSString *path = components.path.lowercaseString;
    if (!([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) ||
        ![host isEqualToString:@"creativecommons.org"]) return NO;

    if ([path containsString:@"/publicdomain/zero/"] ||
        [path containsString:@"/publicdomain/mark/"]) return YES;

    for (NSString *license in @[@"by", @"by-sa", @"by-nc", @"by-nc-sa", @"by-nd", @"by-nc-nd"]) {
        if ([path containsString:[NSString stringWithFormat:@"/licenses/%@/", license]]) return YES;
    }
    return NO;
}

static NSString *SGRLicenseLabel(NSString *licenseURL) {
    NSURLComponents *components = [NSURLComponents componentsWithString:licenseURL ?: @""];
    NSString *path = components.path.lowercaseString ?: @"";
    if ([path containsString:@"/publicdomain/zero/"]) return @"CC0";
    if ([path containsString:@"/publicdomain/mark/"]) return @"Public Domain";
    for (NSString *license in @[@"by-nc-sa", @"by-nc-nd", @"by-sa", @"by-nc", @"by-nd", @"by"]) {
        if ([path containsString:[NSString stringWithFormat:@"/licenses/%@/", license]]) {
            return [NSString stringWithFormat:@"CC %@", [license uppercaseString]];
        }
    }
    return @"Open license";
}

static NSString *SGRSafeFilenameComponent(NSString *value) {
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    NSArray<NSString *> *parts = [(value ?: @"Track") componentsSeparatedByCharactersInSet:invalid];
    NSString *safe = [[parts componentsJoinedByString:@"-"]
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([safe containsString:@"  "]) safe = [safe stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    if (safe.length > 100) safe = [safe substringToIndex:100];
    return safe.length ? safe : @"Track";
}

static NSString *SGREncodedArchiveFilename(NSString *filename) {
    if (!filename.length || [filename hasPrefix:@"/"] || [filename containsString:@"\\"]) return nil;
    NSArray<NSString *> *segments = [filename componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *encodedSegments = [NSMutableArray arrayWithCapacity:segments.count];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    for (NSString *segment in segments) {
        if (!segment.length || [segment isEqualToString:@"."] || [segment isEqualToString:@".."]) return nil;
        NSString *encoded = [segment stringByAddingPercentEncodingWithAllowedCharacters:allowed];
        if (!encoded.length) return nil;
        [encodedSegments addObject:encoded];
    }
    return [encodedSegments componentsJoinedByString:@"/"];
}

static NSURL *SGRArchiveDownloadURL(NSString *identifier, NSString *filename) {
    NSCharacterSet *identifierCharacters = [NSCharacterSet characterSetWithCharactersInString:
                                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._"];
    if (!identifier.length || [identifier rangeOfCharacterFromSet:identifierCharacters.invertedSet].location != NSNotFound) {
        return nil;
    }
    NSString *encodedFilename = SGREncodedArchiveFilename(filename);
    if (!encodedFilename.length) return nil;
    NSString *path = [NSString stringWithFormat:@"/download/%@/%@", identifier, encodedFilename];
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://archive.org"];
    components.percentEncodedPath = path;
    NSURL *url = components.URL;
    return [url.host.lowercaseString isEqualToString:@"archive.org"] ? url : nil;
}

static NSString *SGRFormatByteCount(unsigned long long bytes) {
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    return [formatter stringFromByteCount:(long long)bytes];
}

@interface SGRTrackLinksController : UITableViewController <NSURLSessionDownloadDelegate>
- (instancetype)initWithTitle:(NSString *)title
                        artist:(NSString *)artist
                      trackURI:(NSString *)trackURI
                      duration:(NSTimeInterval)duration;
@end

@implementation SGRTrackLinksController {
    NSString *_trackTitle;
    NSString *_artistName;
    NSURLSession *_session;
    NSMutableArray<NSURLSessionTask *> *_searchTasks;
    NSUInteger _generation;
    BOOL _started;
    BOOL _loading;
    NSString *_statusMessage;
    UILabel *_statusLabel;
    NSArray<NSDictionary *> *_results;
    NSDictionary *_selectedResult;
    NSURLSessionDownloadTask *_activeDownloadTask;
    NSURL *_downloadedFileURL;
    NSString *_downloadedItemIdentifier;
    double _downloadProgress;
}

- (instancetype)initWithTitle:(NSString *)title
                        artist:(NSString *)artist
                      trackURI:(NSString *)trackURI
                      duration:(NSTimeInterval)duration {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _trackTitle = [title copy] ?: @"";
    _artistName = [artist copy] ?: @"";
    (void)trackURI;
    (void)duration;
    _statusMessage = @"Ready to search for downloadable MP3 files.";
    _results = @[];
    _searchTasks = [NSMutableArray array];
    SGRClearLegacyOpenverseCredentials();

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 35.0;
    configuration.timeoutIntervalForResource = 900.0;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Download MP3";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78.0;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Retry" style:UIBarButtonItemStylePlain target:self action:@selector(rightAction)];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.tableView.bounds), 126)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *trackLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, 10, MAX(0, CGRectGetWidth(header.bounds) - 36), 54)];
    trackLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    trackLabel.numberOfLines = 2;
    trackLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    trackLabel.textColor = UIColor.labelColor;
    trackLabel.text = _artistName.length
        ? [NSString stringWithFormat:@"%@\n%@", _trackTitle.length ? _trackTitle : @"Unknown track", _artistName]
        : (_trackTitle.length ? _trackTitle : @"Unknown track");
    [header addSubview:trackLabel];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, 68, MAX(0, CGRectGetWidth(header.bounds) - 36), 50)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.numberOfLines = 3;
    _statusLabel.text = _statusMessage;
    [header addSubview:_statusLabel];
    self.tableView.tableHeaderView = header;

    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 320, 104)];
    footer.text = @"Only original MP3 files with an explicit Creative Commons or public-domain license record are offered. License details are supplied by uploaders and should be checked on the source page. This catalog does not include most mainstream commercial releases. Tap a result to download it, then use the share sheet to Save to Files.";
    footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footer.textColor = UIColor.secondaryLabelColor;
    footer.numberOfLines = 0;
    footer.textAlignment = NSTextAlignmentCenter;
    footer.frame = CGRectMake(0, 0, MAX(0, CGRectGetWidth(self.tableView.bounds) - 36), 104);
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableFooterView = footer;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_started) return;
    _started = YES;
    [self resolveCurrentTrack];
}

- (void)dealloc {
    [_session invalidateAndCancel];
}

- (void)setStatus:(NSString *)status {
    _statusMessage = [status copy] ?: @"";
    _statusLabel.text = _statusMessage;
    [self.tableView reloadData];
}

- (void)rightAction {
    if (_activeDownloadTask) {
        [_activeDownloadTask cancel];
        [self setStatus:@"Cancelling download…"];
        return;
    }
    if (_loading) {
        _generation++;
        for (NSURLSessionTask *task in _searchTasks) [task cancel];
        [_searchTasks removeAllObjects];
        _loading = NO;
        self.navigationItem.rightBarButtonItem.title = @"Retry";
        [self setStatus:@"Search cancelled. Tap Retry to try again."];
        return;
    }
    [self resolveCurrentTrack];
}

- (void)close {
    _generation++;
    for (NSURLSessionTask *task in _searchTasks) [task cancel];
    [_searchTasks removeAllObjects];
    [_activeDownloadTask cancel];
    [_session invalidateAndCancel];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSURL *)searchURL {
    NSArray<NSString *> *tokens = SGRSearchTokens(_trackTitle);
    if (tokens.count == 0) return nil;

    // Search title metadata broadly first. Internet Archive search responses can omit licenseurl
    // even when the full metadata record includes it, so license validation happens after lookup.
    NSString *titleClause = [tokens componentsJoinedByString:@" AND "];
    NSString *query = [NSString stringWithFormat:@"mediatype:audio AND title:(%@)", titleClause];

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://archive.org/advancedsearch.php"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:query],
        [NSURLQueryItem queryItemWithName:@"fl[]" value:@"identifier"],
        [NSURLQueryItem queryItemWithName:@"fl[]" value:@"title"],
        [NSURLQueryItem queryItemWithName:@"fl[]" value:@"creator"],
        [NSURLQueryItem queryItemWithName:@"fl[]" value:@"licenseurl"],
        [NSURLQueryItem queryItemWithName:@"rows" value:@"100"],
        [NSURLQueryItem queryItemWithName:@"page" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"output" value:@"json"]
    ];
    return components.URL;
}

- (void)resolveCurrentTrack {
    if (_activeDownloadTask) {
        [self setStatus:@"Cancel the active download before starting another search."];
        return;
    }
    _generation++;
    NSUInteger generation = _generation;
    for (NSURLSessionTask *task in _searchTasks) [task cancel];
    [_searchTasks removeAllObjects];
    _results = @[];
    _downloadedFileURL = nil;
    _downloadedItemIdentifier = nil;
    _loading = YES;
    self.navigationItem.rightBarButtonItem.title = @"Cancel";

    NSURL *url = [self searchURL];
    if (!url) {
        _loading = NO;
        self.navigationItem.rightBarButtonItem.title = @"Retry";
        [self setStatus:@"The playing track has no usable title. Open a song and try again."];
        return;
    }

    [self setStatus:@"Searching Internet Archive for openly licensed MP3 files…"];
    NSURLSessionDataTask *task = [_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (generation != self->_generation) return;
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (error || !http || http.statusCode < 200 || http.statusCode >= 300) {
            self->_loading = NO;
            self.navigationItem.rightBarButtonItem.title = @"Retry";
            NSString *detail = error.localizedDescription ?: (http ? [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode] : @"No HTTP response");
            [self setStatus:[NSString stringWithFormat:@"Search failed: %@. Check the connection and retry.", detail]];
            return;
        }

        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        NSDictionary *responseObject = [json isKindOfClass:NSDictionary.class] ? json : nil;
        NSArray *docs = [responseObject[@"response"][@"docs"] isKindOfClass:NSArray.class] ? responseObject[@"response"][@"docs"] : nil;
        if (!docs || jsonError) {
            self->_loading = NO;
            self.navigationItem.rightBarButtonItem.title = @"Retry";
            [self setStatus:@"Internet Archive returned an unexpected response. Tap Retry."];
            return;
        }

        [self setStatus:@"Checking source records, licenses, and original MP3 files…"];
        dispatch_group_t group = dispatch_group_create();
        NSMutableArray<NSDictionary *> *verifiedResults = [NSMutableArray array];
        NSMutableSet<NSString *> *seenIdentifiers = [NSMutableSet set];
        NSString *requestedTitle = self->_trackTitle;
        NSString *requestedArtist = self->_artistName;
        NSUInteger metadataRequestCount = 0;

        for (id rawDoc in docs) {
            if (![rawDoc isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *doc = rawDoc;
            NSString *identifier = SGRStringValue(doc[@"identifier"]);
            NSString *candidateTitle = SGRStringValue(doc[@"title"]);
            NSString *candidateCreator = SGRStringValue(doc[@"creator"]);
            NSString *candidateLicense = SGRStringValue(doc[@"licenseurl"]);
            if (!identifier.length || !candidateTitle.length || [seenIdentifiers containsObject:identifier]) continue;

            double titleScore = SGRTextSimilarity(requestedTitle, candidateTitle);
            NSArray *requestedTokens = SGRSearchTokens(requestedTitle);
            double minimumTitleScore = requestedTokens.count <= 1 ? 0.80 : 0.50;
            if (titleScore < minimumTitleScore) continue;
            double artistScore = requestedArtist.length && candidateCreator.length
                ? SGRTextSimilarity(requestedArtist, candidateCreator) : 0.0;
            if (requestedArtist.length && candidateCreator.length && artistScore < 0.15 && titleScore < 0.90) continue;

            [seenIdentifiers addObject:identifier];
            metadataRequestCount++;
            if (metadataRequestCount > 30) break;

            NSURL *metadataURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://archive.org/metadata/%@", identifier]];
            if (!metadataURL || ![metadataURL.host.lowercaseString isEqualToString:@"archive.org"]) continue;

            dispatch_group_enter(group);
            NSURLSessionDataTask *metadataTask = [self->_session dataTaskWithURL:metadataURL completionHandler:^(NSData *metadataData, NSURLResponse *metadataResponse, NSError *metadataError) {
                @try {
                    if (generation != self->_generation || metadataError) return;
                    NSHTTPURLResponse *metadataHTTP = [metadataResponse isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)metadataResponse : nil;
                    if (!metadataHTTP || metadataHTTP.statusCode < 200 || metadataHTTP.statusCode >= 300) return;

                    NSError *parseError = nil;
                    id metadataJSON = [NSJSONSerialization JSONObjectWithData:metadataData options:0 error:&parseError];
                    NSDictionary *record = [metadataJSON isKindOfClass:NSDictionary.class] ? metadataJSON : nil;
                    NSDictionary *metadata = [record[@"metadata"] isKindOfClass:NSDictionary.class] ? record[@"metadata"] : nil;
                    NSArray *files = [record[@"files"] isKindOfClass:NSArray.class] ? record[@"files"] : nil;
                    if (!metadata || !files || parseError) return;

                    NSString *licenseURL = SGRStringValue(metadata[@"licenseurl"]);
                    if (!licenseURL.length) licenseURL = candidateLicense;
                    if (!SGRHasAllowedLicenseURL(licenseURL)) return;

                    NSString *actualTitle = SGRStringValue(metadata[@"title"]);
                    if (!actualTitle.length) actualTitle = candidateTitle;
                    NSString *actualCreator = SGRStringValue(metadata[@"creator"]);
                    if (!actualCreator.length) actualCreator = candidateCreator;
                    double actualTitleScore = SGRTextSimilarity(requestedTitle, actualTitle);
                    if (actualTitleScore < minimumTitleScore) return;
                    double actualArtistScore = requestedArtist.length && actualCreator.length
                        ? SGRTextSimilarity(requestedArtist, actualCreator) : 0.0;
                    if (requestedArtist.length && actualCreator.length && actualArtistScore < 0.15 && actualTitleScore < 0.90) return;

                    NSDictionary *chosenFile = nil;
                    unsigned long long bestSize = 0;
                    for (id rawFile in files) {
                        if (![rawFile isKindOfClass:NSDictionary.class]) continue;
                        NSDictionary *file = rawFile;
                        NSString *fileName = SGRStringValue(file[@"name"]);
                        NSString *source = SGRStringValue(file[@"source"]);
                        unsigned long long fileSize = [SGRStringValue(file[@"size"]) longLongValue];
                        NSString *format = SGRStringValue(file[@"format"]);
                        if (![fileName.lowercaseString hasSuffix:@".mp3"] ||
                            (source.length && ![source isEqualToString:@"original"]) ||
                            !fileName.length || [fileName containsString:@".."] ||
                            [fileName hasPrefix:@"/"] || [fileName containsString:@"\\"] ||
                            ![format.lowercaseString containsString:@"mp3"] ||
                            fileSize < 20000 || fileSize > 150ULL * 1024ULL * 1024ULL) continue;
                        if (fileSize > bestSize) {
                            chosenFile = file;
                            bestSize = fileSize;
                        }
                    }
                    if (!chosenFile) return;

                    NSURL *downloadURL = SGRArchiveDownloadURL(identifier, SGRStringValue(chosenFile[@"name"]));
                    if (!downloadURL) return;

                    NSDictionary *result = @{
                        @"identifier": identifier,
                        @"title": actualTitle,
                        @"creator": actualCreator,
                        @"license_url": licenseURL,
                        @"license_label": SGRLicenseLabel(licenseURL),
                        @"source_url": [NSString stringWithFormat:@"https://archive.org/details/%@", identifier],
                        @"download_url": downloadURL.absoluteString,
                        @"filename": SGRStringValue(chosenFile[@"name"]),
                        @"size": @(bestSize),
                        @"match_score": @(actualTitleScore * 0.8 + actualArtistScore * 0.2)
                    };
                    [verifiedResults addObject:result];
                } @finally {
                    dispatch_group_leave(group);
                }
            }];
            [self->_searchTasks addObject:metadataTask];
            [metadataTask resume];
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            NSArray<NSDictionary *> *sorted = [verifiedResults sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                double scoreA = [a[@"match_score"] doubleValue];
                double scoreB = [b[@"match_score"] doubleValue];
                if (scoreA == scoreB) return NSOrderedSame;
                return scoreA > scoreB ? NSOrderedAscending : NSOrderedDescending;
            }];
            self->_results = sorted;
            self->_loading = NO;
            self.navigationItem.rightBarButtonItem.title = @"Retry";
            if (sorted.count) {
                [self setStatus:[NSString stringWithFormat:@"Found %lu openly licensed MP3 match%@. Tap one to download it.", (unsigned long)sorted.count, sorted.count == 1 ? @"" : @"es"]];
            } else {
                [self setStatus:@"No matching MP3 with a verified Creative Commons/public-domain license was found in Internet Archive. Most mainstream commercial hits are not available as openly licensed downloads."];
            }
        });
    }];
    [_searchTasks addObject:task];
    [task resume];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _results.count ? _results.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseID = @"licensedArchiveMP3";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];

    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 3;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (_results.count == 0) {
        cell.textLabel.text = _loading ? @"Searching…" : @"No MP3 results";
        cell.detailTextLabel.text = _statusMessage ?: @"Tap Retry to search again.";
        return cell;
    }

    NSDictionary *result = _results[indexPath.row];
    NSString *creator = [result[@"creator"] isKindOfClass:NSString.class] ? result[@"creator"] : @"Unknown artist";
    NSString *license = [result[@"license_label"] isKindOfClass:NSString.class] ? result[@"license_label"] : @"Open license";
    NSString *size = SGRFormatByteCount([result[@"size"] unsignedLongLongValue]);
    cell.textLabel.text = result[@"title"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nMP3 • %@ • %@", creator.length ? creator : @"Unknown artist", size, license];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (_downloadedFileURL && [_downloadedItemIdentifier isEqualToString:result[@"identifier"]]) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nDownloaded • Tap to Save or Share", creator.length ? creator : @"Unknown artist"];
    } else if (_activeDownloadTask && [_selectedResult[@"identifier"] isEqualToString:result[@"identifier"]]) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nDownloading… %.0f%%", creator.length ? creator : @"Unknown artist", _downloadProgress * 100.0];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nMP3 • %@ • %@ • Tap to download", creator.length ? creator : @"Unknown artist", size, license];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_results.count == 0) {
        if (!_loading) [self resolveCurrentTrack];
        return;
    }
    if (_activeDownloadTask) {
        [self setStatus:@"A download is already running. Tap Cancel at the top to stop it first."];
        return;
    }

    NSDictionary *result = _results[indexPath.row];
    if (_downloadedFileURL && [_downloadedItemIdentifier isEqualToString:result[@"identifier"]] &&
        [[NSFileManager defaultManager] fileExistsAtPath:_downloadedFileURL.path]) {
        [self presentShareSheetForURL:_downloadedFileURL];
        return;
    }

    NSURL *url = [NSURL URLWithString:result[@"download_url"]];
    if (!url || ![url.host.lowercaseString isEqualToString:@"archive.org"]) {
        [self setStatus:@"This source returned an invalid download address."];
        return;
    }
    _selectedResult = result;
    _downloadedFileURL = nil;
    _downloadedItemIdentifier = nil;
    _downloadProgress = 0.0;
    _statusMessage = @"Starting download…";
    self.navigationItem.rightBarButtonItem.title = @"Cancel";
    [self.tableView reloadData];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:90.0];
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Accept"];
    _activeDownloadTask = [_session downloadTaskWithRequest:request];
    [_activeDownloadTask resume];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (!_activeDownloadTask || downloadTask.taskIdentifier != _activeDownloadTask.taskIdentifier) return;
    if (totalBytesExpectedToWrite > 0) _downloadProgress = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
    NSString *title = _selectedResult[@"title"] ?: @"MP3";
    NSString *progress = totalBytesExpectedToWrite > 0
        ? [NSString stringWithFormat:@"Downloading %@ — %.0f%%", title, _downloadProgress * 100.0]
        : [NSString stringWithFormat:@"Downloading %@ — %@", title, SGRFormatByteCount((unsigned long long)MAX(0, totalBytesWritten))];
    [self setStatus:progress];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didFinishDownloadingToURL:(NSURL *)location {
    if (!_activeDownloadTask || downloadTask.taskIdentifier != _activeDownloadTask.taskIdentifier) return;
    NSHTTPURLResponse *http = [downloadTask.response isKindOfClass:NSHTTPURLResponse.class]
        ? (NSHTTPURLResponse *)downloadTask.response : nil;
    if (!http || http.statusCode < 200 || http.statusCode >= 300) {
        _statusMessage = [NSString stringWithFormat:@"Download failed with HTTP %ld.", (long)(http ? http.statusCode : -1)];
        return;
    }

    NSString *base = SGRSafeFilenameComponent(_trackTitle.length ? _trackTitle : SGRStringValue(_selectedResult[@"title"]));
    NSString *filename = [base stringByAppendingPathExtension:@"mp3"];
    NSArray<NSURL *> *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    NSURL *documentsURL = documents.firstObject;
    NSURL *folderURL = [documentsURL URLByAppendingPathComponent:@"Music Downloads" isDirectory:YES];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        _statusMessage = [NSString stringWithFormat:@"Could not create the download folder: %@", directoryError.localizedDescription ?: @"unknown error"];
        return;
    }

    NSURL *destinationURL = [folderURL URLByAppendingPathComponent:filename];
    NSUInteger suffix = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:destinationURL.path]) {
        filename = [NSString stringWithFormat:@"%@ (%lu).mp3", base, (unsigned long)suffix++];
        destinationURL = [folderURL URLByAppendingPathComponent:filename];
    }

    NSError *moveError = nil;
    if ([[NSFileManager defaultManager] copyItemAtURL:location toURL:destinationURL error:&moveError]) {
        _downloadedFileURL = destinationURL;
        _downloadedItemIdentifier = _selectedResult[@"identifier"];
        _downloadProgress = 1.0;
        _statusMessage = [NSString stringWithFormat:@"Downloaded %@. Opening the share sheet so you can save it to Files…", filename];
    } else {
        _statusMessage = [NSString stringWithFormat:@"Could not save the MP3: %@", moveError.localizedDescription ?: @"unknown error"];
    }
    _statusLabel.text = _statusMessage;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!_activeDownloadTask || task.taskIdentifier != _activeDownloadTask.taskIdentifier) return;
    _activeDownloadTask = nil;
    self.navigationItem.rightBarButtonItem.title = @"Retry";

    if (error) {
        if (error.code == NSURLErrorCancelled) {
            [self setStatus:@"Download cancelled."];
        } else {
            [self setStatus:[NSString stringWithFormat:@"Download failed: %@", error.localizedDescription ?: @"network error"]];
        }
        return;
    }

    if (_downloadedFileURL && [[NSFileManager defaultManager] fileExistsAtPath:_downloadedFileURL.path]) {
        [self.tableView reloadData];
        [self setStatus:_statusMessage ?: @"Download complete."];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.isBeingDismissed && !self.presentedViewController) {
                [self presentShareSheetForURL:self->_downloadedFileURL];
            }
        });
    } else {
        [self setStatus:_statusMessage.length ? _statusMessage : @"The source did not return a valid MP3 file."];
    }
}

- (void)presentShareSheetForURL:(NSURL *)url {
    if (!url || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:activity animated:YES completion:nil];
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
