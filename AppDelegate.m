#import "AppDelegate.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AudioToolbox/AudioToolbox.h>

#pragma mark - Outils

// NaN / infini font planter NSJSONSerialization : on les remplace par 0
static NSNumber *Num(double v) {
    return [NSNumber numberWithDouble:(isnan(v) || isinf(v)) ? 0.0 : v];
}

static NSString *Str(id v) {
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : @"";
}

static NSNumber *PID(NSString *s) {
    return [NSNumber numberWithUnsignedLongLong:strtoull([Str(s) UTF8String], NULL, 10)];
}

// iOS 6 n'a pas base64EncodedStringWithOptions: (iOS 7)
static NSString *Base64(NSData *data) {
    static const char T[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *b = (const unsigned char *)[data bytes];
    NSUInteger n = [data length];
    NSMutableData *out = [NSMutableData dataWithLength:((n + 2) / 3) * 4];
    char *o = (char *)[out mutableBytes];
    NSUInteger j = 0;
    for (NSUInteger i = 0; i < n; i += 3) {
        unsigned v = (unsigned)b[i] << 16;
        if (i + 1 < n) v |= (unsigned)b[i + 1] << 8;
        if (i + 2 < n) v |= (unsigned)b[i + 2];
        o[j++] = T[(v >> 18) & 63];
        o[j++] = T[(v >> 12) & 63];
        o[j++] = (i + 1 < n) ? T[(v >> 6) & 63] : '=';
        o[j++] = (i + 2 < n) ? T[v & 63] : '=';
    }
    return [[NSString alloc] initWithData:out encoding:NSASCIIStringEncoding];
}

static void MuteDone(SystemSoundID sid, void *ctx) {
    [(__bridge AppDelegate *)ctx soundDone];
}

// Reglages partages avec le JS (et lus par le tweak "ecran d'accueil" : cle kiosk)
static NSArray *PrefKeys(void) {
    return [NSArray arrayWithObjects:@"theme", @"clicker", @"backlight", @"hidden", @"kiosk", @"diag",
                                     @"brick", @"alarmOn", @"alarmH", @"alarmM", nil];
}

#define MAX_ROWS 4000

@implementation AppDelegate

#pragma mark - Lancement

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    [app setStatusBarHidden:YES withAnimation:UIStatusBarAnimationNone];
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    self.itemCache = [NSMutableDictionary dictionary];
    self.rowCache = [NSMutableDictionary dictionary];
    self.savedBrightness = -1;

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    UIWebView *web = [[UIWebView alloc] initWithFrame:self.window.bounds];
    web.delegate = self;
    web.scrollView.scrollEnabled = NO;
    web.scrollView.bounces = NO;
    web.scrollView.delaysContentTouches = NO;          // touches transmises sans delai
    web.dataDetectorTypes = UIDataDetectorTypeNone;
    web.backgroundColor = [UIColor blackColor];
    web.opaque = YES;
    self.web = web;

    NSString *path = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    // NSClassFromString : evite un symbole que le SDK 9.3 place dans le mauvais framework
    [web loadRequest:[NSClassFromString(@"NSURLRequest") requestWithURL:[NSURL fileURLWithPath:path]]];

    UIViewController *vc = [[UIViewController alloc] init];
    vc.wantsFullScreenLayout = YES;
    vc.view = web;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    self.curHold = -1;
    self.pendHold = -1;
    [self startMuteCheck];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    // Batterie reelle
    [nc addObserver:self selector:@selector(pollBattery) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(pollBattery) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(pollBattery) userInfo:nil repeats:YES];

    // Lecture : le natif previent le JS lui-meme (plus besoin d'interroger chaque seconde)
    MPMusicPlayerController *pl = [MPMusicPlayerController iPodMusicPlayer];
    [pl beginGeneratingPlaybackNotifications];
    [nc addObserver:self selector:@selector(nowPlayingChanged) name:MPMusicPlayerControllerNowPlayingItemDidChangeNotification object:pl];
    [nc addObserver:self selector:@selector(npSoon) name:MPMusicPlayerControllerPlaybackStateDidChangeNotification object:pl];
    [nc addObserver:self selector:@selector(npSoon) name:MPMusicPlayerControllerVolumeDidChangeNotification object:pl];

    // Bibliotheque modifiee (synchro) : on vide les caches
    [[MPMediaLibrary defaultMediaLibrary] beginGeneratingLibraryChangeNotifications];
    [nc addObserver:self selector:@selector(clearCaches) name:MPMediaLibraryDidChangeNotification object:nil];

    // Appel telephonique pendant la radio : on reprend apres
    [nc addObserver:self selector:@selector(audioInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];

    // Telecommande des ecouteurs
    [app beginReceivingRemoteControlEvents];

    if ([opts objectForKey:UIApplicationLaunchOptionsLocalNotificationKey]) self.pendingAlarm = YES;
    [self scheduleAlarm];
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)app {
    [self setDim:NO];   // ne jamais laisser l'ecran de l'iPhone assombri en quittant
}

- (void)applicationDidBecomeActive:(UIApplication *)app {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [[NSUserDefaults standardUserDefaults] synchronize];   // relit les reglages (le tweak a pu changer "kiosk")
    [self pollBattery];
    if (self.silentID) [self muteCheck];
    if (self.webReady) {
        [self sendPrefs];
        [self deliver:@"window.wake&&window.wake()"];
        [self sendNPArt:NO];
    }
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)app {
    [self clearCaches];
}

- (void)application:(UIApplication *)app didReceiveLocalNotification:(UILocalNotification *)n {
    if (![n.userInfo objectForKey:@"ipodAlarm"]) return;
    if (self.webReady) [self startAlarm]; else self.pendingAlarm = YES;
}

- (void)webViewDidFinishLoad:(UIWebView *)w {
    self.webReady = YES;
    [self sendPrefs];
    [self pollBattery];
    if (self.curHold >= 0) [self pushHold];
    [self sendNPArt:YES];
    if (self.pendingAlarm) [self startAlarm];
}

#pragma mark - Aide JS

- (void)deliver:(NSString *)code {
    if (!self.web || !code) return;
    [self.web stringByEvaluatingJavaScriptFromString:code];
}

- (void)sendCall:(NSString *)fn obj:(id)obj {
    NSData *d = [NSClassFromString(@"NSJSONSerialization") dataWithJSONObject:obj options:0 error:NULL];
    NSString *s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"null";
    NSString *code = [NSString stringWithFormat:@"window.%@&&window.%@(%@)", fn, fn, s];
    [self performSelector:@selector(deliver:) withObject:code afterDelay:0];
}

- (void)toast:(NSString *)m {
    [self sendCall:@"onToast" obj:[NSDictionary dictionaryWithObject:(m ? m : @"") forKey:@"m"]];
}

- (void)sendPrefs {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    for (NSString *k in PrefKeys()) {
        id v = [d objectForKey:k];
        if ([v isKindOfClass:[NSString class]]) [o setObject:v forKey:k];
        else if ([v respondsToSelector:@selector(stringValue)]) [o setObject:[v stringValue] forKey:k];
    }
    // ancienne cle du theme (v0.0.3) deja au bon nom : "theme"
    [self sendCall:@"loadPrefs" obj:o];
}

#pragma mark - Batterie

- (void)pollBattery {
    UIDevice *d = [UIDevice currentDevice];
    float l = d.batteryLevel;                         // -1 si inconnu
    int pct = (l < 0) ? -1 : (int)(l * 100 + 0.5f);
    [self deliver:[NSString stringWithFormat:@"window.setBattery&&window.setBattery(%d,%d)",
                   pct, (int)d.batteryState]];         // 2 = en charge, 3 = pleine
}

#pragma mark - Interrupteur silencieux -> Hold

// Principe : on joue un son silencieux de 0,4 s. Quand l'interrupteur est sur
// silencieux, iOS termine la lecture tout de suite ; sinon elle dure 0,4 s.
- (void)startMuteCheck {
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"silence" withExtension:@"wav"];
    SystemSoundID sid = 0;
    if (!url || AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &sid) != 0) return;
    self.silentID = sid;
    AudioServicesAddSystemSoundCompletion(sid, NULL, NULL, MuteDone, (__bridge void *)self);
    [self muteCheck];
}

- (void)muteCheck {
    // pendant la radio la session audio change : on garde le dernier etat du Hold
    if (self.radioPlayer) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(muteCheck) object:nil];
        [self performSelector:@selector(muteCheck) withObject:nil afterDelay:1.0];
        return;
    }
    if (self.muteBusy) return;
    self.muteBusy = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(muteCheck) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(muteWatchdog) object:nil];
    self.playStart = [NSDate date];
    AudioServicesPlaySystemSound(self.silentID);
    [self performSelector:@selector(muteWatchdog) withObject:nil afterDelay:1.5];
}

// Si iOS n'a jamais rappele (son interrompu...), on relance la mesure.
- (void)muteWatchdog {
    self.muteBusy = NO;
    [self performSelector:@selector(muteCheck) withObject:nil afterDelay:0.5];
}

- (void)soundDone {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(muteWatchdog) object:nil];
    self.muteBusy = NO;
    double el = -[self.playStart timeIntervalSinceNow];
    int reading = (el < 0.15) ? 1 : 0;     // fini tout de suite = silencieux
    self.holdMs = (int)(el * 1000);
    if (self.curHold < 0) {                              // premiere mesure : on applique de suite
        self.curHold = reading; self.pendHold = -1; [self pushHold];
    } else if (reading != self.curHold) {                // changement : confirme par 2 mesures
        if (self.pendHold == reading) { self.curHold = reading; self.pendHold = -1; [self pushHold]; }
        else self.pendHold = reading;
    } else {
        self.pendHold = -1;
    }
    // en arriere-plan inutile de mesurer : on espace
    BOOL active = ([UIApplication sharedApplication].applicationState == UIApplicationStateActive);
    [self performSelector:@selector(muteCheck) withObject:nil afterDelay:(active ? 0.6 : 5.0)];
}

- (void)pushHold {
    [self deliver:[NSString stringWithFormat:@"window.setHold&&window.setHold(%d,%d)", self.curHold, self.holdMs]];
}

#pragma mark - Webradio

- (void)pushRadio {
    NSDictionary *ro = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInt:[self radioState]], @"st", self.radioName ? self.radioName : @"", @"n", nil];
    [self sendCall:@"onRadio" obj:ro];
}

- (void)radioStop {
    if (!self.radioPlayer) return;
    [self.radioPlayer pause];
    self.radioPlayer = nil;
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];
    AVAudioSession *as = [AVAudioSession sharedInstance];
    [as setActive:NO error:NULL];
    [as setCategory:AVAudioSessionCategorySoloAmbient error:NULL];   // retour a l'etat normal (Hold)
    [self performSelector:@selector(muteCheck) withObject:nil afterDelay:0.8];
}

- (void)radioStartURL:(NSString *)u name:(NSString *)n {
    NSURL *url = ([u length] ? [NSURL URLWithString:u] : nil);
    if (!url) return;
    [self radioStop];
    self.radioURL = u;
    self.radioName = n;
    self.radioFailed = NO;
    self.radioStart = [NSDate date];
    [[MPMusicPlayerController iPodMusicPlayer] pause];                // une seule source a la fois
    AVAudioSession *as = [AVAudioSession sharedInstance];
    [as setCategory:AVAudioSessionCategoryPlayback error:NULL];        // joue meme si l'interrupteur est sur silencieux
    [as setActive:YES error:NULL];
    self.radioPlayer = [AVPlayer playerWithURL:url];
    [self.radioPlayer play];
    // nom de la station sur l'ecran verrouille
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:[NSDictionary dictionaryWithObjectsAndKeys:
        (n ? n : @"Radio"), MPMediaItemPropertyTitle, @"Webradio", MPMediaItemPropertyArtist, nil]];
}

// 0 arretee, 1 connexion / mise en memoire, 2 en direct, 3 erreur
- (int)radioState {
    if (!self.radioPlayer) return self.radioFailed ? 3 : 0;
    AVPlayerItem *it = self.radioPlayer.currentItem;
    if (self.radioPlayer.status == AVPlayerStatusFailed || (it && it.status == AVPlayerItemStatusFailed)) {
        [self radioStop]; self.radioFailed = YES; return 3;
    }
    if (it && it.status == AVPlayerItemStatusReadyToPlay && self.radioPlayer.rate > 0.0f && !it.playbackBufferEmpty) {
        self.radioStart = [NSDate date];   // le flux joue : on repart de zero pour le delai
        return 2;
    }
    if (it && it.playbackLikelyToKeepUp && self.radioPlayer.rate == 0.0f) [self.radioPlayer play];   // reprise apres coupure reseau
    if (-[self.radioStart timeIntervalSinceNow] > 25.0) { [self radioStop]; self.radioFailed = YES; return 3; }
    return 1;
}

- (void)audioInterrupted:(NSNotification *)n {
    NSUInteger type = [[n.userInfo objectForKey:AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeEnded && self.radioPlayer) {
        [[AVAudioSession sharedInstance] setActive:YES error:NULL];
        self.radioStart = [NSDate date];
        [self.radioPlayer play];
    }
}

#pragma mark - Telecommande (ecouteurs)

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)remoteControlReceivedWithEvent:(UIEvent *)e {
    if (e.type != UIEventTypeRemoteControl) return;
    MPMusicPlayerController *pl = [MPMusicPlayerController iPodMusicPlayer];
    switch (e.subtype) {
        case UIEventSubtypeRemoteControlTogglePlayPause: [self handleCommand:@"playpause"]; break;
        case UIEventSubtypeRemoteControlPlay:  if (self.radioPlayer) [self.radioPlayer play]; else [pl play]; break;
        case UIEventSubtypeRemoteControlPause: [self handleCommand:@"pause"]; break;
        case UIEventSubtypeRemoteControlNextTrack: [pl skipToNextItem]; break;
        case UIEventSubtypeRemoteControlPreviousTrack: [pl skipToPreviousItem]; break;
        default: break;
    }
    [self pushRadio];
}

#pragma mark - Lecture en cours

- (void)nowPlayingChanged {
    // les compteurs d'ecoute changent : Top 25 / Ecoutes recemment a recalculer
    for (NSString *k in [NSArray arrayWithObjects:@"top|", @"recent|", nil]) {
        [self.itemCache removeObjectForKey:k];
        [self.rowCache removeObjectForKey:k];
    }
    [self npSoon];
}

- (void)npSoon {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sendNP) object:nil];
    [self performSelector:@selector(sendNP) withObject:nil afterDelay:0.05];
}

- (void)sendNP { [self sendNPArt:NO]; }

- (NSString *)artFor:(MPMediaItem *)it {
    MPMediaItemArtwork *aw = it ? [it valueForProperty:MPMediaItemPropertyArtwork] : nil;
    UIImage *img = aw ? [aw imageWithSize:CGSizeMake(180, 180)] : nil;
    if (!img) return @"";
    // reduit a 180 x 180 (90 points en Retina) pour un transfert leger
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(180, 180), YES, 1.0);
    [img drawInRect:CGRectMake(0, 0, 180, 180)];
    UIImage *small = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *jpg = UIImageJPEGRepresentation(small ? small : img, 0.72f);
    return jpg ? Base64(jpg) : @"";
}

- (void)sendNPArt:(BOOL)force {
    if (!self.webReady) return;
    MPMusicPlayerController *pl = [MPMusicPlayerController iPodMusicPlayer];
    MPMediaItem *it = pl.nowPlayingItem;
    NSString *t  = it ? [it valueForProperty:MPMediaItemPropertyTitle] : nil;
    NSString *a  = it ? [it valueForProperty:MPMediaItemPropertyArtist] : nil;
    NSString *al = it ? [it valueForProperty:MPMediaItemPropertyAlbumTitle] : nil;
    NSNumber *dur = it ? [it valueForProperty:MPMediaItemPropertyPlaybackDuration] : nil;
    MPMusicPlaybackState ps = pl.playbackState;
    BOOL playing = (ps == MPMusicPlaybackStatePlaying || ps == MPMusicPlaybackStateSeekingForward || ps == MPMusicPlaybackStateSeekingBackward);

    NSUInteger idx = NSNotFound;
    if ([pl respondsToSelector:@selector(indexOfNowPlayingItem)]) idx = [pl indexOfNowPlayingItem];
    int ix = (it && idx != NSNotFound) ? (int)idx + 1 : 0;
    int cnt = (ix > 0 && ix <= (int)self.queueCount) ? (int)self.queueCount : 0;

    NSString *sh = (pl.shuffleMode == MPMusicShuffleModeSongs) ? @"songs" : (pl.shuffleMode == MPMusicShuffleModeAlbums) ? @"albums" : @"off";
    NSString *rp = (pl.repeatMode == MPMusicRepeatModeOne) ? @"one" : (pl.repeatMode == MPMusicRepeatModeAll) ? @"all" : @"off";

    NSMutableDictionary *o = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        t ? t : @"", @"t", a ? a : @"", @"a", al ? al : @"", @"al",
        Num(pl.currentPlaybackTime), @"pos",
        dur ? Num([dur doubleValue]) : [NSNumber numberWithInt:0], @"dur",
        [NSNumber numberWithInt:playing ? 1 : 0], @"st",
        Num(pl.volume), @"vol",
        [NSNumber numberWithInt:ix], @"idx", [NSNumber numberWithInt:cnt], @"cnt",
        sh, @"sh", rp, @"rp", nil];

    // la pochette ne part que quand le morceau change (ou a la demande)
    NSString *pid = it ? [[it valueForProperty:MPMediaItemPropertyPersistentID] stringValue] : @"";
    if (force || !self.lastArtPid || ![pid isEqualToString:self.lastArtPid]) {
        self.lastArtPid = pid;
        [o setObject:[self artFor:it] forKey:@"art"];
    }
    [self sendCall:@"onNP" obj:o];
}

#pragma mark - Bibliotheque musicale (avec cache)

- (void)clearCaches {
    [self.itemCache removeAllObjects];
    [self.rowCache removeAllObjects];
}

- (void)forgetSrc:(NSString *)src {
    for (NSString *k in [[self.itemCache allKeys] copy]) if ([k hasPrefix:[src stringByAppendingString:@"|"]]) [self.itemCache removeObjectForKey:k];
    for (NSString *k in [[self.rowCache allKeys] copy]) if ([k hasPrefix:[src stringByAppendingString:@"|"]]) [self.rowCache removeObjectForKey:k];
}

- (NSArray *)itemsFiltered:(MPMediaQuery *)q prop:(NSString *)prop pid:(NSString *)pid collection:(BOOL)coll {
    if ([pid length] == 0) return [NSArray array];
    [q addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:PID(pid) forProperty:prop]];
    if (!coll) return [q items];
    NSArray *cols = [q collections];
    return [cols count] ? [[cols objectAtIndex:0] items] : [NSArray array];
}

- (NSArray *)sortedSongsBy:(NSString *)prop {
    NSMutableArray *r = [NSMutableArray array];
    for (MPMediaItem *it in [[MPMediaQuery songsQuery] items]) {
        id v = [it valueForProperty:prop];
        if ([prop isEqualToString:MPMediaItemPropertyPlayCount] ? ([v unsignedIntegerValue] > 0) : (v != nil)) [r addObject:it];
    }
    [r sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [[b valueForProperty:prop] compare:[a valueForProperty:prop]];   // ordre decroissant
    }];
    return [r count] > 25 ? [r subarrayWithRange:NSMakeRange(0, 25)] : r;
}

- (NSArray *)queryItemsForSrc:(NSString *)src pid:(NSString *)pid {
    if ([src isEqualToString:@"songs"])      return [[MPMediaQuery songsQuery] items];
    if ([src isEqualToString:@"podcasts"])   return [[MPMediaQuery podcastsQuery] items];
    if ([src isEqualToString:@"audiobooks"]) return [[MPMediaQuery audiobooksQuery] items];
    if ([src isEqualToString:@"top"])        return [self sortedSongsBy:MPMediaItemPropertyPlayCount];
    if ([src isEqualToString:@"recent"])     return [self sortedSongsBy:MPMediaItemPropertyLastPlayedDate];
    if ([src isEqualToString:@"videos"]) {
        MPMediaQuery *vq = [[MPMediaQuery alloc] init];
        [vq addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:[NSNumber numberWithInt:MPMediaTypeAnyVideo]
                                                               forProperty:MPMediaItemPropertyMediaType]];
        return [vq items];
    }
    if ([src isEqualToString:@"otg"]) {
        NSMutableArray *r = [NSMutableArray array];
        for (id s in [[NSUserDefaults standardUserDefaults] arrayForKey:@"otg"]) {
            MPMediaQuery *q = [[MPMediaQuery alloc] init];
            [q addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:PID(Str(s)) forProperty:MPMediaItemPropertyPersistentID]];
            MPMediaItem *it = [[q items] lastObject];
            if (it) [r addObject:it];
        }
        return r;
    }
    if ([src isEqualToString:@"songs-album"])    return [self itemsFiltered:[MPMediaQuery albumsQuery] prop:MPMediaItemPropertyAlbumPersistentID pid:pid collection:YES];
    if ([src isEqualToString:@"songs-playlist"]) return [self itemsFiltered:[MPMediaQuery playlistsQuery] prop:MPMediaPlaylistPropertyPersistentID pid:pid collection:YES];
    if ([src isEqualToString:@"songs-artist"])   return [self itemsFiltered:[MPMediaQuery songsQuery] prop:MPMediaItemPropertyArtistPersistentID pid:pid collection:NO];
    if ([src isEqualToString:@"songs-genre"])    return [self itemsFiltered:[MPMediaQuery songsQuery] prop:MPMediaItemPropertyGenrePersistentID pid:pid collection:NO];
    if ([src isEqualToString:@"songs-composer"]) return [self itemsFiltered:[MPMediaQuery songsQuery] prop:MPMediaItemPropertyComposerPersistentID pid:pid collection:NO];
    return [NSArray array];
}

- (NSArray *)itemsForSrc:(NSString *)src pid:(NSString *)pid {
    NSString *key = [NSString stringWithFormat:@"%@|%@", Str(src), Str(pid)];
    NSArray *c = [self.itemCache objectForKey:key];
    if (c) return c;
    c = [self queryItemsForSrc:Str(src) pid:Str(pid)];
    if (!c) c = [NSArray array];
    [self.itemCache setObject:c forKey:key];
    return c;
}

// Lignes "groupees" (une ligne = un artiste, un album...) : [titre, sous-titre, id]
- (NSArray *)groupRows:(MPMediaQuery *)q kind:(NSString *)kind {
    NSMutableArray *rows = [NSMutableArray array];
    for (MPMediaItemCollection *c in [q collections]) {
        MPMediaItem *rep = [c representativeItem];
        NSString *t = nil, *s = nil;
        NSNumber *pid = nil;
        if ([kind isEqualToString:@"playlist"]) {
            t = [c valueForProperty:MPMediaPlaylistPropertyName];
            pid = [c valueForProperty:MPMediaPlaylistPropertyPersistentID];
            s = [NSString stringWithFormat:@"%lu", (unsigned long)[c count]];
        } else if ([kind isEqualToString:@"artist"]) {
            t = [rep valueForProperty:MPMediaItemPropertyArtist];
            pid = [rep valueForProperty:MPMediaItemPropertyArtistPersistentID];
        } else if ([kind isEqualToString:@"album"]) {
            t = [rep valueForProperty:MPMediaItemPropertyAlbumTitle];
            s = [rep valueForProperty:MPMediaItemPropertyArtist];
            pid = [rep valueForProperty:MPMediaItemPropertyAlbumPersistentID];
        } else if ([kind isEqualToString:@"genre"]) {
            t = [rep valueForProperty:MPMediaItemPropertyGenre];
            pid = [rep valueForProperty:MPMediaItemPropertyGenrePersistentID];
        } else {
            t = [rep valueForProperty:MPMediaItemPropertyComposer];
            pid = [rep valueForProperty:MPMediaItemPropertyComposerPersistentID];
        }
        [rows addObject:[NSArray arrayWithObjects:(t ? t : @"Inconnu"), (s ? s : @""), (pid ? [pid stringValue] : @"0"), nil]];
        if ([rows count] >= MAX_ROWS) break;
    }
    return rows;
}

- (NSArray *)buildRowsForSrc:(NSString *)src pid:(NSString *)pid {
    if ([src isEqualToString:@"artists"])      return [self groupRows:[MPMediaQuery artistsQuery] kind:@"artist"];
    if ([src isEqualToString:@"albums"])       return [self groupRows:[MPMediaQuery albumsQuery] kind:@"album"];
    if ([src isEqualToString:@"genres"])       return [self groupRows:[MPMediaQuery genresQuery] kind:@"genre"];
    if ([src isEqualToString:@"composers"])    return [self groupRows:[MPMediaQuery composersQuery] kind:@"composer"];
    if ([src isEqualToString:@"compilations"]) return [self groupRows:[MPMediaQuery compilationsQuery] kind:@"album"];
    if ([src isEqualToString:@"playlists"])    return [self groupRows:[MPMediaQuery playlistsQuery] kind:@"playlist"];
    if ([src isEqualToString:@"albums-artist"]) {
        if ([pid length] == 0) return [NSArray array];
        MPMediaQuery *q = [MPMediaQuery albumsQuery];
        [q addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:PID(pid) forProperty:MPMediaItemPropertyArtistPersistentID]];
        return [self groupRows:q kind:@"album"];
    }
    NSArray *items = [self itemsForSrc:src pid:pid];
    BOOL pod = [src isEqualToString:@"podcasts"];
    NSUInteger n = MIN([items count], (NSUInteger)MAX_ROWS);
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        MPMediaItem *it = [items objectAtIndex:i];
        NSString *t = [it valueForProperty:MPMediaItemPropertyTitle];
        NSString *a = [it valueForProperty:(pod ? MPMediaItemPropertyPodcastTitle : MPMediaItemPropertyArtist)];
        [rows addObject:[NSArray arrayWithObjects:(t ? t : @"Sans titre"), (a ? a : @""), nil]];
    }
    return rows;
}

- (NSArray *)rowsForSrc:(NSString *)src pid:(NSString *)pid {
    NSString *key = [NSString stringWithFormat:@"%@|%@", Str(src), Str(pid)];
    NSArray *r = [self.rowCache objectForKey:key];
    if (r) return r;
    r = [self buildRowsForSrc:Str(src) pid:Str(pid)];
    if (!r) r = [NSArray array];
    [self.rowCache setObject:r forKey:key];
    return r;
}

- (void)playItems:(NSArray *)items at:(NSInteger)i shuffle:(BOOL)shuffle {
    if (![items count]) return;
    [self radioStop];
    MPMusicPlayerController *pl = [MPMusicPlayerController iPodMusicPlayer];
    [pl setQueueWithItemCollection:[MPMediaItemCollection collectionWithItems:items]];
    self.queueCount = [items count];
    if (shuffle) {
        pl.shuffleMode = MPMusicShuffleModeSongs;
        i = arc4random_uniform((u_int32_t)[items count]);   // vrai depart au hasard
    }
    if (i >= 0 && i < (NSInteger)[items count]) pl.nowPlayingItem = [items objectAtIndex:i];
    [pl play];
}

#pragma mark - Minuterie de veille, reveil, ecran

- (void)sleepFired {
    self.sleepTimer = nil;
    [[MPMusicPlayerController iPodMusicPlayer] pause];
    [self radioStop];
    [self sendCall:@"onSleepDone" obj:[NSDictionary dictionary]];
}

- (void)scheduleAlarm {
    UIApplication *app = [UIApplication sharedApplication];
    for (UILocalNotification *n in [app scheduledLocalNotifications])
        if ([n.userInfo objectForKey:@"ipodAlarm"]) [app cancelLocalNotification:n];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![[d stringForKey:@"alarmOn"] isEqualToString:@"1"]) return;
    NSString *hs = [d stringForKey:@"alarmH"], *ms = [d stringForKey:@"alarmM"];
    NSInteger h = hs ? [hs integerValue] : 7, m = ms ? [ms integerValue] : 0;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:(NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit) fromDate:[NSDate date]];
    [c setHour:h]; [c setMinute:m]; [c setSecond:0];
    NSDate *fire = [cal dateFromComponents:c];
    if ([fire timeIntervalSinceNow] <= 0) fire = [fire dateByAddingTimeInterval:86400];
    UILocalNotification *n = [[UILocalNotification alloc] init];
    n.fireDate = fire;
    n.timeZone = [NSTimeZone defaultTimeZone];
    n.repeatInterval = NSDayCalendarUnit;
    n.alertBody = @"Réveil iPod";
    n.alertAction = @"ouvrir l'iPod";
    n.soundName = UILocalNotificationDefaultSoundName;
    n.userInfo = [NSDictionary dictionaryWithObject:@"1" forKey:@"ipodAlarm"];
    [app scheduleLocalNotification:n];
}

- (void)startAlarm {
    self.pendingAlarm = NO;
    MPMusicPlayerController *pl = [MPMusicPlayerController iPodMusicPlayer];
    [self playItems:[self itemsForSrc:@"songs" pid:@""] at:0 shuffle:YES];
    if (pl.volume < 0.3f) pl.volume = 0.5f;
    [self setDim:NO];
    [self sendCall:@"onAlarm" obj:[NSDictionary dictionary]];
}

- (void)setDim:(BOOL)on {
    UIScreen *sc = [UIScreen mainScreen];
    if (on && self.savedBrightness < 0) { self.savedBrightness = sc.brightness; sc.brightness = 0.0f; }
    else if (!on && self.savedBrightness >= 0) { sc.brightness = self.savedBrightness; self.savedBrightness = -1; }
}

#pragma mark - Pont JS -> natif (ipod://flush puis window.__drain())

- (NSDictionary *)paramsOfQuery:(NSString *)q {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *kv in [q componentsSeparatedByString:@"&"]) {
        NSRange r = [kv rangeOfString:@"="];
        if (r.location == NSNotFound) continue;
        NSString *v = [[kv substringFromIndex:r.location + 1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        [d setObject:(v ? v : @"") forKey:[kv substringToIndex:r.location]];
    }
    return d;
}

// line = "commande?param=valeur&..."
- (void)handleCommand:(NSString *)line {
    NSRange qr = [line rangeOfString:@"?"];
    NSString *cmd = (qr.location == NSNotFound) ? line : [line substringToIndex:qr.location];
    NSString *qs  = (qr.location == NSNotFound) ? @"" : [line substringFromIndex:qr.location + 1];
    NSDictionary *p = [self paramsOfQuery:qs];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    MPMusicPlayerController *pl = [MPMusicPlayerController iPodMusicPlayer];

    if ([cmd isEqualToString:@"click"]) {
        AudioServicesPlaySystemSound(1104);

    } else if ([cmd isEqualToString:@"setpref"] || [cmd isEqualToString:@"settheme"]) {
        NSString *k = [cmd isEqualToString:@"settheme"] ? @"theme" : Str([p objectForKey:@"k"]);
        if ([PrefKeys() containsObject:k]) {
            [ud setObject:Str([p objectForKey:@"v"]) forKey:k];
            [ud synchronize];      // ecrit tout de suite (le tweak lit "kiosk" dans ce fichier)
            if ([k hasPrefix:@"alarm"]) [self scheduleAlarm];
        }

    } else if ([cmd isEqualToString:@"list"]) {
        NSString *src = Str([p objectForKey:@"src"]);
        NSMutableDictionary *o = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            src, @"src", [NSNumber numberWithInt:[[p objectForKey:@"rid"] intValue]], @"rid",
            [self rowsForSrc:src pid:Str([p objectForKey:@"id"])], @"items", nil];
        if ([src isEqualToString:@"playlists"])
            [o setObject:[NSNumber numberWithUnsignedInteger:[[ud arrayForKey:@"otg"] count]] forKey:@"otg"];
        [self sendCall:@"onList" obj:o];

    } else if ([cmd isEqualToString:@"play"]) {
        [self playItems:[self itemsForSrc:Str([p objectForKey:@"src"]) pid:Str([p objectForKey:@"id"])]
                     at:[[p objectForKey:@"i"] intValue] shuffle:NO];

    } else if ([cmd isEqualToString:@"shuffle"]) {
        NSString *src = Str([p objectForKey:@"src"]);
        [self playItems:[self itemsForSrc:([src length] ? src : @"songs") pid:Str([p objectForKey:@"id"])] at:0 shuffle:YES];

    } else if ([cmd isEqualToString:@"mode"]) {
        NSString *sh = [p objectForKey:@"sh"], *rp = [p objectForKey:@"rp"];
        if (sh) pl.shuffleMode = [sh isEqualToString:@"songs"] ? MPMusicShuffleModeSongs : [sh isEqualToString:@"albums"] ? MPMusicShuffleModeAlbums : MPMusicShuffleModeOff;
        if (rp) pl.repeatMode = [rp isEqualToString:@"one"] ? MPMusicRepeatModeOne : [rp isEqualToString:@"all"] ? MPMusicRepeatModeAll : MPMusicRepeatModeNone;
        [self npSoon];

    } else if ([cmd isEqualToString:@"playpause"]) {
        if (self.radioPlayer) { [self radioStop]; self.radioFailed = NO; [self pushRadio]; }
        else if (pl.playbackState == MPMusicPlaybackStatePlaying) [pl pause];
        else [pl play];
    } else if ([cmd isEqualToString:@"pause"]) {
        if (self.radioPlayer) { [self radioStop]; self.radioFailed = NO; [self pushRadio]; }
        [pl pause];
    } else if ([cmd isEqualToString:@"next"]) {
        [pl skipToNextItem];
    } else if ([cmd isEqualToString:@"prev"]) {
        [pl skipToPreviousItem];
    } else if ([cmd isEqualToString:@"seek"]) {
        pl.currentPlaybackTime = MAX(0.0, [[p objectForKey:@"t"] doubleValue]);
        [self npSoon];
    } else if ([cmd isEqualToString:@"seekfwd"]) {
        [pl beginSeekingForward];
    } else if ([cmd isEqualToString:@"seekbwd"]) {
        [pl beginSeekingBackward];
    } else if ([cmd isEqualToString:@"seekend"]) {
        [pl endSeeking];
        [self npSoon];

    } else if ([cmd isEqualToString:@"np"]) {
        [self sendNPArt:[[p objectForKey:@"art"] isEqualToString:@"1"]];

    } else if ([cmd isEqualToString:@"vol"]) {
        pl.volume = MAX(0.0f, MIN(1.0f, [[p objectForKey:@"v"] floatValue]));

    } else if ([cmd isEqualToString:@"bright"]) {
        if ([p objectForKey:@"v"]) [UIScreen mainScreen].brightness = MAX(0.05f, MIN(1.0f, [[p objectForKey:@"v"] floatValue]));
        [self sendCall:@"onBright" obj:[NSDictionary dictionaryWithObject:Num([UIScreen mainScreen].brightness) forKey:@"v"]];

    } else if ([cmd isEqualToString:@"dim"]) {
        [self setDim:[[p objectForKey:@"on"] isEqualToString:@"1"]];

    } else if ([cmd isEqualToString:@"idle"]) {
        [UIApplication sharedApplication].idleTimerDisabled = [[p objectForKey:@"off"] isEqualToString:@"1"];

    } else if ([cmd isEqualToString:@"radio"]) {
        [self radioStartURL:[p objectForKey:@"u"] name:[p objectForKey:@"n"]];
    } else if ([cmd isEqualToString:@"radiotoggle"]) {
        if (self.radioPlayer) { [self radioStop]; self.radioFailed = NO; }
        else if (self.radioURL) [self radioStartURL:self.radioURL name:self.radioName];
        [self pushRadio];
    } else if ([cmd isEqualToString:@"radiost"]) {
        [self pushRadio];

    } else if ([cmd isEqualToString:@"video"]) {
        NSArray *items = [self itemsForSrc:@"videos" pid:@""];
        int i = [[p objectForKey:@"i"] intValue];
        if (i >= 0 && i < (int)[items count]) {
            NSURL *url = [[items objectAtIndex:i] valueForProperty:MPMediaItemPropertyAssetURL];
            if (url) {
                [self radioStop];
                [pl pause];
                MPMoviePlayerViewController *mp = [[MPMoviePlayerViewController alloc] initWithContentURL:url];
                [self.window.rootViewController presentMoviePlayerViewControllerAnimated:mp];
            } else {
                [self toast:@"Vidéo protégée ou absente de l'iPhone"];
            }
        }

    } else if ([cmd isEqualToString:@"otgadd"]) {
        NSArray *items = [self itemsForSrc:Str([p objectForKey:@"src"]) pid:Str([p objectForKey:@"id"])];
        int i = [[p objectForKey:@"i"] intValue];
        if (i >= 0 && i < (int)[items count]) {
            MPMediaItem *it = [items objectAtIndex:i];
            NSMutableArray *ids = [NSMutableArray arrayWithArray:([ud arrayForKey:@"otg"] ? [ud arrayForKey:@"otg"] : [NSArray array])];
            [ids addObject:[[it valueForProperty:MPMediaItemPropertyPersistentID] stringValue]];
            [ud setObject:ids forKey:@"otg"];
            [ud synchronize];
            [self forgetSrc:@"otg"];
            NSString *t = [it valueForProperty:MPMediaItemPropertyTitle];
            [self toast:[NSString stringWithFormat:@"Ajouté à On-The-Go :\n%@", t ? t : @""]];
        }
    } else if ([cmd isEqualToString:@"otgclear"]) {
        [ud removeObjectForKey:@"otg"];
        [ud synchronize];
        [self forgetSrc:@"otg"];

    } else if ([cmd isEqualToString:@"sleep"]) {
        [self.sleepTimer invalidate];
        self.sleepTimer = nil;
        int m = [[p objectForKey:@"m"] intValue];
        if (m > 0) self.sleepTimer = [NSTimer scheduledTimerWithTimeInterval:m * 60.0 target:self selector:@selector(sleepFired) userInfo:nil repeats:NO];

    } else if ([cmd isEqualToString:@"alarm"]) {
        [self scheduleAlarm];
    } else if ([cmd isEqualToString:@"alarmtest"]) {
        [self startAlarm];

    } else if ([cmd isEqualToString:@"stats"]) {
        NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:@"/private/var" error:NULL];
        NSDictionary *o = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithUnsignedInteger:[[self itemsForSrc:@"songs" pid:@""] count]], @"songs",
            [NSNumber numberWithUnsignedInteger:[[[MPMediaQuery albumsQuery] collections] count]], @"albums",
            [NSNumber numberWithUnsignedInteger:[[[MPMediaQuery artistsQuery] collections] count]], @"artists",
            [NSNumber numberWithUnsignedInteger:[[self itemsForSrc:@"videos" pid:@""] count]], @"videos",
            Num([[fs objectForKey:NSFileSystemSize] doubleValue]), @"cap",
            Num([[fs objectForKey:NSFileSystemFreeSize] doubleValue]), @"free", nil];
        [self sendCall:@"onStats" obj:o];
    }
}

- (BOOL)webView:(UIWebView *)w shouldStartLoadWithRequest:(NSURLRequest *)r
                                          navigationType:(UIWebViewNavigationType)t {
    NSURL *u = r.URL;
    if (![u.scheme isEqualToString:@"ipod"]) return YES;

    if ([u.host isEqualToString:@"flush"]) {
        // le JS a mis des commandes en file d'attente : on les recupere toutes d'un coup
        NSString *all = [w stringByEvaluatingJavaScriptFromString:@"window.__drain&&window.__drain()"];
        for (NSString *line in [all componentsSeparatedByString:@"\n"]) {
            if ([line length] == 0) continue;
            @try { [self handleCommand:line]; }
            @catch (NSException *ex) { NSLog(@"IPodWheel: commande '%@' ignoree (%@)", line, ex); }
        }
        return NO;
    }
    // compat : commande directe ipod://commande?x=y
    NSString *direct = [[u absoluteString] substringFromIndex:[@"ipod://" length]];
    @try { [self handleCommand:direct]; } @catch (NSException *ex) { NSLog(@"IPodWheel: %@", ex); }
    return NO;
}

@end
