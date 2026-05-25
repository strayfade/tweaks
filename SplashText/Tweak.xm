#import <CoreText/CoreText.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <rootless.h>

static NSString *const kMCSplashPrefsID = @"com.strayfade.splashtext~prefs";
static BOOL mcsplashTriedRegisteringFont = NO;
static NSString *mcsplashRegisteredFontName = nil;
// Developer tuneables for the anchor when clock geometry is imperfect.
static CGFloat const kMCSplashStaticOffsetX = -70.0f;
static CGFloat const kMCSplashStaticOffsetY = 0.0f;

static BOOL mcsplashReadBool(NSString *key, BOOL fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kMCSplashPrefsID);
    if (!value) {
        return fallback;
    }
    BOOL result = fallback;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int n = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n)) {
            result = n != 0;
        }
    }
    CFRelease(value);
    return result;
}

static float mcsplashReadFloat(NSString *key, float fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kMCSplashPrefsID);
    if (!value) {
        return fallback;
    }
    float result = fallback;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberFloatType, &result);
    }
    CFRelease(value);
    return result;
}

static NSString *mcsplashReadString(NSString *key, NSString *fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kMCSplashPrefsID);
    if (!value) {
        return fallback;
    }
    NSString *result = fallback;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        NSString *candidate = [(__bridge NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (candidate.length > 0) {
            result = candidate;
        }
    }
    CFRelease(value);
    return result;
}

static NSArray<NSString *> *mcsplashDefaultSplashes(void) {
    return @[
        @"As seen on TV!",
        @"The End?",
        @"Should not be played while driving.",
        @"1% sugar!",
        @"Ph1lza had a good run!",
        @"Awesome!",
        @"100% pure!",
        @"May contain nuts!",
        @"All is full of love!",
        @"More polygons!",
        @"Limited edition!",
        @"Flashing letters!",
        @"Made by Notch!",
        @"It's here!",
        @"Put that cookie down!",
        @"Best in class!",
        @"It's finished!",
        @"Kind of dragon free!",
        @"Call you Mom!",
        @"Excitement!",
        @"More than 500 sold!",
        @"One of a kind!",
        @"Heaps of hits on YouTube!",
        @"Indev!",
        @"Spiders everywhere!",
        @"Check it out!",
        @"Holy cow, man!",
        @"It's a game!",
        @"Made in Sweden!",
        @"Uses LWJGL!",
        @"Reticulating splines!",
        @"Minecraft!",
        @"Yaaay!",
        @"Singleplayer!",
        @"Keyboard compatible!",
        @"Undocumented!",
        @"Ingots!",
        @"Exploding creepers!",
        @"That's no moon!",
        @"L33t!",
        @"Create!",
        @"Survive!",
        @"Dungeon!",
        @"Exclusive!",
        @"The bee's knees!",
        @"Down with O.P.P.!",
        @"Closed source!",
        @"Classy!",
        @"Wow!",
        @"Not on steam!",
        @"Oh man!",
        @"Awesome community!",
        @"Pixels!",
        @"Teetsuuuuoooo!",
        @"Kaaneeeedaaaa!",
        @"Now with difficulty!",
        @"Enhanced!",
        @"90% bug free!",
        @"Pretty!",
        @"12 herbs and spices!",
        @"Fat free!",
        @"Absolutely no memes!",
        @"Free dental!",
        @"Ask your doctor!",
        @"Minors welcome!",
        @"Cloud computing!",
        @"Legal in Finland!",
        @"Hard to label!",
        @"Technically good!",
        @"Bringing home the bacon!",
        @"Indie!",
        @"GOTY!",
        @"Ceci n'est pas une title screen!",
        @"Euclidian!",
        @"Now in 3D!",
        @"Inspirational!",
        @"Herregud!",
        @"Complex cellular automata!",
        @"Yes, sir!",
        @"Played by cowboys!",
        @"OpenGL 1.2!",
        @"Thousands of colors!",
        @"Try it!",
        @"Age of Wonders is better!",
        @"Try the mushroom stew!",
        @"Sensational!",
        @"Hot tamale, hot hot tamale!",
        @"Play him off, keyboard cat!",
        @"Guaranteed!",
        @"Macroscopic!",
        @"Bring it on!",
        @"Random splash!",
        @"Call your mother!",
        @"Monster infighting!",
        @"Loved by millions!",
        @"Ultimate edition!",
        @"Freaky!",
        @"You've got a brand new key!",
        @"Water proof!",
        @"Uninflammable!",
        @"Whoa, dude!",
        @"All inclusive!",
        @"Tell your friends!",
        @"NP is not in P!",
        @"Notch <3 ez!",
        @"Music by C418!",
        @"Livestreamed!",
        @"Haunted!",
        @"Polynomial!",
        @"Terrestrial!",
        @"Full of stars!",
        @"Scientific!",
        @"Cooler than Spock!",
        @"Collaborate and listen!",
        @"Never dig down!",
        @"Take frequent breaks!",
        @"Not linear!",
        @"Han shot first!",
        @"Nice to meet you!",
        @"Buckets of lava!",
        @"Ride the pig!",
        @"Larger than Earth!",
        @"sqrt(-1) love you!",
        @"Phobos anomaly!",
        @"Punching wood!",
        @"Falling off cliffs!",
        @"150% hyperbole!",
        @"Synecdoche!",
        @"Let's dance!",
        @"Seecret Friday update!",
        @"Reference implementation!",
        @"Lewd with two dudes with food!",
        @"Kiss the sky!",
        @"20 GOTO 10!",
        @"Verlet intregration!",
        @"Peter Griffin!",
        @"Do not distribute!",
        @"Cogito ergo sum!",
        @"A skeleton popped out!",
        @"The Work of Notch!",
        @"The sum of its parts!",
        @"BTAF used to be good!",
        @"I miss ADOM!",
        @"umop-apisdn!",
        @"OICU812!",
        @"Bring me Ray Cokes!",
        @"Finger-licking!",
        @"Thematic!",
        @"Pneumatic!",
        @"Sublime!",
        @"Octagonal!",
        @"Une baguette!",
        @"Gargamel plays it!",
        @"Rita is the new top dog!",
        @"SWM forever!",
        @"Representing Edsbyn!",
        @"Matt Damon!",
        @"Supercalifragilisticexpialidocious!",
        @"Consummate V's!",
        @"Cow Tools!",
        @"Double buffered!",
        @"Fan fiction!",
        @"Jason! Jason! Jason!",
        @"Hotter than the sun!",
        @"Internet enabled!",
        @"Autonomous!",
        @"Engage!",
        @"Fantasy!",
        @"DRR! DRR! DRR!",
        @"Kick it root down!",
        @"Regional resources!",
        @"Woo, facepunch!",
        @"Woo, somethingawful!",
        @"Woo, /v/!",
        @"Woo, tigsource!",
        @"Woo, minecraftforum!",
        @"Woo, worldofminecraft!",
        @"Woo, reddit!",
        @"Woo, 2pp!",
        @"Google anlyticsed!",
        @"Give us Gordon!",
        @"Tip your waiter!",
        @"Very fun!",
        @"12345 is a bad password!",
        @"Vote for net neutrality!",
        @"Lives in a pineapple under the sea!",
        @"MAP11 has two names!",
        @"Omnipotent!",
        @"Gasp!",
        @"...!",
        @"Bees, bees, bees, bees!",
        @"Jag känner en bot!",
        @"This text is hard to read if you play the game at the default resolution, but at 1080p it's fine!",
        @"Haha, LOL!",
        @"Hampsterdance!",
        @"Switches and ores!",
        @"Menger sponge!",
        @"idspispopd!",
        @"Eple (original edit)!",
        @"So fresh, so clean!",
        @"Slow acting portals!",
        @"Try the Nether!",
        @"Don't look directly at the bugs!",
        @"Oh, ok, Pigmen!",
        @"Finally with ladders!",
        @"Scary!",
        @"Play Minecraft, Watch Topgear, Get Pig!",
        @"Twittered about!",
        @"Jump up, jump up, and get down!",
        @"Joel is neat!",
        @"A riddle, wrapped in a mystery!",
        @"Huge tracts of land!",
        @"Welcome to your Doom!",
        @"Stay a while, stay forever!",
        @"Stay a while and listen!",
        @"Treatment for your rash!",
        @"\"Autological\" is!",
        @"Information wants to be free!",
        @"\"Almost never\" is an interesting concept!",
        @"Lots of truthiness!",
        @"The creeper is a spy!",
        @"Turing complete!",
        @"It's groundbreaking!",
        @"Let our battle's begin!",
        @"The sky is the limit!",
        @"Jeb has amazing hair!",
        @"Casual gaming!",
        @"Undefeated!",
        @"Kinda like Lemmings!",
        @"Follow the train, CJ!",
        @"Leveraging synergy!",
        @"DungeonQuest is unfair!",
        @"110813!",
        @"90210!",
        @"Check out the far lands!",
        @"Tyrion would love it!",
        @"Also try VVVVVV!",
        @"Also try Super Meat Boy!",
        @"Also try Terraria!",
        @"Also try Mount And Blade!",
        @"Also try Project Zomboid!",
        @"Also try World of Goo!",
        @"Also try Limbo!",
        @"Also try Pixeljunk Shooter!",
        @"Also try Braid!",
        @"That's super!",
        @"Bread is pain!",
        @"Read more books!",
        @"Khaaaaaaaaan!",
        @"Less addictive than TV Tropes!",
        @"More addictive than lemonade!",
        @"Bigger than a bread box!",
        @"Millions of peaches!",
        @"Fnord!",
        @"This is my true form!",
        @"Totally forgot about Dre!",
        @"Don't bother with the clones!",
        @"Pumpkinhead!",
        @"Hobo humping slobo babe!",
        @"Made by Jeb!",
        @"Has an ending!",
        @"Finally complete!",
        @"Feature packed!",
        @"Boots with the fur!",
        @"Stop, hammertime!",
        @"Testificates!",
        @"Conventional!",
        @"Homeomorphic to a 3-sphere!",
        @"Doesn't avoid double negatives!",
        @"Place ALL the blocks!",
        @"Does barrel rolls!",
        @"Meeting expectations!",
        @"PC gaming since 1873!",
        @"Ghoughpteighbteau tchoghs!",
        @"Déjà vu!",
        @"Got your nose!",
        @"Haley loves Elan!",
        @"Afraid of the big, black bat!",
        @"Doesn't use the U-word!",
        @"Child's play!",
        @"See you next Friday or so!",
        @"150 bpm for 400000 minutes!",
        @"Technologic!",
        @"Lennart lennart = new Lennart();",
        @"I see your vocabulary has improved!",
        @"Who put it there?",
        @"You can't explain that!",
        @"If not ok then return end",
        @"Flavor with no seasoning!",
        @"Strange, but not a stranger!",
        @"Tougher than diamonds, rich like cream!",
        @"Getting ready to show!",
        @"Getting ready to know!",
        @"Getting ready to drop!",
        @"Getting ready to shock!",
        @"Getting ready to freak!",
        @"Getting ready to speak!",
        @"It swings, it jives!",
        @"Cruising streets for gold!",
        @"Take an eggbeater and beat it against a skillet!",
        @"Make me a table, a funky table!",
        @"Take the elevator to the mezzanine!",
        @"Stop being reasonable, this is the Internet!",
        @"/give @a hugs 64",
        @"This is good for Realms.",
        @"Any computer is a laptop if you're brave enough!",
        @"Do it all, everything!",
        @"Where there is not light, there can spider!",
        @"GNU Terry Pratchett",
        @"More Digital!",
        @"Falling with style!",
        @"There's no stopping the Trollmaso",
        @"Throw yourself at the ground and miss",
        @"Rule #1: it's never my fault",
        @"Replaced molten cheese with blood?",
        @"Absolutely fixed relatively broken coordinates",
        @"Boats FTW",
        @"Javalicious edition",
        @"Should not be played while driving!",
        @"You're going too fast!",
        @"Don't feed chocolate to parrots!",
        @"The true meaning of covfefe",
        @"An illusion! What are you hiding?",
        @"Something's not quite right...",
        @"Monster infighting!",
        @"missingno",
        @"In case it isn't obvious, foxes aren't players.",
        @"Buzzy Bees!",
        @"Minecraft Java Edition presents: Disgusting Bugs",
        @"Team Mystic!",
        @"Hamilton!",
        @"Beta!",
        @"Absolutely no memes!"
    ];
}

static NSArray<NSString *> *mcsplashConfiguredSplashes(void) {
    return mcsplashDefaultSplashes();
}

static NSString *mcsplashPostScriptNameFromFontPath(NSString *fontPath) {
    NSData *data = [NSData dataWithContentsOfFile:fontPath];
    if (!data) {
        return nil;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);
    if (!provider) {
        return nil;
    }
    CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
    if (!cgFont) {
        return nil;
    }
    CFStringRef psNameRef = CGFontCopyPostScriptName(cgFont);
    CGFontRelease(cgFont);
    if (!psNameRef) {
        return nil;
    }
    NSString *psName = [(__bridge NSString *)psNameRef copy];
    CFRelease(psNameRef);
    return psName;
}

static UIFont *mcsplashFont(void) {
    if (!mcsplashTriedRegisteringFont) {
        mcsplashTriedRegisteringFont = YES;
        NSArray<NSString *> *candidatePaths = @[
            ROOT_PATH_NS(@"/Library/Application Support/SplashText/minecraft.ttf"),
            ROOT_PATH_NS(@"/Library/Application Support/SplashText/Minecraft.ttf"),
            ROOT_PATH_NS(@"/Library/Application Support/splashtext/Minecraft.ttf"),
            ROOT_PATH_NS(@"/Library/Application Support/splashtext/minecraft.ttf"),
            ROOT_PATH_NS(@"/Library/MobileSubstrate/DynamicLibraries/Minecraft.ttf"),
            ROOT_PATH_NS(@"/Library/MobileSubstrate/DynamicLibraries/minecraft.ttf")
        ];

        for (NSString *fontPath in candidatePaths) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:fontPath]) {
                continue;
            }

            NSURL *fontURL = [NSURL fileURLWithPath:fontPath];
            // Register may return false if already registered; still read descriptors.
            CTFontManagerRegisterFontsForURL((CFURLRef)fontURL, kCTFontManagerScopeProcess, NULL);
            NSArray *descriptors = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((CFURLRef)fontURL));
            if ([descriptors isKindOfClass:[NSArray class]] && descriptors.count > 0) {
                id first = descriptors.firstObject;
                if (first && CFGetTypeID((__bridge CFTypeRef)first) == CTFontDescriptorGetTypeID()) {
                    CFTypeRef attr = CTFontDescriptorCopyAttribute((CTFontDescriptorRef)(__bridge CFTypeRef)first, kCTFontNameAttribute);
                    if (attr && CFGetTypeID(attr) == CFStringGetTypeID()) {
                        mcsplashRegisteredFontName = [(__bridge NSString *)attr copy];
                    }
                    if (attr) {
                        CFRelease(attr);
                    }
                }
            }
            if (mcsplashRegisteredFontName.length == 0) {
                mcsplashRegisteredFontName = mcsplashPostScriptNameFromFontPath(fontPath);
            }
            if (mcsplashRegisteredFontName.length > 0) {
                break;
            }
        }
    }

    CGFloat size = MAX(4.0, MIN(30.0, mcsplashReadFloat(@"FontSize", 14.0)));
    NSString *fontName = mcsplashReadString(@"FontName", @"Minecraft");
    UIFont *font = [UIFont fontWithName:fontName size:size];
    if (font) {
        return font;
    }
    font = [UIFont fontWithName:@"Minecraft-Regular" size:size];
    if (font) {
        return font;
    }
    font = [UIFont fontWithName:@"MinecraftRegular" size:size];
    if (font) {
        return font;
    }
    if (mcsplashRegisteredFontName.length > 0) {
        font = [UIFont fontWithName:mcsplashRegisteredFontName size:size];
    }
    if (font) {
        return font;
    }
    font = [UIFont fontWithName:@"Minecraftia-Regular" size:size];
    if (font) {
        return font;
    }
    return [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightHeavy];
}

static UIColor *mcsplashYellowColor(void) {
    return [UIColor colorWithRed:1.0 green:0.95 blue:0.10 alpha:1.0];
}

@interface MCSplashCoordinator : NSObject
@property (nonatomic, strong) UILabel *splashLabel;
- (void)installInController:(UIViewController *)controller;
- (void)remove;
@end

@implementation MCSplashCoordinator

- (void)collectLabelsFromView:(UIView *)root output:(NSMutableArray<UILabel *> *)labels {
    if (!root) {
        return;
    }
    if ([root isKindOfClass:[UILabel class]]) {
        [labels addObject:(UILabel *)root];
    }
    for (UIView *subview in root.subviews) {
        [self collectLabelsFromView:subview output:labels];
    }
}

- (UILabel *)findClockLabelInView:(UIView *)root {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    [self collectLabelsFromView:root output:labels];

    UILabel *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    CGFloat maxYForClock = CGRectGetHeight(root.bounds) * 0.55;

    for (UILabel *label in labels) {
        if (label.hidden || label.alpha < 0.05 || label.bounds.size.width < 40.0 || label.bounds.size.height < 20.0) {
            continue;
        }

        CGRect frame = [label convertRect:label.bounds toView:root];
        if (CGRectGetMaxY(frame) > maxYForClock) {
            continue;
        }

        NSString *text = label.text ?: @"";
        CGFloat fontSize = label.font.pointSize;
        CGFloat score = fontSize * 3.0;
        if ([text containsString:@":"]) {
            score += 120.0;
        }
        if (text.length >= 3) {
            score += 20.0;
        }
        if (CGRectGetMidY(frame) < CGRectGetHeight(root.bounds) * 0.35) {
            score += 10.0;
        }

        if (score > bestScore) {
            bestScore = score;
            best = label;
        }
    }

    return best;
}

- (NSString *)randomSplashText {
    NSArray<NSString *> *splashes = mcsplashConfiguredSplashes();
    if (splashes.count == 0) {
        return @"Minecraft!";
    }
    NSUInteger index = arc4random_uniform((u_int32_t)splashes.count);
    return splashes[index];
}

- (void)installInController:(UIViewController *)controller {
    if (!mcsplashReadBool(@"Enabled", YES) || !controller.view) {
        [self remove];
        return;
    }

    UIView *host = controller.view;
    [host layoutIfNeeded];

    UILabel *clockLabel = [self findClockLabelInView:host];
    if (!clockLabel) {
        return;
    }

    UILabel *label = self.splashLabel;
    if (!label) {
        label = [[UILabel alloc] init];
        label.text = [self randomSplashText];
        label.textColor = mcsplashYellowColor();
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.shadowColor = [UIColor colorWithWhite:0 alpha:0.9];
        label.shadowOffset = CGSizeMake(2.0, 2.0);

        [host addSubview:label];
        self.splashLabel = label;

        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        pulse.fromValue = @1.0;
        pulse.toValue = @1.06;
        pulse.duration = 0.5;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [label.layer addAnimation:pulse forKey:@"mcsplash.pulse"];
    }
    if (label.superview != host) {
        [label removeFromSuperview];
        [host addSubview:label];
    }

    CGRect anchorRect = [clockLabel convertRect:clockLabel.bounds toView:host];
    CGFloat centerX = CGRectGetMaxX(anchorRect) + kMCSplashStaticOffsetX + mcsplashReadFloat(@"OffsetX", 8.0f);
    CGFloat centerY = CGRectGetMaxY(anchorRect) + kMCSplashStaticOffsetY + mcsplashReadFloat(@"OffsetY", -4.0f);
    CGFloat maxWidth = MAX(120.0f, MIN(300.0f, mcsplashReadFloat(@"MaxWidth", 220.0f)));

    label.font = mcsplashFont();
    CGSize fit = [label sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat width = MIN(maxWidth, MAX(80.0f, fit.width));
    CGFloat height = MAX(20.0f, fit.height);
    label.bounds = CGRectMake(0, 0, width, height);
    label.center = CGPointMake(centerX, centerY);
    label.transform = CGAffineTransformMakeRotation((CGFloat)(-25.0 * M_PI / 180.0));
}

- (void)remove {
    [self.splashLabel removeFromSuperview];
    self.splashLabel = nil;
}

@end

static const void *kMCSplashCoordinatorKey = &kMCSplashCoordinatorKey;

static void mcsplashInstall(UIViewController *controller) {
    MCSplashCoordinator *coordinator = objc_getAssociatedObject(controller, kMCSplashCoordinatorKey);
    if (!coordinator) {
        coordinator = [MCSplashCoordinator new];
        objc_setAssociatedObject(controller, kMCSplashCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [coordinator installInController:controller];
}

static void mcsplashRemove(UIViewController *controller) {
    MCSplashCoordinator *coordinator = objc_getAssociatedObject(controller, kMCSplashCoordinatorKey);
    [coordinator remove];
}

%hook CSCoverSheetViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    mcsplashInstall((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    mcsplashInstall((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    mcsplashRemove((UIViewController *)self);
    %orig;
}
%end

%hook SBDashBoardViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    mcsplashInstall((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    mcsplashInstall((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    mcsplashRemove((UIViewController *)self);
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        %init;
    }
}
