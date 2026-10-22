// Search official music platforms for the currently playing track.
// This panel opens each platform's own search results; it does not extract audio streams.
#import "Core/SGCore.h"
#import "SGRTrackLinks.h"
#import <Security/Security.h>

static void SGRClearLegacyOpenverseCredentials(void) {
    NSString *service = @"com.fastx.vitrine.openverse";
    for (NSString *account in @[@"client-id", @"client-secret"]) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: service,
            (__bridge id)kSecAttrAccount: account
        };
        SecItemDelete((__bridge CFDictionaryRef)query);
    }
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
    NSString *_searchQuery;
    NSArray<NSDictionary *> *_services;
}

- (instancetype)initWithTitle:(NSString *)title
                        artist:(NSString *)artist
                      trackURI:(NSString *)trackURI
                      duration:(NSTimeInterval)duration {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;

    _trackTitle = [title copy] ?: @"";
    _artistName = [artist copy] ?: @"";
    _searchQuery = [[NSString stringWithFormat:@"%@ %@", _trackTitle, _artistName]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    (void)trackURI;
    (void)duration;

    SGRClearLegacyOpenverseCredentials();
    return self;
}

- (NSURL *)searchURLForBase:(NSString *)base queryName:(NSString *)queryName {
    NSURLComponents *components = [NSURLComponents componentsWithString:base];
    if (!components) return nil;
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:queryName value:_searchQuery ?: @""]
    ];
    return components.URL;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Find Track Online";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(close)];

    _services = @[
        @{
            @"name": @"YouTube",
            @"detail": @"Search videos and official uploads",
            @"url": [self searchURLForBase:@"https://www.youtube.com/results"
                                 queryName:@"search_query"].absoluteString ?: @""
        },
        @{
            @"name": @"YouTube Music",
            @"detail": @"Search music releases and artist pages",
            @"url": [self searchURLForBase:@"https://music.youtube.com/search"
                                 queryName:@"q"].absoluteString ?: @""
        },
        @{
            @"name": @"SoundCloud",
            @"detail": @"Find tracks and creator uploads",
            @"url": [self searchURLForBase:@"https://soundcloud.com/search"
                                 queryName:@"q"].absoluteString ?: @""
        },
        @{
            @"name": @"Bandcamp",
            @"detail": @"Find artist pages and available purchases",
            @"url": [self searchURLForBase:@"https://bandcamp.com/search"
                                 queryName:@"q"].absoluteString ?: @""
        },
        @{
            @"name": @"Apple Music",
            @"detail": @"Search the official music catalog",
            @"url": [self searchURLForBase:@"https://music.apple.com/search"
                                 queryName:@"term"].absoluteString ?: @""
        },
        @{
            @"name": @"Deezer",
            @"detail": @"Search the official music catalog",
            @"url": [self searchURLForBase:@"https://www.deezer.com/search"
                                 queryName:@"q"].absoluteString ?: @""
        }
    ];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.tableView.bounds), 88)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *trackLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, MAX(0, CGRectGetWidth(header.bounds) - 36), 64)];
    trackLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    trackLabel.numberOfLines = 2;
    trackLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    trackLabel.textColor = UIColor.labelColor;
    NSString *artistLine = _artistName.length ? _artistName : @"";
    trackLabel.text = artistLine.length
        ? [NSString stringWithFormat:@"%@\n%@", _trackTitle.length ? _trackTitle : @"Unknown track", artistLine]
        : (_trackTitle.length ? _trackTitle : @"Unknown track");
    [header addSubview:trackLabel];
    self.tableView.tableHeaderView = header;

    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 320, 72)];
    footer.text = @"Choose a service to open its search results. Listening, purchase, and offline options are provided by each service or the uploader.";
    footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footer.textColor = UIColor.secondaryLabelColor;
    footer.numberOfLines = 0;
    footer.textAlignment = NSTextAlignmentCenter;
    footer.frame = CGRectMake(0, 0, MAX(0, CGRectGetWidth(self.tableView.bounds) - 36), 72);
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableFooterView = footer;
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _services.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseID = @"musicPlatformSearch";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
    }

    NSDictionary *service = _services[indexPath.row];
    cell.textLabel.text = service[@"name"];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.text = service[@"detail"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *urlString = _services[indexPath.row][@"url"];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
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
