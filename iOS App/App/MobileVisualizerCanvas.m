#import "MobileVisualizerCanvas.h"
#import <WebKit/WebKit.h>

// Use WebKit's iOS 14 Objective-C API on every supported system. This avoids
// introducing a load-time dependency on a newer system Swift overlay.
@interface TDVisualizerSurface () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, copy) NSString *preset;
@property (nonatomic) BOOL animating;
@property (nonatomic) BOOL ready;
@property (nonatomic) BOOL sendingBands;
@end

@implementation TDVisualizerSurface

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) { return nil; }
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    _web = [[WKWebView alloc] initWithFrame:self.bounds configuration:configuration];
    _web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _web.opaque = NO;
    _web.backgroundColor = UIColor.blackColor;
    _web.scrollView.scrollEnabled = NO;
    _web.userInteractionEnabled = NO;
    _web.navigationDelegate = self;
    _preset = @"tunnel";
    [self addSubview:_web];
    [self loadVisualizer];
    return self;
}

- (void)loadVisualizer {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"index" withExtension:@"html" subdirectory:@"Visualizer"];
    if (url != nil) {
        [_web loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
    }
}

- (void)configurePreset:(NSString *)preset animating:(BOOL)animating {
    _preset = [preset copy];
    _animating = animating;
    if (_ready) {
        [_web callAsyncJavaScript:@"window.mobileVisual(preset, animate)"
                        arguments:@{@"preset": _preset, @"animate": @(_animating)}
                          inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
    }
}

- (void)updateBands:(NSArray<NSNumber *> *)levels {
    if (!_ready || !_animating || _sendingBands) { return; }
    _sendingBands = YES;
    __weak typeof(self) weakSelf = self;
    [_web callAsyncJavaScript:@"window.mobileBands(values)" arguments:@{@"values": levels}
                      inFrame:nil inContentWorld:WKContentWorld.pageWorld
            completionHandler:^(id result, NSError *error) { weakSelf.sendingBands = NO; }];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    _ready = YES;
    [self configurePreset:_preset animating:_animating];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    _ready = NO;
    _sendingBands = NO;
    [self loadVisualizer];
}

- (void)invalidate {
    _ready = NO;
    _animating = NO;
    [_web stopLoading];
    _web.navigationDelegate = nil;
}
@end
