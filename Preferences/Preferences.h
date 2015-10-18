#import <UIKit/UIKit.h>

@interface PSSpecifier : NSObject
@property (nonatomic, copy) NSString *name;
- (id)propertyForKey:(NSString *)key;
@end

@protocol PSBaseView <NSObject>
- (void)setParentController:(id)parentController;
@end

@interface PSViewController : UIViewController <PSBaseView>
- (instancetype)initForContentSize:(CGSize)contentSize;
@property (nonatomic, copy) PSSpecifier *specifier;
- (void)pushController:(id<PSBaseView>)controller;
@end

@interface PSViewController (Legacy)
- (void)viewWillBecomeVisible:(void *)source;
@end

@interface PSListController : PSViewController
- (PSSpecifier *)specifierForID:(NSString *)identifier;
@end
