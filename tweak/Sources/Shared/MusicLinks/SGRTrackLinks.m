// Cross-platform song link resolver. This deliberately opens official music-service pages
// rather than copying protected streams or writing Spotify's private offline-download records.
#import "Core/SGCore.h"
#import "SGRTrackLinks.h"

static NSString *SGRPlatformName(NSString *key) {
    NSDictionary<NSString *, NSString *> *names = @{
        @"spotify": @"Spotify",
        @"appleMusic": @"Apple Music",
        @"itunes": @"iTunes Store",
        @"youtubeMusic": @"YouTube Music",
        @"youtube": @"YouTube",
        @"soundcloud": @"SoundCloud",
        @"deezer": @"Deezer",
        @"tidal": @"TIDAL",
        @"amazonMusic": @"Amazon Music",
        @"pandora": @"Pandora",
        @"napster": @"Napster",
        @"yandex": @"Yandex Music",
        @"anghami": @"Anghami",
        @"audius": @"Audius",
        @"qobuz": @"Qobuz"
    };
    return names[key] ?: key;
}

@interface SGRTrackLinksController : UITableViewController <UISearchBarDelegate>
@property (nonatomic, copy) NSString *trackTitle;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *trackURI;
- (instancetype)initWithTitle:(NSString *)title artist:(NSString *)artist trackURI:(NSString *)trackURI;
@end

@implementation SGRTrackLinksController {
    UISearchBar *_searchBar;
    NSMutableArray<NSDictionary *> *_items;
    NSURLSessionDataTask *_task;
    BOOL _searchMode;
    BOOL _loading;
    BOOL _started;
    NSString *_statusMessage;
}

- (instancetype)initWithTitle:(NSString *)title artist:(NSString *)artist trackURI:(NSString *)trackURI {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.trackTitle = [title copy] ?: @"";
    self.artistName = [artist copy] ?: @"";
    self.trackURI = [trackURI copy] ?: @"";
    _items = [NSMutableArray array];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Find Across Platforms";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68;

    _searchBar = [UISearchBar new];
    _searchBar.delegate = self;
    _searchBar.placeholder = @"Search title or artist";
    _searchBar.text = [[@[self.trackTitle ?: @"", self.artistName ?: @""] componentsJoinedByString:@" "]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _searchBar.hidden = YES;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.tableView.bounds), 0)];
    [header addSubview:_searchBar];
    self.tableView.tableHeaderView = header;
    [self layoutSearchHeader];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Search"
                                                                                style:UIBarButtonItemStylePlain
                                                                               target:self
                                                                               action:@selector(toggleSearch)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                           target:self
                                                                                           action:@selector(close)];

    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectZero];
    footer.text = @"Exact matches open the service's official song page. Search links are included for platforms that did not return an exact match. Full-track downloads are available only through each service's own download or purchase options.";
    footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footer.textColor = UIColor.secondaryLabelColor;
    footer.numberOfLines = 0;
    footer.textAlignment = NSTextAlignmentCenter;
    footer.frame = CGRectMake(0, 0, MAX(0, CGRectGetWidth(self.tableView.bounds) - 40), 96);
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableFooterView = footer;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutSearchHeader];
}

- (void)layoutSearchHeader {
    UIView *header = self.tableView.tableHeaderView;
    if (!header) return;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    CGFloat height = _searchMode ? 56.0 : 0.0;
    header.frame = CGRectMake(0, 0, width, height);
    _searchBar.frame = CGRectMake(0, 0, width, 56);
    _searchBar.hidden = !_searchMode;
    self.tableView.tableHeaderView = header;
}

- (void)toggleSearch {
    _searchMode = !_searchMode;
    [self layoutSearchHeader];
    if (_searchMode) {
        [_searchBar becomeFirstResponder];
    } else {
        [_searchBar resignFirstResponder];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_started) return;
    _started = YES;
    [self resolveCurrentTrack];
}

- (void)close {
    [_task cancel];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSString *)spotifyURLFromTrackURI {
    NSString *value = [self.trackURI stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([value.lowercaseString hasPrefix:@"https://open.spotify.com/track/"]) return value;
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@":"];
    if (parts.count >= 3 && [parts[0] isEqualToString:@"spotify"] && [parts[1] isEqualToString:@"track"] && parts[2].length) {
        NSString *trackID = parts[2];
        NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
        if ([trackID rangeOfCharacterFromSet:[safe invertedSet]].location != NSNotFound) return nil;
        return [NSString stringWithFormat:@"https://open.spotify.com/track/%@", trackID];
    }
    return nil;
}

- (NSString *)currentSearchQuery {
    return [[@[self.trackTitle ?: @"", self.artistName ?: @""] componentsJoinedByString:@" "]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSArray<NSDictionary *> *)platformSearchItemsForQuery:(NSString *)query excludingKeys:(NSSet<NSString *> *)excludedKeys {
    NSArray<NSDictionary *> *platforms = @[
        @{@"key": @"spotify", @"name": @"Spotify", @"base": @"https://open.spotify.com/search", @"parameter": @"q"},
        @{@"key": @"appleMusic", @"name": @"Apple Music", @"base": @"https://music.apple.com/us/search", @"parameter": @"term"},
        @{@"key": @"youtubeMusic", @"name": @"YouTube Music", @"base": @"https://music.youtube.com/search", @"parameter": @"q"},
        @{@"key": @"youtube", @"name": @"YouTube", @"base": @"https://www.youtube.com/results", @"parameter": @"search_query"},
        @{@"key": @"soundcloud", @"name": @"SoundCloud", @"base": @"https://soundcloud.com/search/sounds", @"parameter": @"q"},
        @{@"key": @"deezer", @"name": @"Deezer", @"base": @"https://www.deezer.com/search", @"parameter": @"q"},
        @{@"key": @"tidal", @"name": @"TIDAL", @"base": @"https://listen.tidal.com/search", @"parameter": @"q"},
        @{@"key": @"amazonMusic", @"name": @"Amazon Music", @"base": @"https://music.amazon.com/search", @"parameter": @"k"}
    ];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (NSDictionary *platform in platforms) {
        NSString *key = platform[@"key"];
        if ([excludedKeys containsObject:key]) continue;
        NSURLComponents *components = [NSURLComponents componentsWithString:platform[@"base"]];
        components.queryItems = @[[NSURLQueryItem queryItemWithName:platform[@"parameter"] value:query]];
        NSString *url = components.URL.absoluteString;
        if (!url.length) continue;
        [items addObject:@{
            @"platformKey": key,
            @"platform": platform[@"name"],
            @"url": url,
            @"detail": @"Search this service",
            @"isSearch": @YES
        }];
    }
    return items;
}

- (void)showFallbackSearchesWithMessage:(NSString *)message {
    [_items removeAllObjects];
    NSString *query = [self currentSearchQuery];
    if (!query.length) query = self.trackTitle ?: self.artistName ?: @"";
    NSArray<NSDictionary *> *searches = [self platformSearchItemsForQuery:query excludingKeys:[NSSet set]];
    [_items addObjectsFromArray:searches];
    _loading = NO;
    _statusMessage = message;
    [self.tableView reloadData];
}

- (void)resolveCurrentTrack {
    NSString *sourceURL = [self spotifyURLFromTrackURI];
    if (!sourceURL.length) {
        [self showFallbackSearchesWithMessage:@"This track has no Spotify catalogue URL. Search across services below."];
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://api.song.link/v1-alpha.1/links"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url" value:sourceURL],
        [NSURLQueryItem queryItemWithName:@"userCountry" value:@"DZ"]
    ];
    NSURL *url = components.URL;
    if (!url) {
        [self showFallbackSearchesWithMessage:@"Could not create the link lookup request. Search each service below."];
        return;
    }

    [_task cancel];
    _loading = YES;
    _statusMessage = @"Finding this track across music services…";
    [_items removeAllObjects];
    [self.tableView reloadData];

    __weak typeof(self) weakSelf = self;
    _task = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            if (error) {
                if (error.code == NSURLErrorCancelled) return;
                [self showFallbackSearchesWithMessage:@"Automatic matching is unavailable right now. These are direct searches on each service."];
                return;
            }
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            NSError *jsonError = nil;
            id payload = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
            NSDictionary *links = [payload isKindOfClass:NSDictionary.class] && [payload[@"linksByPlatform"] isKindOfClass:NSDictionary.class]
                ? payload[@"linksByPlatform"] : nil;
            if (!http || http.statusCode < 200 || http.statusCode >= 300 || jsonError || !links.count) {
                [self showFallbackSearchesWithMessage:@"No exact cross-platform match was returned. Search directly on each service below."];
                return;
            }

            [self->_items removeAllObjects];
            NSMutableSet<NSString *> *matchedKeys = [NSMutableSet set];
            NSArray<NSString *> *order = @[@"spotify", @"appleMusic", @"itunes", @"youtubeMusic", @"youtube", @"soundcloud", @"deezer", @"tidal", @"amazonMusic", @"pandora", @"napster", @"yandex", @"anghami", @"qobuz", @"audius"];
            for (NSString *key in order) {
                NSDictionary *entry = [links[key] isKindOfClass:NSDictionary.class] ? links[key] : nil;
                NSString *link = [entry[@"url"] isKindOfClass:NSString.class] ? entry[@"url"] : @"";
                NSURL *candidateURL = [NSURL URLWithString:link];
                if (!candidateURL || ![candidateURL.scheme.lowercaseString isEqualToString:@"https"]) continue;
                NSString *displayName = SGRPlatformName(key);
                [_items addObject:@{
                    @"platformKey": key,
                    @"platform": displayName,
                    @"url": link,
                    @"detail": @"Exact cross-platform match",
                    @"isSearch": @NO
                }];
                [matchedKeys addObject:key];
            }

            // Always provide search links for major services that did not return a matched track.
            NSArray<NSDictionary *> *fallbacks = [self platformSearchItemsForQuery:[self currentSearchQuery] excludingKeys:matchedKeys];
            [self->_items addObjectsFromArray:fallbacks];
            self->_loading = NO;
            self->_statusMessage = self->_items.count
                ? @"Matched links appear first; remaining rows search that service by title and artist."
                : @"No service links were returned. Use Search to enter a title or artist.";
            [self.tableView reloadData];
        });
    }];
    [_task resume];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *query = [searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) query = [self currentSearchQuery];
    [self showFallbackSearchesWithMessage:@"Showing direct searches for your query across major music services."];
    if (query.length) {
        [_items removeAllObjects];
        [_items addObjectsFromArray:[self platformSearchItemsForQuery:query excludingKeys:[NSSet set]]];
        [self.tableView reloadData];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _loading || !_items.count ? 1 : (NSInteger)_items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseID = @"serviceLink";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 2;

    if (_loading || !_items.count) {
        cell.textLabel.text = _loading ? @"Searching music services…" : (_statusMessage ?: @"No service links available.");
        cell.detailTextLabel.text = _loading ? @"Please wait…" : @"Tap Search to look up another title or artist.";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    NSDictionary *item = _items[(NSUInteger)indexPath.row];
    cell.textLabel.text = item[@"platform"] ?: @"Music service";
    cell.detailTextLabel.text = item[@"detail"] ?: @"Open service";
    cell.textLabel.textColor = UIColor.labelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_loading || indexPath.row >= (NSInteger)_items.count) return;
    NSString *link = _items[(NSUInteger)indexPath.row][@"url"];
    NSURL *url = [NSURL URLWithString:link ?: @""];
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"]) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

@end

void SGRTrackLinksPresent(UIView *source, NSString *trackTitle, NSString *artistName, NSString *trackURI) {
    UIWindow *window = source.window;
    UIViewController *presenter = window.rootViewController;
    if (!presenter) return;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    SGRTrackLinksController *page = [[SGRTrackLinksController alloc] initWithTitle:trackTitle ?: @""
                                                                           artist:artistName ?: @""
                                                                          trackURI:trackURI ?: @""];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        navigation.sheetPresentationController.prefersGrabberVisible = YES;
    }
    SGPresentDark(navigation);
    [presenter presentViewController:navigation animated:YES completion:nil];
}
