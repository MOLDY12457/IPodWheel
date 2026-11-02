// IPodWheelKiosk : fait d'IPodWheel l'ecran d'accueil de l'iPhone (iOS 6, dans SpringBoard).
//
//  - Active depuis l'app : Reglages > Ecran d'accueil (cle "kiosk" de com.tanguytar.ipodwheel.plist).
//    Desactive par defaut : installer le paquet ne change rien tant qu'on ne l'active pas.
//  - Kiosque actif : l'app se relance toute seule des que l'ecran d'accueil s'affiche
//    (demarrage, respring, plantage) et le bouton Home ne la quitte plus.
//  - SORTIE : Home + Volume+ + Volume-  -> kiosque coupe, retour a l'ecran des apps.
//    Aussi possible depuis l'app (Reglages > Ecran d'accueil > Non).
//  - Aucun fichier systeme n'est remplace : SpringBoard reste en place.
//
// Securites :
//  - mode sans echec MobileSubstrate (maintenir Volume+ pendant le respring) ;
//  - fichier d'arret : creer /var/mobile/Library/Preferences/ipodwheel.kiosk.disable (par SSH) ;
//  - si l'app est relancee plus de 8 fois en 60 s (boucle de plantages), le kiosque se coupe seul ;
//  - si la combinaison de touches n'a pas pu etre installee, 5 appuis sur Home en 3 s font sortir.

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define KIOSK_APP   @"com.tanguytar.ipodwheel"
#define KIOSK_PREFS @"/var/mobile/Library/Preferences/com.tanguytar.ipodwheel.plist"
#define KIOSK_KILL  @"/var/mobile/Library/Preferences/ipodwheel.kiosk.disable"

@interface UIApplication (IPodWheelKiosk)
- (BOOL)launchApplicationWithIdentifier:(id)identifier suspended:(BOOL)suspended;
@end

static BOOL gComboHooked = NO;
static BOOL gHomeDown = NO;
static NSTimeInterval gLastUp = 0, gLastDown = 0;
static NSMutableArray *gTaps = nil, *gLaunches = nil;
static id gPoller = nil;

static IMP oClicked = NULL, oDown = NULL, oUp = NULL, oVolUp = NULL, oVolDown = NULL, oDbl = NULL;

#pragma mark - Outils

static NSTimeInterval Now(void) { return [NSDate timeIntervalSinceReferenceDate]; }

// Lecture directe du fichier de reglages de l'app (iOS 6 : pas de cfprefsd)
static BOOL KioskOn(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:KIOSK_KILL]) return NO;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:KIOSK_PREFS];
    id v = [d objectForKey:@"kiosk"];
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}

static void KioskOff(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:([NSDictionary dictionaryWithContentsOfFile:KIOSK_PREFS] ?: [NSDictionary dictionary])];
    [d setObject:@"0" forKey:@"kiosk"];
    [d writeToFile:KIOSK_PREFS atomically:YES];
}

static id Shared(NSString *cls, NSString *sel) {
    Class c = NSClassFromString(cls);
    SEL s = NSSelectorFromString(sel);
    return (c && [c respondsToSelector:s]) ? [c performSelector:s] : nil;
}

static BOOL AskBool(id o, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!o || ![o respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(o, s);
}

static id FrontApp(void) {
    UIApplication *a = [UIApplication sharedApplication];
    SEL s = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    return [a respondsToSelector:s] ? [a performSelector:s] : nil;
}

static NSString *AppId(id app) {
    if (!app) return nil;
    SEL s1 = NSSelectorFromString(@"displayIdentifier"), s2 = NSSelectorFromString(@"bundleIdentifier");
    if ([app respondsToSelector:s1]) return [app performSelector:s1];
    if ([app respondsToSelector:s2]) return [app performSelector:s2];
    return nil;
}

static BOOL IPodIsFront(void) { return [AppId(FrontApp()) isEqualToString:KIOSK_APP]; }

static BOOL IsLocked(void) {
    id away = Shared(@"SBAwayController", @"sharedAwayController");   // iOS 6
    if (away) return AskBool(away, @"isLocked");
    return AskBool([UIApplication sharedApplication], @"isLocked");
}

static void Buzz(void) { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate); }

static void ExitKiosk(void) {
    KioskOff();
    Buzz();
    id ui = Shared(@"SBUIController", @"sharedInstance");
    SEL s = NSSelectorFromString(@"clickedMenuButton");
    if (ui && [ui respondsToSelector:s]) [ui performSelector:s];   // kiosque coupe -> Home normal = ecran des apps
}

#pragma mark - Hooks

// Bouton Home : en kiosque, avec l'iPod au premier plan, il ne fait rien
static BOOL hkClicked(id self, SEL _cmd) {
    @try {
        if (IPodIsFront() && KioskOn()) {
            if (!gComboHooked) {        // secours : 5 appuis en 3 s
                NSTimeInterval n = Now();
                [gTaps addObject:[NSNumber numberWithDouble:n]];
                while ([gTaps count] && n - [[gTaps objectAtIndex:0] doubleValue] > 3.0) [gTaps removeObjectAtIndex:0];
                if ([gTaps count] >= 5) { [gTaps removeAllObjects]; ExitKiosk(); }
            }
            return YES;
        }
    } @catch (NSException *e) {}
    return oClicked ? ((BOOL (*)(id, SEL))oClicked)(self, _cmd) : NO;
}

// Double appui Home (barre multitache) : bloque en kiosque
static void hkDouble(id self, SEL _cmd) {
    @try { if (IPodIsFront() && KioskOn()) return; } @catch (NSException *e) {}
    if (oDbl) ((void (*)(id, SEL))oDbl)(self, _cmd);
}

static void CheckCombo(void) {
    if (!gHomeDown) return;
    NSTimeInterval n = Now();
    if (n - gLastUp < 2.0 && n - gLastDown < 2.0 && KioskOn()) {
        gLastUp = gLastDown = 0;
        ExitKiosk();
    }
}

static void hkDown(id self, SEL _cmd, void *ev) {
    gHomeDown = YES;
    @try { CheckCombo(); } @catch (NSException *e) {}
    if (oDown) ((void (*)(id, SEL, void *))oDown)(self, _cmd, ev);
}
static void hkUp(id self, SEL _cmd, void *ev) {
    gHomeDown = NO;
    if (oUp) ((void (*)(id, SEL, void *))oUp)(self, _cmd, ev);
}
static void hkVolUp(id self, SEL _cmd) {
    gLastUp = Now();
    @try { CheckCombo(); } @catch (NSException *e) {}
    if (oVolUp) ((void (*)(id, SEL))oVolUp)(self, _cmd);
}
static void hkVolDown(id self, SEL _cmd) {
    gLastDown = Now();
    @try { CheckCombo(); } @catch (NSException *e) {}
    if (oVolDown) ((void (*)(id, SEL))oVolDown)(self, _cmd);
}

static BOOL HasMethod(Class c, SEL s) { return c && class_getInstanceMethod(c, s) != NULL; }

static void Swap(Class c, SEL s, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, imp);
}

#pragma mark - Relance automatique

@interface IPodWheelKioskPoller : NSObject
- (void)tick;
@end

@implementation IPodWheelKioskPoller
- (void)tick {
    @try {
        if (FrontApp()) return;                     // une appli est au premier plan : rien a faire
        if (!KioskOn()) return;
        if (IsLocked()) return;                     // ecran verrouille : on attend
        if (AskBool(Shared(@"SBTelephonyManager", @"sharedTelephonyManager"), @"inCall")) return;

        NSTimeInterval n = Now();
        [gLaunches addObject:[NSNumber numberWithDouble:n]];
        while ([gLaunches count] && n - [[gLaunches objectAtIndex:0] doubleValue] > 60.0) [gLaunches removeObjectAtIndex:0];
        if ([gLaunches count] > 8) {                // boucle de plantages : on coupe le kiosque
            [gLaunches removeAllObjects];
            KioskOff();
            Buzz();
            return;
        }
        UIApplication *a = [UIApplication sharedApplication];
        if ([a respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)])
            [a launchApplicationWithIdentifier:KIOSK_APP suspended:NO];
    } @catch (NSException *e) {}
}
@end

#pragma mark - Initialisation

__attribute__((constructor)) static void IPodWheelKioskInit(void) {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return;
        if ([[NSFileManager defaultManager] fileExistsAtPath:KIOSK_KILL]) return;

        gTaps = [NSMutableArray array];
        gLaunches = [NSMutableArray array];

        Class ui = NSClassFromString(@"SBUIController");
        Class sb = NSClassFromString(@"SpringBoard");
        Class vc = NSClassFromString(@"VolumeControl");
        if (!HasMethod(vc, NSSelectorFromString(@"increaseVolume"))) vc = NSClassFromString(@"SBVolumeControl");

        // 1) bouton Home
        SEL sClick = NSSelectorFromString(@"clickedMenuButton");
        if (HasMethod(ui, sClick)) Swap(ui, sClick, (IMP)hkClicked, &oClicked);

        // 2) double appui Home (nom variable selon la version)
        SEL sD1 = NSSelectorFromString(@"handleMenuDoubleTap"), sD2 = NSSelectorFromString(@"_handleMenuDoubleTap");
        if (HasMethod(ui, sD1)) Swap(ui, sD1, (IMP)hkDouble, &oDbl);
        else if (HasMethod(ui, sD2)) Swap(ui, sD2, (IMP)hkDouble, &oDbl);

        // 3) combinaison Home + Vol+ + Vol- : seulement si les 4 methodes existent
        SEL sDn = NSSelectorFromString(@"menuButtonDown:"), sUp = NSSelectorFromString(@"menuButtonUp:");
        SEL sVu = NSSelectorFromString(@"increaseVolume"),  sVd = NSSelectorFromString(@"decreaseVolume");
        if (HasMethod(sb, sDn) && HasMethod(sb, sUp) && HasMethod(vc, sVu) && HasMethod(vc, sVd)) {
            Swap(sb, sDn, (IMP)hkDown, &oDown);
            Swap(sb, sUp, (IMP)hkUp, &oUp);
            Swap(vc, sVu, (IMP)hkVolUp, &oVolUp);
            Swap(vc, sVd, (IMP)hkVolDown, &oVolDown);
            gComboHooked = YES;
        }
        NSLog(@"IPodWheelKiosk: home=%d combo=%d double=%d", oClicked != NULL, gComboHooked, oDbl != NULL);

        // 4) surveillance toutes les 3 s, a partir de 12 s apres le demarrage de SpringBoard
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12LL * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            gPoller = [[IPodWheelKioskPoller alloc] init];
            [NSTimer scheduledTimerWithTimeInterval:3.0 target:gPoller selector:@selector(tick) userInfo:nil repeats:YES];
        });
    }
}
