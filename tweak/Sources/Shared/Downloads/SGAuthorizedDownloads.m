// A separate, user-managed library for tracks from a provider that explicitly permits downloading.
// This deliberately does not read Spotify stream URLs or write Spotify's private offline-download records.
#import <AVFoundation/AVFoundation.h>
#import <float.h>
#import "Core/SGCore.h"
#import "SGAuthorizedDownloads.h"

static NSString *const kSGJamendoClientIDKey = @"spotifyglass.authorizedDownloads.jamendoClientID";
static NSString *const kSGAuthorizedLibraryKey = @"spotifyglass.authorizedDownloads.library";

static NSString *SGDownloadNormalize(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *folded = [[value lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch
                                                                      locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    NSCharacterSet *lettersAndDigits = NSCharacterSet.alphanumericCharacterSet;
    NSMutableString *normalized = [NSMutableString string];
    BOOL needsSpace = NO;
    for (NSUInteger i = 0; i < folded.length; i++) {
        unichar character = [folded characterAtIndex:i];
        if ([lettersAndDigits characterIsMember:character]) {
            if (needsSpace && normalized.length) [normalized appendString:@" "];
            [normalized appendFormat:@"%C", character];
            needsSpace = NO;
        } else {
            needsSpace = YES;
        }
    }
    return [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSSet<NSString *> *SGDownloadTokens(NSString *value) {
    NSString *normalized = SGDownloadNormalize(value);
    if (!normalized.length) return [NSSet set];
    NSMutableSet<NSString *> *tokens = [NSMutableSet setWithArray:[normalized componentsSeparatedByString:@" "]];
    [tokens removeObject:@"feat"];
    [tokens removeObject:@"featuring"];
    [tokens removeObject:@"with"];
    return tokens;
}

// Conservative token overlap: a partial phrase is not treated as an exact song/artist match.
static double SGDownloadSimilarity(NSString *left, NSString *right) {
    NSString *a = SGDownloadNormalize(left), *b = SGDownloadNormalize(right);
    if (!a.length || !b.length) return 0;
    if ([a isEqualToString:b]) return 1.0;
    NSSet<NSString *> *leftTokens = SGDownloadTokens(a);
    NSSet<NSString *> *rightTokens = SGDownloadTokens(b);
    if (!leftTokens.count || !rightTokens.count) return 0;
    NSMutableSet<NSString *> *common = [leftTokens mutableCopy];
    [common intersectSet:rightTokens];
    return (double)common.count / (double)MAX(leftTokens.count, rightTokens.count);
}

@interface SGAuthorizedDownloadsController : UITableViewController <UISearchBarDelegate, NSURLSessionDownloadDelegate>
@property (nonatomic, copy) NSString *trackTitle;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic) NSTimeInterval trackDuration;
- (instancetype)initWithTitle:(NSString *)title artist:(NSString *)artist duration:(NSTimeInterval)duration;
- (NSDictionary *)bestMatchFrom:(NSArray<NSDictionary *> *)items;
- (BOOL)isConfidentMatch:(NSDictionary *)item;
@end

@implementation SGAuthorizedDownloadsController {
    UISearchBar *_searchBar;
    UISegmentedControl *_segments;
    NSMutableArray<NSDictionary *> *_results;
    NSMutableArray<NSDictionary *> *_library;
    NSMutableArray<NSDictionary *> *_queue;
    NSMutableDictionary<NSString *, NSString *> *_states;
    NSMutableDictionary<NSString *, NSNumber *> *_progress;
    NSURLSession *_downloadSession;
    NSURLSessionDataTask *_searchTask;
    NSURLSessionDownloadTask *_activeTask;
    NSDictionary *_activeTrack;
    NSString *_finishedPath;
    NSString *_downloadFailureReason;
    BOOL _attemptedInitialSearch;
    BOOL _closing;
    BOOL _manualSearch;
    BOOL _searching;
    NSString *_searchMessage;
}

- (instancetype)initWithTitle:(NSString *)title artist:(NSString *)artist duration:(NSTimeInterval)duration {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.trackTitle = [title copy] ?: @"";
    self.artistName = [artist copy] ?: @"";
    self.trackDuration = MAX(0, duration);
    _results = [NSMutableArray array];
    _library = [[NSUserDefaults.standardUserDefaults arrayForKey:kSGAuthorizedLibraryKey] mutableCopy] ?: [NSMutableArray array];
    _queue = [NSMutableArray array];
    _states = [NSMutableDictionary dictionary];
    _progress = [NSMutableDictionary dictionary];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Vitrine Downloads";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;

    _segments = [[UISegmentedControl alloc] initWithItems:@[@"Current track", @"Library"]];
    _segments.selectedSegmentIndex = 0;
    [_segments addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];

    _searchBar = [UISearchBar new];
    _searchBar.delegate = self;
    _searchBar.placeholder = @"Search licensed music";
    NSString *query = [@[self.trackTitle ?: @"", self.artistName ?: @""] componentsJoinedByString:@" "];
    _searchBar.text = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _searchBar.hidden = YES;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.tableView.bounds), 50)];
    [header addSubview:_segments];
    [header addSubview:_searchBar];
    self.tableView.tableHeaderView = header;
    [self layoutHeader];

    UIBarButtonItem *searchButton = [[UIBarButtonItem alloc] initWithTitle:@"Search"
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self
                                                                    action:@selector(enableManualSearch)];
    UIBarButtonItem *apiButton = [[UIBarButtonItem alloc] initWithTitle:@"API ID"
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(editClientID)];
    self.navigationItem.rightBarButtonItems = @[searchButton, apiButton];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                           target:self
                                                                                           action:@selector(close)];
    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 66)];
    footer.text = @"Vitrine matches the current track by title, artist and duration. Only files explicitly marked downloadable by their provider are saved; this library is separate from Spotify Downloads.";
    footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footer.textColor = UIColor.secondaryLabelColor;
    footer.numberOfLines = 0;
    footer.textAlignment = NSTextAlignmentCenter;
    footer.frame = CGRectMake(0, 0, CGRectGetWidth(self.tableView.bounds) - 40, 66);
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableFooterView = footer;

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 25;
    configuration.timeoutIntervalForResource = 180;
    _downloadSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];

    [self ensureDownloadsDirectory];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutHeader];
}

- (void)layoutHeader {
    if (!_segments || !_searchBar) return;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    BOOL showSearch = _manualSearch && _segments.selectedSegmentIndex == 0;
    _searchBar.hidden = !showSearch;
    UIView *header = self.tableView.tableHeaderView;
    CGFloat height = showSearch ? 106 : 50;
    CGRect newFrame = CGRectMake(0, 0, width, height);
    BOOL changed = !CGRectEqualToRect(header.frame, newFrame);
    if (changed) header.frame = newFrame;
    _segments.frame = CGRectMake(16, 8, MAX(0, width - 32), 32);
    _searchBar.frame = CGRectMake(0, 42, width, 56);
    if (changed) self.tableView.tableHeaderView = header;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_attemptedInitialSearch) return;
    _attemptedInitialSearch = YES;
    if (_searchBar.text.length) [self performSearch];
}

- (void)close {
    [_searchTask cancel];
    _closing = YES;
    if (!_activeTask && !_queue.count) [_downloadSession finishTasksAndInvalidate];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        _closing = YES;
        if (!_activeTask && !_queue.count) [_downloadSession finishTasksAndInvalidate];
    }
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex == 1) [_searchBar resignFirstResponder];
    [self layoutHeader];
    [self.tableView reloadData];
}

- (void)enableManualSearch {
    _manualSearch = YES;
    if (_searchBar.text.length == 0) _searchBar.text = self.trackTitle ?: @"";
    [self layoutHeader];
    [self.tableView reloadData];
    [_searchBar becomeFirstResponder];
}

- (void)editClientID {
    [self promptForClientIDAndSearch:NO];
}

- (void)promptForClientIDAndSearch:(BOOL)searchAfterSave {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Jamendo API ID"
                                                                   message:@"Search uses Jamendo's licensed music catalog. Add your own read-only API client ID from the Jamendo developer portal."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Client ID";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.text = [NSUserDefaults.standardUserDefaults stringForKey:kSGJamendoClientIDKey];
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Get API ID" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:@"https://developer.jamendo.com/v3.0"];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *clientID = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clientID.length) {
            [NSUserDefaults.standardUserDefaults setObject:clientID forKey:kSGJamendoClientIDKey];
            if (searchAfterSave) [self performSearch];
        } else if (searchAfterSave) {
            [self promptForClientIDAndSearch:YES];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self performSearch];
}

- (NSDictionary *)bestMatchFrom:(NSArray<NSDictionary *> *)items {
    NSDictionary *best = nil;
    double bestScore = -1;
    for (NSDictionary *item in items) {
        NSString *candidateTitle = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : @"";
        NSString *candidateArtist = [item[@"artist_name"] isKindOfClass:NSString.class] ? item[@"artist_name"] : @"";
        double titleScore = SGDownloadSimilarity(self.trackTitle, candidateTitle);
        double artistScore = SGDownloadSimilarity(self.artistName, candidateArtist);
        if (titleScore <= 0 || artistScore <= 0) continue;

        double durationScore = 0;
        double durationDelta = DBL_MAX;
        double candidateDuration = [item[@"duration"] respondsToSelector:@selector(doubleValue)] ? [item[@"duration"] doubleValue] : 0;
        BOOL hasDuration = self.trackDuration > 0 && candidateDuration > 0;
        if (hasDuration) {
            durationDelta = fabs(self.trackDuration - candidateDuration);
            durationScore = durationDelta <= 3 ? 1.0 : durationDelta <= 7 ? 0.8 : durationDelta <= 14 ? 0.5 : durationDelta <= 20 ? 0.2 : 0.0;
        }
        double score = hasDuration
            ? (0.60 * titleScore + 0.33 * artistScore + 0.07 * durationScore)
            : (0.64 * titleScore + 0.36 * artistScore);
        NSMutableDictionary *scored = [item mutableCopy];
        scored[@"_vitrineScore"] = @(score);
        scored[@"_vitrineTitleScore"] = @(titleScore);
        scored[@"_vitrineArtistScore"] = @(artistScore);
        if (hasDuration) scored[@"_vitrineDurationDelta"] = @(durationDelta);
        if (score > bestScore) {
            best = scored;
            bestScore = score;
        }
    }
    return best;
}

- (BOOL)isConfidentMatch:(NSDictionary *)item {
    if (![item isKindOfClass:NSDictionary.class]) return NO;
    double score = [item[@"_vitrineScore"] doubleValue];
    double titleScore = [item[@"_vitrineTitleScore"] doubleValue];
    double artistScore = [item[@"_vitrineArtistScore"] doubleValue];
    NSNumber *durationDelta = item[@"_vitrineDurationDelta"];
    // Only auto-download very strong matches. A similar title or artist isn't enough to claim it is the same recording.
    if (durationDelta && durationDelta.doubleValue > 12.0) return NO;
    return score >= 0.90 && titleScore >= 0.95 && artistScore >= 0.75;
}

- (void)performSearch {
    if (_segments.selectedSegmentIndex != 0) _segments.selectedSegmentIndex = 0;
    NSString *clientID = [NSUserDefaults.standardUserDefaults stringForKey:kSGJamendoClientIDKey];
    if (!clientID.length) {
        [self promptForClientIDAndSearch:YES];
        return;
    }

    // Automatic mode looks up the playing title only, then independently scores artist + duration.
    // Manual mode is an explicit fallback and uses what the user typed.
    NSString *query = _manualSearch
        ? [_searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : [self.trackTitle stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length && !_manualSearch) {
        query = [self.artistName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (!query.length) {
        _searchMessage = @"No current track title is available.";
        [_results removeAllObjects];
        [self.tableView reloadData];
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://api.jamendo.com/v3.0/tracks/"];
    NSMutableArray<NSURLQueryItem *> *queryItems = [@[
        [NSURLQueryItem queryItemWithName:@"client_id" value:clientID],
        [NSURLQueryItem queryItemWithName:@"format" value:@"json"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"50"],
        [NSURLQueryItem queryItemWithName:@"namesearch" value:query],
        [NSURLQueryItem queryItemWithName:@"type" value:@"single albumtrack"],
        [NSURLQueryItem queryItemWithName:@"include" value:@"licenses"],
        [NSURLQueryItem queryItemWithName:@"order" value:@"relevance"]
    ] mutableCopy];
    // Keep the server query focused on the title; artists and duration are ranked locally so
    // punctuation or collaborative artist credits do not discard a valid candidate prematurely.
    if (!_manualSearch && self.trackDuration > 20) {
        NSInteger low = MAX(1, (NSInteger)floor(self.trackDuration - 20));
        NSInteger high = (NSInteger)ceil(self.trackDuration + 20);
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"durationbetween"
                                                          value:[NSString stringWithFormat:@"%ld_%ld", (long)low, (long)high]]];
    }
    components.queryItems = queryItems;
    NSURL *url = components.URL;
    if (!url) return;

    [_searchTask cancel];
    _searching = YES;
    _searchMessage = _manualSearch ? @"Searching licensed tracks…" : @"Matching the current track…";
    [_results removeAllObjects];
    [self.tableView reloadData];

    __weak typeof(self) weakSelf = self;
    _searchTask = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self->_searching = NO;
            if (error) {
                if (error.code == NSURLErrorCancelled) return;
                self->_searchMessage = @"Lookup failed. Check the connection and Jamendo API ID, then try again.";
                [self.tableView reloadData];
                return;
            }
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
                self->_searchMessage = [NSString stringWithFormat:@"The music catalogue returned HTTP %ld.", (long)http.statusCode];
                [self.tableView reloadData];
                return;
            }
            NSError *jsonError = nil;
            id payload = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
            if (![payload isKindOfClass:NSDictionary.class] || jsonError || [payload[@"headers"] isKindOfClass:NSDictionary.class] && [payload[@"results"] isKindOfClass:NSArray.class] == NO) {
                self->_searchMessage = @"The music catalogue returned an unreadable response.";
                [self.tableView reloadData];
                return;
            }
            if ([payload[@"headers"] isKindOfClass:NSDictionary.class] && [payload[@"headers"][@"status"] isKindOfClass:NSString.class]
                && [payload[@"headers"][@"status"] caseInsensitiveCompare:@"success"] != NSOrderedSame) {
                self->_searchMessage = @"The music catalogue rejected this request. Check the API ID.";
                [self.tableView reloadData];
                return;
            }
            NSArray *items = [payload[@"results"] isKindOfClass:NSArray.class] ? payload[@"results"] : @[];
            NSMutableArray<NSDictionary *> *permitted = [NSMutableArray array];
            for (id candidate in items) {
                if (![candidate isKindOfClass:NSDictionary.class]) continue;
                NSDictionary *item = candidate;
                NSString *downloadURL = [item[@"audiodownload"] isKindOfClass:NSString.class] ? item[@"audiodownload"] : @"";
                id canDownload = item[@"audiodownload_allowed"];
                // Fail closed: the provider must explicitly allow this file to be downloaded.
                if (![canDownload respondsToSelector:@selector(boolValue)] || ![canDownload boolValue] || !downloadURL.length) continue;
                if (![item[@"id"] isKindOfClass:NSString.class] || ![item[@"name"] isKindOfClass:NSString.class]) continue;
                [permitted addObject:item];
            }

            if (self->_manualSearch) {
                // Manual fallback remains short; never display the entire catalogue response.
                if (permitted.count > 8) permitted = [[permitted subarrayWithRange:NSMakeRange(0, 8)] mutableCopy];
                self->_results = permitted;
                self->_searchMessage = permitted.count ? nil : @"No downloadable tracks matched that title.";
            } else {
                NSDictionary *best = [self bestMatchFrom:permitted];
                if ([self isConfidentMatch:best]) {
                    self->_results = [NSMutableArray arrayWithObject:best];
                    self->_searchMessage = nil;
                    // Choosing Download current track is the user's action; a high-confidence authorized
                    // match is queued automatically with no second search or download button.
                    [self enqueueTrack:best atFront:YES];
                } else {
                    self->_results = [NSMutableArray array];
                    self->_searchMessage = @"No confident downloadable match was found for this exact title and artist. Use Search to check the licensed catalogue manually.";
                }
            }
            [self.tableView reloadData];
        });
    }];
    [_searchTask resume];
}

- (NSString *)downloadsDirectory {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"Vitrine/Downloads"];
}

- (void)ensureDownloadsDirectory {
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:[self downloadsDirectory]
                                 withIntermediateDirectories:YES attributes:nil error:&error]) {
        SGLog(@"authorized downloads: could not create library folder: %@", error);
    }
}

- (BOOL)isSavedTrackID:(NSString *)trackID {
    for (NSDictionary *entry in _library) if ([entry[@"id"] isEqualToString:trackID]) return YES;
    return NO;
}

- (NSString *)licenseURLForTrack:(NSDictionary *)track {
    NSString *licenseURL = [track[@"license_ccurl"] isKindOfClass:NSString.class] ? track[@"license_ccurl"] : @"";
    return licenseURL;
}

- (NSString *)licenseForTrack:(NSDictionary *)track {
    NSString *url = [self licenseURLForTrack:track].lowercaseString;
    if ([url containsString:@"/licenses/by-nc-sa/"]) return @"CC BY-NC-SA — attribution, non-commercial, share-alike";
    if ([url containsString:@"/licenses/by-nc-nd/"]) return @"CC BY-NC-ND — attribution, non-commercial, no derivatives";
    if ([url containsString:@"/licenses/by-nc/"]) return @"CC BY-NC — attribution, non-commercial";
    if ([url containsString:@"/licenses/by-sa/"]) return @"CC BY-SA — attribution, share-alike";
    if ([url containsString:@"/licenses/by-nd/"]) return @"CC BY-ND — attribution, no derivatives";
    if ([url containsString:@"/licenses/by/"]) return @"CC BY — attribution";
    return url.length ? @"Track licence — open licence details" : @"Jamendo download permission enabled by artist";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_segments.selectedSegmentIndex == 1) return MAX(1, (NSInteger)_library.count);
    if (_searching && !_results.count) return 1;
    if (!_results.count) return 1;
    return (NSInteger)_results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL libraryMode = _segments.selectedSegmentIndex == 1;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:libraryMode ? @"saved" : @"result"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:libraryMode ? @"saved" : @"result"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = libraryMode ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 2;
    cell.imageView.image = nil;

    if (libraryMode) {
        if (_library.count == 0) {
            cell.textLabel.text = @"Your Vitrine library is empty";
            cell.detailTextLabel.text = @"Search licensed music, then tap the download icon to save a permitted file here.";
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            return cell;
        }
        NSDictionary *entry = _library[(NSUInteger)indexPath.row];
        cell.textLabel.text = entry[@"title"] ?: @"Unknown track";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", entry[@"artist"] ?: @"Unknown artist", entry[@"license"] ?: @"License information unavailable"];
        cell.textLabel.textColor = UIColor.labelColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (_searching || !_results.count) {
        cell.textLabel.text = _searchMessage ?: @"Search for a song or artist";
        cell.detailTextLabel.text = _searching ? @"Please wait…" : @"Results are limited to tracks that the provider says can be downloaded.";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        return cell;
    }

    NSDictionary *track = _results[(NSUInteger)indexPath.row];
    NSString *trackID = [track[@"id"] description];
    NSString *artist = [track[@"artist_name"] isKindOfClass:NSString.class] ? track[@"artist_name"] : @"Unknown artist";
    NSString *album = [track[@"album_name"] isKindOfClass:NSString.class] ? track[@"album_name"] : @"";
    cell.textLabel.text = track[@"name"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@\n%@", artist, album.length ? [@" · " stringByAppendingString:album] : @"", [self licenseForTrack:track]];
    cell.textLabel.textColor = UIColor.labelColor;

    NSString *state = _states[trackID];
    BOOL saved = [self isSavedTrackID:trackID];
    if (saved) {
        cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
        ((UIImageView *)cell.accessoryView).tintColor = UIColor.systemGreenColor;
    } else if ([state isEqualToString:@"Queued"]) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Queued · %@", cell.detailTextLabel.text];
        cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"clock"]];
        ((UIImageView *)cell.accessoryView).tintColor = UIColor.secondaryLabelColor;
    } else if ([state isEqualToString:@"Downloading"]) {
        NSInteger percent = (NSInteger)round(_progress[trackID].doubleValue * 100);
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Downloading · %ld%%\n%@", (long)percent, [self licenseForTrack:track]];
        UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        bar.frame = CGRectMake(0, 0, 56, 4);
        bar.progress = _progress[trackID].floatValue;
        cell.accessoryView = bar;
    } else if ([state isEqualToString:@"Failed"]) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Download failed · tap arrow to retry\n%@", [self licenseForTrack:track]];
        UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
        retry.frame = CGRectMake(0, 0, 36, 36);
        [retry setImage:[UIImage systemImageNamed:@"arrow.clockwise.circle"] forState:UIControlStateNormal];
        retry.tintColor = UIColor.systemOrangeColor;
        retry.tag = indexPath.row;
        [retry addTarget:self action:@selector(downloadPressed:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = retry;
    } else {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(0, 0, 36, 36);
        [button setImage:[UIImage systemImageNamed:@"arrow.down.circle"] forState:UIControlStateNormal];
        button.tintColor = self.view.tintColor;
        button.tag = indexPath.row;
        [button addTarget:self action:@selector(downloadPressed:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = button;
    }
    return cell;
}

- (void)downloadPressed:(UIButton *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)_results.count) return;
    NSDictionary *track = _results[(NSUInteger)sender.tag];
    NSString *trackID = [track[@"id"] description];
    if ([self isSavedTrackID:trackID] || [_states[trackID] isEqualToString:@"Queued"] || [_states[trackID] isEqualToString:@"Downloading"]) return;

    NSString *license = [self licenseForTrack:track];
    UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:@"Download licensed track?"
                                                                          message:[NSString stringWithFormat:@"%@ — %@\n\nThe provider reports that downloading is allowed. Review the track's license before reusing or redistributing it.\n\n%@", track[@"name"] ?: @"Track", track[@"artist_name"] ?: @"Unknown artist", license]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self enqueueTrack:track atFront:NO];
    }]];
    [self presentViewController:confirmation animated:YES completion:nil];
}

- (void)enqueueTrack:(NSDictionary *)track atFront:(BOOL)front {
    NSString *trackID = [track[@"id"] description];
    if (!trackID.length || [self isSavedTrackID:trackID]) return;
    if ([[_activeTrack[@"id"] description] isEqualToString:trackID]) return;
    for (NSDictionary *queued in _queue) if ([[queued[@"id"] description] isEqualToString:trackID]) return;
    if (front) [_queue insertObject:track atIndex:0];
    else [_queue addObject:track];
    _states[trackID] = @"Queued";
    [self.tableView reloadData];
    [self startNextDownload];
}

- (BOOL)isAllowedJamendoDownloadURL:(NSURL *)url {
    NSString *scheme = url.scheme.lowercaseString;
    NSString *host = url.host.lowercaseString;
    BOOL validHost = [host isEqualToString:@"jamendo.com"] || [host hasSuffix:@".jamendo.com"];
    return [scheme isEqualToString:@"https"] && validHost;
}

- (void)startNextDownload {
    if (_activeTask || !_queue.count) return;
    NSDictionary *track = _queue.firstObject;
    [_queue removeObjectAtIndex:0];
    NSURL *url = [NSURL URLWithString:track[@"audiodownload"] ?: @""];
    NSString *trackID = [track[@"id"] description];
    if (![self isAllowedJamendoDownloadURL:url]) {
        _states[trackID] = @"Failed";
        [self.tableView reloadData];
        [self startNextDownload];
        return;
    }
    _activeTrack = track;
    _finishedPath = nil;
    _downloadFailureReason = nil;
    _progress[trackID] = @0;
    _states[trackID] = @"Downloading";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _activeTask = [_downloadSession downloadTaskWithRequest:request];
    _activeTask.taskDescription = trackID;
    [self.tableView reloadData];
    [_activeTask resume];
}

- (NSString *)safeExtensionForResponse:(NSURLResponse *)response originalURL:(NSURL *)url {
    NSString *ext = response.suggestedFilename.pathExtension.lowercaseString;
    NSSet *allowed = [NSSet setWithArray:@[@"mp3", @"m4a", @"aac", @"ogg", @"opus", @"flac", @"wav", @"aiff", @"aif", @"mp4"]];
    if (![allowed containsObject:ext]) ext = url.pathExtension.lowercaseString;
    if (![allowed containsObject:ext]) {
        NSString *mime = response.MIMEType.lowercaseString;
        if ([mime isEqualToString:@"audio/mpeg"] || [mime isEqualToString:@"audio/mp3"]) ext = @"mp3";
        else if ([mime isEqualToString:@"audio/mp4"] || [mime isEqualToString:@"audio/x-m4a"]) ext = @"m4a";
        else if ([mime isEqualToString:@"audio/aac"]) ext = @"aac";
        else if ([mime isEqualToString:@"audio/ogg"]) ext = @"ogg";
        else if ([mime isEqualToString:@"audio/flac"] || [mime isEqualToString:@"audio/x-flac"]) ext = @"flac";
        else if ([mime isEqualToString:@"audio/wav"] || [mime isEqualToString:@"audio/x-wav"] || [mime isEqualToString:@"audio/wave"]) ext = @"wav";
        else if ([mime isEqualToString:@"audio/aiff"] || [mime isEqualToString:@"audio/x-aiff"]) ext = @"aiff";
    }
    return [allowed containsObject:ext] ? ext : nil;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSString *trackID = downloadTask.taskDescription;
    if (totalBytesExpectedToWrite > 0) _progress[trackID] = @(MIN(1.0, (double)totalBytesWritten / (double)totalBytesExpectedToWrite));
    [self.tableView reloadData];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didFinishDownloadingToURL:(NSURL *)location {
    NSHTTPURLResponse *http = [downloadTask.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)downloadTask.response : nil;
    NSString *mime = http.MIMEType.lowercaseString ?: @"";
    if (!http || http.statusCode < 200 || http.statusCode >= 300) {
        _downloadFailureReason = [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
        return;
    }
    // Only audio responses are persisted; generic binary responses still need a recognized audio extension.
    NSString *ext = [self safeExtensionForResponse:http originalURL:downloadTask.originalRequest.URL];
    BOOL audioType = [mime hasPrefix:@"audio/"];
    if ((!audioType && ![mime isEqualToString:@"application/octet-stream"]) || !ext) {
        _downloadFailureReason = @"The provider did not return a supported audio file.";
        return;
    }
    NSString *trackID = [_activeTrack[@"id"] description] ?: @"track";
    NSString *filename = [NSString stringWithFormat:@"%@.%@", trackID, ext];
    NSString *path = [[self downloadsDirectory] stringByAppendingPathComponent:filename];
    NSError *moveError = nil;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    if (![NSFileManager.defaultManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:path] error:&moveError]) {
        _downloadFailureReason = moveError.localizedDescription ?: @"Could not save the downloaded file.";
        return;
    }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if ([attributes[NSFileSize] unsignedLongLongValue] == 0) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        _downloadFailureReason = @"The downloaded file was empty.";
        return;
    }
    _finishedPath = path;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task != _activeTask) return;
    NSDictionary *track = _activeTrack;
    NSString *trackID = [track[@"id"] description] ?: @"";
    NSString *failure = error.localizedDescription ?: _downloadFailureReason;

    if (!error && _finishedPath.length && !_downloadFailureReason) {
        NSMutableDictionary *entry = [@{
            @"id": trackID,
            @"title": [track[@"name"] isKindOfClass:NSString.class] ? track[@"name"] : @"Unknown track",
            @"artist": [track[@"artist_name"] isKindOfClass:NSString.class] ? track[@"artist_name"] : @"Unknown artist",
            @"album": [track[@"album_name"] isKindOfClass:NSString.class] ? track[@"album_name"] : @"",
            @"license": [self licenseForTrack:track],
            @"licenseURL": [self licenseURLForTrack:track],
            @"filename": _finishedPath.lastPathComponent,
            @"source": [track[@"shareurl"] isKindOfClass:NSString.class] ? track[@"shareurl"] : @"",
            @"added": @((long long)NSDate.date.timeIntervalSince1970)
        } mutableCopy];
        [_library removeObjectsAtIndexes:[_library indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
            return [obj[@"id"] isEqualToString:trackID];
        }]];
        [_library insertObject:entry atIndex:0];
        [NSUserDefaults.standardUserDefaults setObject:_library forKey:kSGAuthorizedLibraryKey];
        _states[trackID] = @"Saved";
        [_progress removeObjectForKey:trackID];
        SGLog(@"authorized downloads: saved %@ by %@", entry[@"title"], entry[@"artist"]);
    } else {
        _states[trackID] = @"Failed";
        [_progress removeObjectForKey:trackID];
        if (_finishedPath.length) [NSFileManager.defaultManager removeItemAtPath:_finishedPath error:nil];
        SGLog(@"authorized downloads: %@ failed: %@", trackID, failure ?: @"unknown download error");
    }
    _activeTask = nil;
    _activeTrack = nil;
    _finishedPath = nil;
    _downloadFailureReason = nil;
    [self.tableView reloadData];
    [self startNextDownload];
    if (_closing && !_activeTask && !_queue.count) [_downloadSession finishTasksAndInvalidate];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_segments.selectedSegmentIndex != 1 || indexPath.row >= (NSInteger)_library.count) return;
    NSDictionary *entry = _library[(NSUInteger)indexPath.row];
    NSString *path = [[self downloadsDirectory] stringByAppendingPathComponent:entry[@"filename"] ?: @""];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"File not found"
                                                                       message:@"This file is missing from Vitrine's download folder."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove entry" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self deleteEntryAtIndex:indexPath.row];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:entry[@"title"] ?: @"Downloaded track"
                                                                   message:[NSString stringWithFormat:@"%@\n%@", entry[@"artist"] ?: @"", entry[@"license"] ?: @""]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share / export file" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        activity.popoverPresentationController.sourceView = cell;
        activity.popoverPresentationController.sourceRect = cell.bounds;
        [self presentViewController:activity animated:YES completion:nil];
    }]];
    NSString *licenseURL = [entry[@"licenseURL"] isKindOfClass:NSString.class] ? entry[@"licenseURL"] : @"";
    if (licenseURL.length) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"View licence" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSURL *url = [NSURL URLWithString:licenseURL];
            if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete from Vitrine" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self deleteEntryAtIndex:indexPath.row];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceRect = [tableView cellForRowAtIndexPath:indexPath].bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)deleteEntryAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_library.count) return;
    NSDictionary *entry = _library[(NSUInteger)index];
    NSString *path = [[self downloadsDirectory] stringByAppendingPathComponent:entry[@"filename"] ?: @""];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    [_library removeObjectAtIndex:(NSUInteger)index];
    [NSUserDefaults.standardUserDefaults setObject:_library forKey:kSGAuthorizedLibraryKey];
    [self.tableView reloadData];
}

@end

void SGRAuthorizedDownloadsPresent(UIView *source, NSString *trackTitle, NSString *artistName, NSTimeInterval duration) {
    UIWindow *window = source.window;
    UIViewController *presenter = window.rootViewController;
    if (!presenter) return;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    SGAuthorizedDownloadsController *page = [[SGAuthorizedDownloadsController alloc] initWithTitle:trackTitle ?: @"" artist:artistName ?: @"" duration:duration];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        navigation.sheetPresentationController.prefersGrabberVisible = YES;
    }
    SGPresentDark(navigation);
    [presenter presentViewController:navigation animated:YES completion:nil];
}
