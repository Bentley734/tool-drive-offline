#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TDVisualizerSurface : UIView
- (void)configurePreset:(NSString *)preset animating:(BOOL)animating;
- (void)updateBands:(NSArray<NSNumber *> *)levels;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
