#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate, UIWebViewDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) UIWebView *web;
@property (assign, nonatomic) BOOL webReady;

// Hold (interrupteur silencieux)
@property (assign, nonatomic) int curHold;    // -1 inconnu, 0 libre, 1 verrouille
@property (assign, nonatomic) int pendHold;   // lecture en attente de confirmation
@property (assign, nonatomic) int holdMs;
@property (assign, nonatomic) BOOL muteBusy;  // une mesure est en cours
@property (assign, nonatomic) SystemSoundID silentID;
@property (strong, nonatomic) NSDate *playStart;

// Webradio
@property (strong, nonatomic) AVPlayer *radioPlayer;   // nil = arretee
@property (copy, nonatomic) NSString *radioURL;
@property (copy, nonatomic) NSString *radioName;
@property (strong, nonatomic) NSDate *radioStart;      // derniere fois ou le flux jouait (ou demarrage)
@property (assign, nonatomic) BOOL radioFailed;

// Bibliotheque
@property (strong, nonatomic) NSMutableDictionary *itemCache;   // "src|id" -> NSArray de MPMediaItem
@property (strong, nonatomic) NSMutableDictionary *rowCache;    // "src|id" -> lignes deja pretes pour le JS
@property (assign, nonatomic) NSUInteger queueCount;
@property (copy, nonatomic) NSString *lastArtPid;

// Divers
@property (strong, nonatomic) NSTimer *sleepTimer;
@property (assign, nonatomic) float savedBrightness;   // -1 = ecran pas assombri
@property (assign, nonatomic) BOOL pendingAlarm;

- (void)soundDone;
@end
