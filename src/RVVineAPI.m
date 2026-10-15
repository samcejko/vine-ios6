#import "RVVineAPI.h"
#import "RVDivine.h"
#import "RVIDMap.h"
#import "RVAssets.h"
#import "RVURLProtocol.h"
#import "RVMediaCheck.h"
#import "RVCommon.h"

#include <time.h>

@implementation RVVineResponse
@end

// Served by RVAssets through RVURLProtocol (the app asks for these hosts, nobody else answers them any more)
static NSString * const RVDefaultAvatarURL = @"http://v.cdn.vine.co/avatars/default.png";
static NSString * const RVAssetBase = @"http://media.vineapp.com/revine/";

// Channels: the two archives first, then diVine's categories. Vine shows a channel by its number; the feeds behind
// them are answered in RVChannelTimeline.
static const long long RVChannelClassics = 1;
static const long long RVChannelNew = 2;
static const long long RVChannelCategoryBase = 10;

static NSArray *RVCategories(void)
{
    // diVine category, title key, colour (Vine's channel colours: RRGGBB)
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @[@"comedy",        @"ChannelComedy",        @"ffaf40"],
            @[@"animals",       @"ChannelAnimals",       @"e8a04f"],
            @[@"music",         @"ChannelMusic",         @"5082e5"],
            @[@"dance",         @"ChannelDance",         @"ff6fa8"],
            @[@"art",           @"ChannelArt",           @"7870cc"],
            @[@"entertainment", @"ChannelEntertainment", @"ff5967"],
            @[@"family",        @"ChannelFamily",        @"68bf60"],
            @[@"sports",        @"ChannelSports",        @"33ccbf"],
            @[@"fashion",       @"ChannelFashion",       @"c56ad8"],
            @[@"food",          @"ChannelFood",          @"f26a4b"],
            @[@"travel",        @"ChannelTravel",        @"4fb8e8"],
            @[@"gaming",        @"ChannelGaming",        @"5b5fd6"],
            @[@"education",     @"ChannelEducation",     @"8fa83a"],
            @[@"news",          @"ChannelNews",          @"6f8590"],
        ];
    });
    return list;
}

#pragma mark - Small helpers

static NSString *RVVineDate(long long unixTime)
{
    if (unixTime <= 0) unixTime = (long long)time(NULL);
    time_t t = (time_t)unixTime;
    struct tm parts;
    gmtime_r(&t, &parts);
    char buf[48];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S.000000", &parts);
    return [NSString stringWithUTF8String:buf];
}

static NSString *RVTagValue(NSArray *tags, NSString *name)
{
    for (id entry in tags) {
        NSArray *tag = RVArr(entry);
        if (tag.count >= 2 && [RVStr(tag[0]) isEqualToString:name]) return RVStr(tag[1]);
    }
    return nil;
}

static NSArray *RVTagValues(NSArray *tags, NSString *name)
{
    NSMutableArray *values = [NSMutableArray array];
    for (id entry in tags) {
        NSArray *tag = RVArr(entry);
        if (tag.count >= 2 && [RVStr(tag[0]) isEqualToString:name] && RVStr(tag[1]).length) [values addObject:RVStr(tag[1])];
    }
    return values;
}

// A field of the NIP-94 "imeta" tag ("url https://...", "image https://...")
static NSString *RVImetaValue(NSArray *tags, NSString *field)
{
    NSString *prefix = [field stringByAppendingString:@" "];
    for (id entry in tags) {
        NSArray *tag = RVArr(entry);
        if (tag.count < 2 || ![RVStr(tag[0]) isEqualToString:@"imeta"]) continue;
        for (NSUInteger i = 1; i < tag.count; i++) {
            NSString *part = RVStr(tag[i]);
            if ([part hasPrefix:prefix]) return [part substringFromIndex:prefix.length];
        }
    }
    return nil;
}

static NSString *RVNonEmpty(NSString *value)
{
    return [value isKindOfClass:[NSString class]] && value.length ? value : nil;
}

// diVine's media server serves a blob with or without an extension; Vine names its cached files after the URL and
// the player goes by the extension, so videos get ".mp4"
static NSString *RVMediaURL(NSString *url, NSString *extension)
{
    if (!url.length) return url;
    NSString *last = [[NSURL URLWithString:url] lastPathComponent];
    if (last.length && [last rangeOfString:@"."].location == NSNotFound) return [url stringByAppendingFormat:@".%@", extension];
    return url;
}

// A picture URL the app can load (pictures elsewhere than on diVine go through the tweak's TLS stack too)
static NSString *RVAvatar(NSString *url)
{
    url = RVNonEmpty(url);
    return url ? [RVURLProtocol proxyURLForURL:url] : RVDefaultAvatarURL;
}

static NSString *RVShortName(NSString *pubkey)
{
    return pubkey.length >= 8 ? [NSString stringWithFormat:@"%@ %@", L(@"User"), [pubkey substringToIndex:8]] : L(@"User");
}

// Vine's profile colours; a user without one gets a steady pick from the public key
static NSString *RVProfileColor(NSString *pubkey, NSString *banner)
{
    if (banner.length == 8 && [banner hasPrefix:@"0x"]) return banner;
    static NSArray *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palette = @[@"0x00bf8f", @"0x5082e5", @"0x68bf60", @"0xff5967", @"0xffaf40", @"0x7870cc", @"0x33ccbf", @"0xc56ad8"];
    });
    NSUInteger sum = 0;
    for (NSUInteger i = 0; i < MIN((NSUInteger)8, pubkey.length); i++) sum += [pubkey characterAtIndex:i];
    return palette[sum % palette.count];
}

#pragma mark - Envelopes

static RVVineResponse *RVJSONResponse(NSInteger status, id object)
{
    RVVineResponse *response = [[RVVineResponse alloc] init];
    response.status = status;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL] ?: [NSData data];
    return response;
}

static RVVineResponse *RVSuccess(id data)
{
    return RVJSONResponse(200, @{ @"code": @"", @"data": data ?: @{}, @"success": @YES, @"error": @"" });
}

static RVVineResponse *RVFailure(NSInteger status, NSString *message)
{
    return RVJSONResponse(status, @{ @"code": @"", @"data": @"", @"success": @NO, @"error": message ?: @"" });
}

static RVVineResponse *RVReadOnly(void)
{
    return RVFailure(400, L(@"ReadOnlyMessage"));
}

static RVVineResponse *RVUnreachable(NSError *error)
{
    RVLog(@"diVine unreachable: %@", error.localizedDescription);
    return RVFailure(503, L(@"UnreachableMessage"));
}

typedef struct {
    NSInteger page;     // 1-based
    NSInteger size;
    NSInteger offset;
} RVPage;

static RVPage RVPageFromQuery(NSDictionary *query, NSInteger defaultSize)
{
    RVPage p;
    p.page = MAX((NSInteger)1, (NSInteger)RVLong(query[@"page"]));
    p.size = RVLong(query[@"size"]) > 0 ? MIN((NSInteger)50, (NSInteger)RVLong(query[@"size"])) : defaultSize;
    p.offset = (p.page - 1) * p.size;
    return p;
}

static NSDictionary *RVPaged(NSArray *records, RVPage p, BOOL hasMore, long long total)
{
    long long count = total > 0 ? total : (long long)(p.offset + records.count + (hasMore ? p.size : 0));
    return @{
        @"count": @(count),
        @"records": records ?: @[],
        @"anchor": @0,
        @"anchorStr": @"0",
        @"backAnchor": @"",
        @"previousPage": p.page > 1 ? @(p.page - 1) : [NSNull null],
        @"nextPage": hasMore ? @(p.page + 1) : [NSNull null],
        @"size": @(p.size),
    };
}

static NSDictionary *RVCountOnly(long long count)
{
    return @{
        @"count": @(count), @"records": @[], @"anchor": @0, @"anchorStr": @"0", @"backAnchor": @"",
        @"previousPage": [NSNull null], @"nextPage": count > 0 ? @2 : [NSNull null], @"size": @10,
    };
}

#pragma mark - Records

// A video of api/videos lists, or the {event, stats} answer of api/videos/<id>, as one flat dictionary
static NSDictionary *RVFlatVideo(NSDictionary *video)
{
    NSDictionary *event = RVDict(video[@"event"]);
    if (!event) return video;
    NSMutableDictionary *flat = [event mutableCopy];
    NSDictionary *stats = RVDict(video[@"stats"]);
    for (NSString *key in stats) if (!flat[key]) flat[key] = stats[key];
    return flat;
}

// Vine counts entity ranges in Unicode code points (it cuts the caption as UTF-32 data): an emoji is one, not the
// two UTF-16 units NSString counts. A range past the end crashes the app (-[VNEntity initWithJSON:inString:]).
static NSUInteger RVCodePoints(NSString *text, NSUInteger utf16Index)
{
    return [[text substringToIndex:MIN(utf16Index, text.length)] lengthOfBytesUsingEncoding:NSUTF32LittleEndianStringEncoding] / 4;
}

// Hashtags of a caption as Vine entities: tappable, with their character range
static NSArray *RVTagEntities(NSString *text, NSMutableOrderedSet *names)
{
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"#([\\p{L}\\p{N}_]+)" options:0 error:NULL];
    });
    NSMutableArray *entities = [NSMutableArray array];
    if (!text.length) return entities;
    for (NSTextCheckingResult *match in [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        NSString *name = [text substringWithRange:[match rangeAtIndex:1]];
        NSRange range = match.range;
        [names addObject:name];
        [entities addObject:@{
            @"type": @"tag",
            @"id": @([RVIDMap idForName:[name lowercaseString] kind:RVIDKindTag]),
            @"title": name,
            @"range": @[@(RVCodePoints(text, range.location)), @(RVCodePoints(text, NSMaxRange(range)))],
            @"link": [@"vine://tag/" stringByAppendingString:[RVDivine escape:name]],
            @"vanityUrls": @[],
        }];
    }
    return entities;
}

static NSDictionary *RVPostRecord(NSDictionary *video)
{
    NSDictionary *v = RVFlatVideo(video);
    NSString *eventID = RVStr(v[@"id"]);
    NSString *pubkey = RVStr(v[@"pubkey"]);
    if (eventID.length < 15 || pubkey.length < 15) return nil;
    NSArray *tags = RVArr(v[@"tags"]);

    NSString *videoURL = RVNonEmpty(RVStr(v[@"video_url"])) ?: RVImetaValue(tags, @"url");
    if (!videoURL.length) return nil;
    videoURL = RVMediaURL(videoURL, @"mp4");
    NSString *thumbnail = [RVURLProtocol proxyURLForURL:RVNonEmpty(RVStr(v[@"thumbnail"])) ?: RVImetaValue(tags, @"image")] ?: @"";

    NSString *platform = RVNonEmpty(RVStr(v[@"platform"])) ?: RVTagValue(tags, @"platform");
    BOOL classic = [platform isEqualToString:@"vine"];
    NSString *title = RVNonEmpty(RVStr(v[@"title"])) ?: RVTagValue(tags, @"title");
    NSString *content = RVNonEmpty(RVStr(v[@"content"]));
    // (archived posts carry "Original stats: ..." in their content; their caption is the title)
    NSString *text = (classic || !content) ? (title ?: content ?: @"") : content;
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    long long loops = MAX(RVLong(v[@"loops"]), MAX(RVLong(v[@"embedded_loops"]), RVLong(RVTagValue(tags, @"loops"))));
    long long likes = RVLong(v[@"embedded_likes"]) + RVLong(v[@"reactions"]);
    if (!likes) likes = RVLong(RVTagValue(tags, @"likes"));
    long long comments = RVLong(v[@"embedded_comments"]) + RVLong(v[@"comments"]);
    if (!comments) comments = RVLong(RVTagValue(tags, @"comments"));
    long long reposts = RVLong(v[@"embedded_reposts"]) + RVLong(v[@"reposts"]);
    if (!reposts) reposts = RVLong(RVTagValue(tags, @"reposts"));

    long long when = RVLong(v[@"published_at"]);
    if (!when) when = RVLong(RVTagValue(tags, @"published_at"));
    if (!when) when = RVLong(v[@"created_at"]);

    NSString *username = RVNonEmpty(RVStr(v[@"author_name"])) ?: RVTagValue(tags, @"author") ?: RVShortName(pubkey);
    NSString *avatar = RVAvatar(RVStr(v[@"author_avatar"]));

    NSString *vineShortID = classic ? (RVTagValue(tags, @"vine_id") ?: RVNonEmpty(RVStr(v[@"d_tag"]))) : nil;
    NSString *permalink = vineShortID ? [@"https://vine.co/v/" stringByAppendingString:vineShortID]
                                      : [@"https://divine.video/video/" stringByAppendingString:eventID];

    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    NSArray *entities = RVTagEntities(text, names);
    for (NSString *t in RVTagValues(tags, @"t")) [names addObject:t];
    NSMutableArray *tagRecords = [NSMutableArray array];
    for (NSString *name in names) {
        [tagRecords addObject:@{ @"tagId": @([RVIDMap idForName:[name lowercaseString] kind:RVIDKindTag]), @"tag": name }];
    }

    return @{
        @"postId": [RVIDMap numberForHex:eventID kind:RVIDKindPost],
        @"userId": [RVIDMap numberForHex:pubkey kind:RVIDKindUser],
        @"username": username,
        @"avatarUrl": avatar,
        @"description": text,
        @"created": RVVineDate(when),
        @"videoUrl": videoURL,
        @"videoLowURL": videoURL,
        @"videoDashUrl": videoURL,
        @"thumbnailUrl": thumbnail,
        @"permalinkUrl": permalink,
        @"shareUrl": permalink,
        @"liked": @0,
        @"myRepostId": @0,
        @"following": @0,
        @"followRequested": @0,
        @"blocked": @0,
        @"private": @0,
        @"explicitContent": @0,
        @"verified": @0,
        @"promoted": @0,
        @"vanityUrls": @[],
        @"foursquareVenueId": [NSNull null],
        @"profileBackground": RVProfileColor(pubkey, nil),
        @"loops": @{ @"count": @((double)loops), @"velocity": @0.0, @"onFire": @0 },
        @"likes": RVCountOnly(likes),
        @"comments": RVCountOnly(comments),
        @"reposts": RVCountOnly(reposts),
        @"tags": tagRecords,
        @"entities": entities,
    };
}

static NSArray *RVPostRecords(NSArray *videos)
{
    NSMutableArray *records = [NSMutableArray array];
    for (id video in videos) {
        NSDictionary *record = RVDict(video) ? RVPostRecord(video) : nil;
        if (record) [records addObject:record];
    }
    return records;
}

// A user of api/users/<pubkey> or api/users/bulk ({pubkey, profile, social, stats, engagement}), or a flat one of
// the profile search
static NSDictionary *RVUserRecord(NSDictionary *user)
{
    NSString *pubkey = RVStr(user[@"pubkey"]);
    if (pubkey.length < 15) return nil;
    NSDictionary *profile = RVDict(user[@"profile"]) ?: user;
    NSDictionary *social = RVDict(user[@"social"]);
    NSDictionary *stats = RVDict(user[@"stats"]);
    NSDictionary *engagement = RVDict(user[@"engagement"]);

    NSString *name = RVNonEmpty(RVStr(profile[@"display_name"])) ?: RVNonEmpty(RVStr(profile[@"name"])) ?: RVShortName(pubkey);
    NSString *avatar = RVAvatar(RVStr(profile[@"picture"]));
    long long followers = social ? RVLong(social[@"follower_count"]) : RVLong(user[@"follower_count"]);
    long long following = social ? RVLong(social[@"following_count"]) : RVLong(user[@"following_count"]);
    long long posts = stats ? RVLong(stats[@"video_count"]) : RVLong(user[@"video_count"]);
    long long loops = (long long)MAX(RVDbl(engagement[@"total_loops"]), RVDbl(engagement[@"archived_loops"]));

    return @{
        @"userId": [RVIDMap numberForHex:pubkey kind:RVIDKindUser],
        @"username": name,
        @"description": RVNonEmpty(RVStr(profile[@"about"])) ?: @"",
        @"location": @"",
        @"avatarUrl": avatar,
        @"followerCount": @(followers),
        @"followingCount": @(following),
        @"postCount": @(posts),
        @"authoredPostCount": @(posts),
        @"likeCount": @(RVLong(stats[@"reaction_count"])),
        @"loopCount": @(loops),
        @"private": @0,
        @"explicitContent": @0,
        @"blocked": @0,
        @"blocking": @0,
        @"verified": @0,
        @"vanityUrls": @[],
        @"following": @0,
        @"followRequested": @0,
        @"notifyPosts": @0,
        @"repostsEnabled": @1,
        @"shareUrl": [@"https://divine.video/profile/" stringByAppendingString:pubkey],
        @"profileBackground": RVProfileColor(pubkey, RVStr(profile[@"banner"])),
        @"user": @{ @"private": @0 },
    };
}

static NSDictionary *RVGuestRecord(void)
{
    return @{
        @"userId": @(RVGuestUserID),
        @"username": L(@"GuestName"),
        @"description": L(@"GuestDescription"),
        @"location": @"",
        @"avatarUrl": RVDefaultAvatarURL,
        @"email": @"",
        @"phoneNumber": [NSNull null],
        @"followerCount": @0,
        @"followingCount": @0,
        @"postCount": @0,
        @"authoredPostCount": @0,
        @"likeCount": @0,
        @"loopCount": @0,
        @"private": @0,
        @"explicitContent": @0,
        @"blocked": @0,
        @"blocking": @0,
        @"verified": @0,
        @"verifiedEmail": @1,
        @"verifiedPhoneNumber": @1,
        @"twitterConnected": @0,
        @"facebookConnected": @0,
        @"vanityUrls": @[],
        @"following": @0,
        @"followRequested": @0,
        @"notifyPosts": @0,
        @"repostsEnabled": @1,
        @"edition": @"US",
        @"shareUrl": @"https://divine.video",
        @"profileBackground": @"0x00bf8f",
        @"user": @{ @"private": @0 },
    };
}

#pragma mark - Requests

static NSDictionary *RVParseQuery(NSString *query)
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        if (!pair.length) continue;
        NSRange eq = [pair rangeOfString:@"="];
        NSString *key = eq.location == NSNotFound ? pair : [pair substringToIndex:eq.location];
        NSString *value = eq.location == NSNotFound ? @"" : [pair substringFromIndex:eq.location + 1];
        key = [[key stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: key;
        value = [[value stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: value;
        values[key] = value;
    }
    return values;
}

// The records whose archived video exists on diVine's media server (see RVMediaCheck)
static NSArray *RVPlayableRecords(NSArray *records)
{
    // (only archived posts can miss their video; new uploads are on the media server by definition)
    NSMutableArray *urls = [NSMutableArray array];
    for (NSDictionary *record in records) {
        if ([RVStr(record[@"permalinkUrl"]) hasPrefix:@"https://vine.co/v/"] && RVStr(record[@"videoUrl"])) [urls addObject:record[@"videoUrl"]];
    }
    if (!urls.count) return records;
    NSSet *missing = [RVMediaCheck missingAmong:urls timeout:3.0];
    if (!missing.count) return records;
    NSMutableArray *playable = [NSMutableArray arrayWithCapacity:records.count];
    for (NSDictionary *record in records) if (![missing containsObject:RVStr(record[@"videoUrl"]) ?: @""]) [playable addObject:record];
    return playable;
}
// api/videos?... (a list) -> Vine timeline
static RVVineResponse *RVVideoTimeline(NSString *path, NSString *params, RVPage p)
{
    NSString *sep = [path rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&";
    NSString *full = [NSString stringWithFormat:@"%@%@%@%@limit=%ld&offset=%ld", path, sep, params ?: @"",
                      params.length ? @"&" : @"", (long)p.size, (long)p.offset];
    NSError *error = nil;
    id json = [RVDivine get:full error:&error];
    if (!json) return error.code == 404 ? RVSuccess(RVPaged(@[], p, NO, 0)) : RVUnreachable(error);
    NSArray *videos = RVArr(json) ?: RVArr(RVDict(json)[@"data"]) ?: RVArr(RVDict(json)[@"videos"]);
    NSArray *records = RVPlayableRecords(RVPostRecords(videos));
    return RVSuccess(RVPaged(records, p, videos.count >= (NSUInteger)p.size, 0));
}

// Users by public key, in that order, as Vine user records (likers, followers...)
static NSArray *RVUserRecordsForPubkeys(NSArray *pubkeys, NSArray *extras)
{
    NSDictionary *users = [RVDivine usersForPubkeys:pubkeys];
    NSMutableArray *records = [NSMutableArray array];
    for (NSUInteger i = 0; i < pubkeys.count; i++) {
        NSString *pubkey = RVStr(pubkeys[i]);
        NSDictionary *user = users[pubkey];
        NSMutableDictionary *record = [(user ? RVUserRecord(user) : RVUserRecord(@{ @"pubkey": pubkey ?: @"" })) mutableCopy];
        if (!record) continue;
        if (i < extras.count) [record addEntriesFromDictionary:extras[i]];
        [records addObject:record];
    }
    return records;
}

static RVVineResponse *RVUserProfile(NSString *vineID)
{
    if ([vineID longLongValue] == RVGuestUserID) return RVSuccess(RVGuestRecord());
    NSString *pubkey = [RVIDMap hexForString:vineID kind:RVIDKindUser];
    if (!pubkey) return RVFailure(404, L(@"NotFoundMessage"));
    NSError *error = nil;
    NSDictionary *user = [RVDivine userForPubkey:pubkey error:&error];
    if (!user) return error.code == 404 ? RVFailure(404, L(@"NotFoundMessage")) : RVUnreachable(error);
    return RVSuccess(RVUserRecord(user));
}

static RVVineResponse *RVUserSearch(NSString *term, RVPage p)
{
    // (only people with videos: diVine also knows every Nostr account that never posted one)
    NSString *path = [NSString stringWithFormat:@"/api/search/profiles?q=%@&has_videos=true&limit=%ld&offset=%ld",
                      [RVDivine escape:term], (long)p.size, (long)p.offset];
    NSError *error = nil;
    id json = [RVDivine get:path error:&error];
    if (!json) return RVUnreachable(error);
    NSArray *found = RVArr(json) ?: RVArr(RVDict(json)[@"data"]) ?: RVArr(RVDict(json)[@"profiles"]);
    NSMutableArray *records = [NSMutableArray array];
    for (id user in found) {
        NSDictionary *record = RVDict(user) ? RVUserRecord(user) : nil;
        if (record) [records addObject:record];
    }
    return RVSuccess(RVPaged(records, p, found.count >= (NSUInteger)p.size, 0));
}

static RVVineResponse *RVTagSearch(NSString *term, RVPage p)
{
    NSString *path = [NSString stringWithFormat:@"/api/hashtags?q=%@&limit=%ld&offset=%ld",
                      [RVDivine escape:term], (long)p.size, (long)p.offset];
    NSError *error = nil;
    id json = [RVDivine get:path error:&error];
    if (!json) return RVUnreachable(error);
    NSArray *found = RVArr(json) ?: RVArr(RVDict(json)[@"data"]) ?: RVArr(RVDict(json)[@"hashtags"]);
    NSMutableArray *records = [NSMutableArray array];
    for (id entry in found) {
        NSString *name = RVStr(RVDict(entry)[@"hashtag"]) ?: RVStr(RVDict(entry)[@"tag"]);
        if (!name.length) continue;
        [records addObject:@{ @"tagId": @([RVIDMap idForName:[name lowercaseString] kind:RVIDKindTag]), @"tag": name,
                              @"postCount": @(RVLong(RVDict(entry)[@"video_count"])) }];
    }
    return RVSuccess(RVPaged(records, p, found.count >= (NSUInteger)p.size, 0));
}

static NSString *RVChannelTitle(long long channelID, NSString **color)
{
    if (color) *color = @"00bf8f";
    if (channelID == RVChannelClassics) return L(@"ChannelClassics");
    if (channelID == RVChannelNew) { if (color) *color = @"ff5967"; return L(@"ChannelNew"); }
    NSArray *categories = RVCategories();
    long long index = channelID - RVChannelCategoryBase;
    if (index >= 0 && index < (long long)categories.count) {
        if (color) *color = categories[(NSUInteger)index][2];
        return L(categories[(NSUInteger)index][1]);
    }
    NSString *tag = [RVIDMap hexForID:channelID kind:RVIDKindTag];
    return tag ? [@"#" stringByAppendingString:tag] : nil;
}

static NSDictionary *RVChannelRecord(long long channelID)
{
    NSString *color = nil;
    NSString *title = RVChannelTitle(channelID, &color);
    if (!title) return nil;
    NSString *icon = [RVAssetBase stringByAppendingFormat:@"icon/%@.png", [RVDivine escape:[title substringToIndex:1]]];
    return @{
        @"channelId": @(channelID),
        @"channel": title,
        @"exploreName": title,
        @"backgroundColor": color,
        @"fontColor": @"ffffff",
        @"iconUrl": icon,
        @"retinaIconUrl": icon,
        @"exploreIconUrl": icon,
        @"exploreRetinaIconUrl": icon,
        @"showRecent": @1,
        @"following": @0,
    };
}

static RVVineResponse *RVChannelTimeline(long long channelID, BOOL recent, RVPage p)
{
    NSString *sort = recent ? @"recent" : @"trending";
    if (channelID == RVChannelClassics) {
        // popular: the archive by its original loops; recent: the classics people watch now
        return RVVideoTimeline(@"/api/videos", recent ? @"platform=vine&sort=watching" : @"classic=true", p);
    }
    if (channelID == RVChannelNew) {
        return RVVideoTimeline(@"/api/videos", [NSString stringWithFormat:@"exclude_platform=vine&sort=%@", sort], p);
    }
    NSArray *categories = RVCategories();
    long long index = channelID - RVChannelCategoryBase;
    if (index >= 0 && index < (long long)categories.count) {
        return RVVideoTimeline(@"/api/videos", [NSString stringWithFormat:@"category=%@&sort=%@",
                                                categories[(NSUInteger)index][0], sort], p);
    }
    NSString *tag = [RVIDMap hexForID:channelID kind:RVIDKindTag];
    if (tag) {
        return RVVideoTimeline(@"/api/videos", [NSString stringWithFormat:@"tag=%@&sort=%@",
                                                [RVDivine escape:tag], recent ? @"recent" : @"popular"], p);
    }
    return RVSuccess(RVPaged(@[], p, NO, 0));
}

static RVVineResponse *RVTimeline(NSString *method, NSArray *c, NSDictionary *query)
{
    RVPage p = RVPageFromQuery(query, 20);
    NSString *kind = c.count > 1 ? c[1] : @"";
    if ([kind isEqualToString:@"graph"]) {
        // Home: the guest follows nobody, so the Vine archive is the home feed, the most engaging classics first
        // (classic=true only takes effect without a sort; platform=vine filters with any sort)
        return RVVideoTimeline(@"/api/videos", @"platform=vine&sort=engagement", p);
    }
    if ([kind isEqualToString:@"popular"]) {
        return RVVideoTimeline(@"/api/videos", @"sort=trending", p);
    }
    if ([kind isEqualToString:@"global"]) {
        return RVVideoTimeline(@"/api/videos", @"sort=recent", p);
    }
    if ([kind isEqualToString:@"promoted"] || [kind isEqualToString:@"venues"]) {
        return RVSuccess(RVPaged(@[], p, NO, 0));
    }
    if ([kind isEqualToString:@"tags"] && c.count > 2) {
        return RVVideoTimeline(@"/api/videos", [NSString stringWithFormat:@"tag=%@&sort=popular", [RVDivine escape:c[2]]], p);
    }
    if ([kind isEqualToString:@"channels"] && c.count > 2) {
        BOOL recent = c.count > 3 && [c[3] isEqualToString:@"recent"];
        return RVChannelTimeline([c[2] longLongValue], recent, p);
    }
    if ([kind isEqualToString:@"posts"] && c.count > 2) {
        NSString *eventID = [RVIDMap hexForString:c[2] kind:RVIDKindPost];
        if (!eventID) return RVSuccess(RVPaged(@[], p, NO, 0));
        // (the stats answer is a flat video with its counts; the plain one has no loop count for new videos)
        NSError *error = nil;
        NSDictionary *video = RVDict([RVDivine get:[NSString stringWithFormat:@"/api/videos/%@/stats", eventID] error:&error]);
        if (!video) video = RVDict([RVDivine get:[@"/api/videos/" stringByAppendingString:eventID] error:&error]);
        if (!video) return error.code == 404 ? RVSuccess(RVPaged(@[], p, NO, 0)) : RVUnreachable(error);
        NSDictionary *record = RVPostRecord(video);
        return RVSuccess(RVPaged(record ? @[record] : @[], p, NO, 0));
    }
    if ([kind isEqualToString:@"users"] && c.count > 2) {
        if ([c[2] isEqualToString:@"trending"]) return RVVideoTimeline(@"/api/videos", @"sort=popular&period=week", p);
        if (c.count > 3 && [c[3] isEqualToString:@"likes"]) return RVSuccess(RVPaged(@[], p, NO, 0));
        NSString *pubkey = [RVIDMap hexForString:c[2] kind:RVIDKindUser];
        if (!pubkey) return RVSuccess(RVPaged(@[], p, NO, 0));
        return RVVideoTimeline([NSString stringWithFormat:@"/api/users/%@/videos", pubkey], nil, p);
    }
    RVLog(@"unknown timeline %@", [c componentsJoinedByString:@"/"]);
    return RVSuccess(RVPaged(@[], p, NO, 0));
}

static RVVineResponse *RVPostLists(NSString *method, NSArray *c, NSDictionary *query)
{
    // posts/<id>/(comments|likes|reposts)
    if (![method isEqualToString:@"GET"]) return RVReadOnly();
    RVPage p = RVPageFromQuery(query, 20);
    if (c.count < 3) return RVSuccess(RVPaged(@[], p, NO, 0));
    NSString *eventID = [RVIDMap hexForString:c[1] kind:RVIDKindPost];
    if (!eventID) return RVSuccess(RVPaged(@[], p, NO, 0));
    long long postID = [c[1] longLongValue];
    NSString *what = c[2];
    NSError *error = nil;

    if ([what isEqualToString:@"comments"]) {
        NSString *path = [NSString stringWithFormat:@"/api/videos/%@/comments?limit=%ld&offset=%ld", eventID, (long)p.size, (long)p.offset];
        NSDictionary *json = RVDict([RVDivine get:path error:&error]);
        if (!json) return error.code == 404 ? RVSuccess(RVPaged(@[], p, NO, 0)) : RVUnreachable(error);
        NSArray *comments = RVArr(json[@"comments"]) ?: RVArr(json[@"data"]);
        // (comments do not always carry their author's name: those come from the profiles, in one request)
        NSMutableArray *nameless = [NSMutableArray array];
        for (id entry in comments) {
            NSString *pubkey = RVStr(RVDict(entry)[@"pubkey"]);
            if (pubkey.length >= 15 && !RVNonEmpty(RVStr(RVDict(entry)[@"author_name"]))) [nameless addObject:pubkey];
        }
        NSDictionary *authors = nameless.count ? [RVDivine usersForPubkeys:nameless] : @{};
        NSMutableArray *records = [NSMutableArray array];
        for (id entry in comments) {
            NSDictionary *comment = RVDict(entry);
            NSString *commentID = RVStr(comment[@"id"]);
            NSString *pubkey = RVStr(comment[@"pubkey"]);
            if (commentID.length < 15 || pubkey.length < 15) continue;
            NSDictionary *profile = RVDict(RVDict(authors[pubkey])[@"profile"]);
            NSString *name = RVNonEmpty(RVStr(comment[@"author_name"])) ?: RVNonEmpty(RVStr(profile[@"display_name"])) ?:
                             RVNonEmpty(RVStr(profile[@"name"])) ?: RVShortName(pubkey);
            NSString *avatar = RVAvatar(RVNonEmpty(RVStr(comment[@"author_avatar"])) ?: RVStr(profile[@"picture"]));
            NSString *text = RVStr(comment[@"content"]) ?: @"";
            NSNumber *userID = [RVIDMap numberForHex:pubkey kind:RVIDKindUser];
            NSString *color = RVProfileColor(pubkey, nil);
            [records addObject:@{
                @"commentId": [RVIDMap numberForHex:commentID kind:RVIDKindComment],
                @"postId": @(postID),
                @"comment": text,
                @"created": RVVineDate(RVLong(comment[@"created_at"])),
                @"userId": userID,
                @"username": name,
                @"avatarUrl": avatar,
                @"verified": @0,
                @"vanityUrls": @[],
                @"profileBackground": color,
                @"entities": RVTagEntities(text, [NSMutableOrderedSet orderedSet]),
                @"videoUrl": [NSNull null],
                @"videoLowURL": [NSNull null],
                @"videoDashUrl": [NSNull null],
                @"user": @{ @"userId": userID, @"username": name, @"avatarUrl": avatar, @"verified": @0, @"private": @0,
                            @"description": @"", @"location": @"", @"profileBackground": color, @"vanityUrls": @[] },
            }];
        }
        long long total = RVLong(json[@"total"]);
        BOOL more = total ? (p.offset + (NSInteger)comments.count < total) : comments.count >= (NSUInteger)p.size;
        return RVSuccess(RVPaged(records, p, more, total));
    }

    if ([what isEqualToString:@"likes"] || [what isEqualToString:@"reposts"]) {
        BOOL likes = [what isEqualToString:@"likes"];
        NSString *path = [NSString stringWithFormat:@"/api/videos/%@/%@?limit=%ld&offset=%ld", eventID,
                          likes ? @"likers" : @"reposters", (long)p.size, (long)p.offset];
        NSDictionary *json = RVDict([RVDivine get:path error:&error]);
        if (!json) return error.code == 404 ? RVSuccess(RVPaged(@[], p, NO, 0)) : RVUnreachable(error);
        NSArray *entries = RVArr(json[@"data"]) ?: RVArr(json[likes ? @"likers" : @"reposters"]);
        NSMutableArray *pubkeys = [NSMutableArray array];
        NSMutableArray *extras = [NSMutableArray array];
        for (id entry in entries) {
            NSString *pubkey = RVStr(entry) ?: RVStr(RVDict(entry)[@"pubkey"]);
            if (pubkey.length < 15) continue;
            NSString *eventOfAction = RVStr(RVDict(entry)[@"event_id"]) ?: pubkey;
            NSNumber *actionID = [RVIDMap numberForHex:eventOfAction kind:RVIDKindComment];
            [pubkeys addObject:pubkey];
            [extras addObject:@{ (likes ? @"likeId" : @"repostId"): actionID,
                                 @"created": RVVineDate(RVLong(RVDict(entry)[@"created_at"])) }];
        }
        NSArray *records = RVUserRecordsForPubkeys(pubkeys, extras);
        BOOL more = [RVDict(json[@"pagination"])[@"has_more"] boolValue];
        return RVSuccess(RVPaged(records, p, more, 0));
    }
    return RVSuccess(RVPaged(@[], p, NO, 0));
}

static RVVineResponse *RVUserLists(NSString *pubkey, NSString *what, RVPage p)
{
    NSString *path = [NSString stringWithFormat:@"/api/v2/users/%@/%@?limit=%ld&offset=%ld", pubkey, what, (long)p.size, (long)p.offset];
    NSError *error = nil;
    NSDictionary *json = RVDict([RVDivine get:path error:&error]);
    if (!json) return error.code == 404 ? RVSuccess(RVPaged(@[], p, NO, 0)) : RVUnreachable(error);
    NSMutableArray *pubkeys = [NSMutableArray array];
    for (id entry in RVArr(json[@"data"])) {
        NSString *key = RVStr(entry) ?: RVStr(RVDict(entry)[@"pubkey"]);
        if (key.length >= 15) [pubkeys addObject:key];
    }
    NSArray *records = RVUserRecordsForPubkeys(pubkeys, nil);
    BOOL more = [RVDict(json[@"pagination"])[@"has_more"] boolValue];
    return RVSuccess(RVPaged(records, p, more, 0));
}

static RVVineResponse *RVLogin(void)
{
    // Every sign-in (e-mail, Twitter, sign up) becomes the guest: diVine accounts need Nostr keys, Vine knows none
    NSString *key = [NSString stringWithFormat:@"%lld-%@", RVGuestUserID, [[NSUUID UUID] UUIDString]];
    return RVSuccess(@{ @"username": L(@"GuestName"), @"userId": @(RVGuestUserID), @"key": [key lowercaseString],
                        @"avatarUrl": RVDefaultAvatarURL, @"edition": @"US" });
}

static RVVineResponse *RVUsers(NSString *method, NSArray *c, NSDictionary *query)
{
    RVPage p = RVPageFromQuery(query, 20);
    NSString *second = c.count > 1 ? c[1] : @"";
    if ([second isEqualToString:@"authenticate"]) {
        if ([method isEqualToString:@"DELETE"]) return RVSuccess(@{});
        return RVLogin();
    }
    if (c.count == 1) return [method isEqualToString:@"POST"] ? RVLogin() : RVSuccess(RVPaged(@[], p, NO, 0));
    if ([second isEqualToString:@"me"]) return RVSuccess(RVGuestRecord());
    if ([second isEqualToString:@"reactivate"]) return RVLogin();
    if ([second isEqualToString:@"forgotPassword"] || [second isEqualToString:@"verifyEmail"] ||
        [second isEqualToString:@"verifyPhoneNumber"]) {
        return RVSuccess(@{});
    }
    if ([second isEqualToString:@"profiles"] && c.count > 2) {
        if ([c[2] isEqualToString:@"usernames"] && c.count > 3) {
            // a mention by name: the best match of the profile search
            NSString *path = [NSString stringWithFormat:@"/api/search/profiles?q=%@&limit=1", [RVDivine escape:c[3]]];
            NSError *error = nil;
            NSArray *found = RVArr([RVDivine get:path error:&error]);
            NSDictionary *user = found.count ? RVDict(found[0]) : nil;
            NSDictionary *record = user ? RVUserRecord(user) : nil;
            return record ? RVSuccess(record) : RVFailure(404, L(@"NotFoundMessage"));
        }
        return RVUserProfile(c[2]);
    }
    if ([second isEqualToString:@"search"]) {
        NSString *term = c.count > 2 ? c[2] : RVStr(query[@"q"]);
        return RVUserSearch(term ?: @"", p);
    }
    if ([second isEqualToString:@"followers"]) return RVSuccess(RVPaged(@[], p, NO, 0));

    // users/<id>[/...]
    if (c.count == 2) {
        if ([method isEqualToString:@"GET"]) return RVUserProfile(second);
        return RVReadOnly();
    }
    NSString *what = c[2];
    BOOL guest = [second longLongValue] == RVGuestUserID;
    if ([what isEqualToString:@"followers"] || [what isEqualToString:@"following"]) {
        if (c.count > 3 && [c[3] isEqualToString:@"suggested"]) return RVSuccess(RVPaged(@[], p, NO, 0));
        if (c.count > 3 || ![method isEqualToString:@"GET"]) {
            // follow / unfollow / notifications / requests / reposts
            return [method isEqualToString:@"GET"] ? RVSuccess(RVPaged(@[], p, NO, 0)) : RVReadOnly();
        }
        NSString *pubkey = guest ? nil : [RVIDMap hexForString:second kind:RVIDKindUser];
        if (!pubkey) return RVSuccess(RVPaged(@[], p, NO, 0));
        return RVUserLists(pubkey, what, p);
    }
    if ([what isEqualToString:@"pendingNotificationsCount"]) return RVSuccess(@0);
    if ([what isEqualToString:@"activityCounts"]) {
        return RVSuccess(@{ @"notifications": @0, @"messages": @0, @"followRequests": @0, @"activity": @0 });
    }
    if ([what isEqualToString:@"preferences"] || [what isEqualToString:@"edition"]) {
        return [method isEqualToString:@"GET"] ? RVSuccess(@{}) : RVSuccess(@{});
    }
    if ([what isEqualToString:@"explicit"] || [what isEqualToString:@"blocked"] || [what isEqualToString:@"complaints"]) {
        return [method isEqualToString:@"GET"] ? RVSuccess(RVPaged(@[], p, NO, 0)) : RVReadOnly();
    }
    // notifications, conversations, contacts, friends...: nothing for the guest
    return [method isEqualToString:@"GET"] ? RVSuccess(RVPaged(@[], p, NO, 0)) : RVReadOnly();
}

static RVVineResponse *RVChannels(NSArray *c, NSDictionary *query)
{
    NSMutableArray *records = [NSMutableArray array];
    NSMutableArray *ids = [NSMutableArray arrayWithObjects:@(RVChannelClassics), @(RVChannelNew), nil];
    for (NSUInteger i = 0; i < RVCategories().count; i++) [ids addObject:@(RVChannelCategoryBase + (long long)i)];
    for (NSNumber *channelID in ids) {
        NSDictionary *record = RVChannelRecord([channelID longLongValue]);
        if (record) [records addObject:record];
    }
    RVPage p = RVPageFromQuery(query, 50);
    return RVSuccess(RVPaged(records, p, NO, (long long)records.count));
}

static RVVineResponse *RVTags(NSArray *c, NSDictionary *query)
{
    RVPage p = RVPageFromQuery(query, 20);
    NSString *second = c.count > 1 ? c[1] : @"";
    if ([second isEqualToString:@"search"]) return RVTagSearch(c.count > 2 ? c[2] : (RVStr(query[@"q"]) ?: @""), p);
    // tags/trending
    NSError *error = nil;
    id json = [RVDivine get:[NSString stringWithFormat:@"/api/hashtags/trending?limit=%ld", (long)p.size] error:&error];
    if (!json) return RVUnreachable(error);
    NSMutableArray *records = [NSMutableArray array];
    for (id entry in RVArr(json)) {
        NSString *name = RVStr(RVDict(entry)[@"hashtag"]);
        if (name.length) [records addObject:@{ @"tagId": @([RVIDMap idForName:[name lowercaseString] kind:RVIDKindTag]), @"tag": name }];
    }
    return RVSuccess(RVPaged(records, p, NO, 0));
}

static RVVineResponse *RVAPI(NSString *method, NSArray *c, NSDictionary *query)
{
    NSString *first = c.count ? c[0] : @"";
    if ([first isEqualToString:@"timelines"]) return RVTimeline(method, c, query);
    if ([first isEqualToString:@"users"]) return RVUsers(method, c, query);
    if ([first isEqualToString:@"posts"]) {
        if (c.count >= 3) return RVPostLists(method, c, query);
        return RVReadOnly();   // posting, deleting
    }
    if ([first isEqualToString:@"channels"]) return RVChannels(c, query);
    if ([first isEqualToString:@"tags"]) return RVTags(c, query);
    if ([first isEqualToString:@"loops"]) return RVSuccess(@{});
    RVPage p = RVPageFromQuery(query, 20);
    if ([first isEqualToString:@"conversations"] || [first isEqualToString:@"venues"] || [first isEqualToString:@"search"]) {
        return [method isEqualToString:@"GET"] ? RVSuccess(RVPaged(@[], p, NO, 0)) : RVReadOnly();
    }
    RVLog(@"unhandled %@ /%@", method, [c componentsJoinedByString:@"/"]);
    return [method isEqualToString:@"GET"] ? RVSuccess(RVPaged(@[], p, NO, 0)) : RVReadOnly();
}

#pragma mark - Explore page

static NSString *RVHTMLEscape(NSString *text)
{
    NSMutableString *s = [text mutableCopy] ?: [NSMutableString string];
    [s replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, s.length)];
    return s;
}

// Vine's own link that opens a channel (VNNavigationManager reads these query fields)
static NSString *RVChannelLink(long long channelID)
{
    NSString *color = nil;
    NSString *title = RVChannelTitle(channelID, &color);
    NSString *q = [RVDivine escape:title ?: @""];
    return [NSString stringWithFormat:@"vine://channels/%lld?channelId=%lld&channel=%@&name=%@&navRGB=%@&backgroundColor=%@&fontColor=ffffff&showRecent=1",
            channelID, channelID, q, q, color, color];
}

static RVVineResponse *RVExplorePage(void)
{
    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no\">"
        "<style>"
        "body{margin:0;background:#f2f2f2;font-family:'Helvetica Neue',Helvetica,sans-serif;color:#333;-webkit-text-size-adjust:none}"
        "h2{margin:18px 12px 8px;font-size:13px;font-weight:bold;text-transform:uppercase;color:#888;letter-spacing:1px}"
        ".list{background:#fff;border-top:1px solid #ddd;border-bottom:1px solid #ddd}"
        ".row{display:block;padding:13px 12px;border-bottom:1px solid #eee;color:#333;text-decoration:none;font-size:17px;font-weight:bold}"
        ".row:last-child{border-bottom:0}"
        ".dot{display:inline-block;width:12px;height:12px;border-radius:6px;margin-right:10px;vertical-align:middle}"
        ".tags{padding:4px 8px}"
        ".tag{display:inline-block;margin:4px;padding:7px 12px;border-radius:15px;background:#00bf8f;color:#fff;text-decoration:none;font-weight:bold;font-size:15px}"
        ".note{margin:16px 12px 24px;font-size:12px;color:#999;text-align:center}"
        "</style></head><body>"];

    [html appendFormat:@"<h2>%@</h2><div class=\"list\">", RVHTMLEscape(L(@"ExploreFeeds"))];
    [html appendFormat:@"<a class=\"row\" href=\"vine://popular-now\"><span class=\"dot\" style=\"background:#00bf8f\"></span>%@</a>",
        RVHTMLEscape(L(@"ExplorePopularNow"))];
    for (NSNumber *channelID in @[@(RVChannelClassics), @(RVChannelNew)]) {
        NSString *color = nil;
        NSString *title = RVChannelTitle([channelID longLongValue], &color);
        [html appendFormat:@"<a class=\"row\" href=\"%@\"><span class=\"dot\" style=\"background:#%@\"></span>%@</a>",
            RVHTMLEscape(RVChannelLink([channelID longLongValue])), color, RVHTMLEscape(title)];
    }
    [html appendString:@"</div>"];

    // Trending hashtags (as channels: Vine has no link that opens a tag)
    NSArray *trending = RVArr([RVDivine get:@"/api/hashtags/trending?limit=24" error:NULL]);
    if (trending.count) {
        [html appendFormat:@"<h2>%@</h2><div class=\"tags\">", RVHTMLEscape(L(@"ExploreTrendingTags"))];
        for (id entry in trending) {
            NSString *name = RVStr(RVDict(entry)[@"hashtag"]);
            if (!name.length) continue;
            long long channelID = [RVIDMap idForName:name kind:RVIDKindTag];
            [html appendFormat:@"<a class=\"tag\" href=\"%@\">#%@</a>", RVHTMLEscape(RVChannelLink(channelID)), RVHTMLEscape(name)];
        }
        [html appendString:@"</div>"];
    }

    [html appendFormat:@"<h2>%@</h2><div class=\"list\">", RVHTMLEscape(L(@"ExploreChannels"))];
    for (NSUInteger i = 0; i < RVCategories().count; i++) {
        long long channelID = RVChannelCategoryBase + (long long)i;
        NSString *color = nil;
        NSString *title = RVChannelTitle(channelID, &color);
        [html appendFormat:@"<a class=\"row\" href=\"%@\"><span class=\"dot\" style=\"background:#%@\"></span>%@</a>",
            RVHTMLEscape(RVChannelLink(channelID)), color, RVHTMLEscape(title)];
    }
    [html appendString:@"</div>"];
    [html appendFormat:@"<p class=\"note\">%@</p></body></html>", RVHTMLEscape(L(@"ExploreNote"))];

    RVVineResponse *response = [[RVVineResponse alloc] init];
    response.status = 200;
    response.contentType = @"text/html; charset=utf-8";
    response.body = [html dataUsingEncoding:NSUTF8StringEncoding];
    return response;
}

static RVVineResponse *RVSimplePage(NSString *message)
{
    NSString *html = [NSString stringWithFormat:@"<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>"
        "<body style=\"font-family:Helvetica;text-align:center;color:#888;padding:40px 20px\">%@</body></html>", RVHTMLEscape(message)];
    RVVineResponse *response = [[RVVineResponse alloc] init];
    response.status = 200;
    response.contentType = @"text/html; charset=utf-8";
    response.body = [html dataUsingEncoding:NSUTF8StringEncoding];
    return response;
}

#pragma mark - Entry

@implementation RVVineAPI

+ (BOOL)handlesHost:(NSString *)host
{
    host = [host lowercaseString];
    static NSSet *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = [NSSet setWithObjects:@"api.vineapp.com", @"config.vineapp.com", @"media.vineapp.com", @"vine.co",
                 @"www.vine.co", @"v.cdn.vine.co", @"mtc.cdn.vine.co", nil];
    });
    if ([hosts containsObject:host]) return YES;
    // The dead services of 2014 the app still calls: answered here so that nobody else can (a lapsed domain or
    // storage bucket could otherwise talk to every old copy of Vine)
    if ([host hasSuffix:@".s3.amazonaws.com"] || [host hasSuffix:@"testflightapp.com"] || [host hasSuffix:@"flurry.com"] ||
        [host hasSuffix:@"crashlytics.com"]) {
        return YES;
    }
    return NO;
}

+ (RVVineResponse *)responseForRequest:(NSURLRequest *)request body:(NSData *)body
{
    NSURL *url = request.URL;
    NSString *host = [url.host lowercaseString];
    NSString *method = [request.HTTPMethod uppercaseString] ?: @"GET";
    NSMutableArray *c = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) if (part.length) [c addObject:part];
    NSMutableDictionary *query = [RVParseQuery(url.query) mutableCopy];

    if ([host isEqualToString:@"api.vineapp.com"]) {
        // form fields of POSTs count as parameters too (page/size are in the query anyway)
        NSString *type = [[request valueForHTTPHeaderField:@"Content-Type"] lowercaseString];
        if (body.length && [type hasPrefix:@"application/x-www-form-urlencoded"]) {
            NSString *form = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            NSDictionary *fields = RVParseQuery(form);
            for (NSString *key in fields) if (!query[key]) query[key] = fields[key];
        }
        NSDate *start = [NSDate date];
        RVVineResponse *response = RVAPI(method, c, query);
        RVLog(@"%@ %@ -> %ld (%lu bytes, %.2f s)", method, url.path, (long)response.status,
              (unsigned long)response.body.length, -[start timeIntervalSinceNow]);
        return response;
    }
    if ([host isEqualToString:@"config.vineapp.com"]) {
        return RVSuccess(@{});
    }
    if ([host isEqualToString:@"media.vineapp.com"] || [host hasSuffix:@"cdn.vine.co"]) {
        NSData *png = nil;
        if ([url.path hasPrefix:@"/revine/icon/"]) {
            png = [RVAssets channelIconPNGForLetter:[[url.path lastPathComponent] stringByDeletingPathExtension]];
        } else if ([url.path hasSuffix:@"/avatars/default.png"] || [url.path hasPrefix:@"/revine/avatar"]) {
            png = [RVAssets defaultAvatarPNG];
        }
        if (png) {
            RVVineResponse *response = [[RVVineResponse alloc] init];
            response.status = 200;
            response.contentType = @"image/png";
            response.body = png;
            return response;
        }
        if ([url.path hasPrefix:@"/upload"]) return RVReadOnly();
        return RVFailure(404, @"");
    }
    if ([host isEqualToString:@"vine.co"] || [host isEqualToString:@"www.vine.co"]) {
        if ([url.path hasPrefix:@"/explore"]) return RVExplorePage();
        return RVSimplePage(L(@"PageUnavailable"));
    }
    // dead analytics and status services
    if ([url.path hasSuffix:@"status.json"]) return RVJSONResponse(200, @{});
    return RVFailure(404, @"");
}

@end
