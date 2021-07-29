#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@import AVFoundation;

@interface RNPhotoCaptureDelegate : NSObject<AVCapturePhotoCaptureDelegate>

- (instancetype)initWithRequestedPhotoSettings:(AVCapturePhotoSettings *)requestedPhotoSettings willCapturePhotoAnimation:(void (^)())willCapturePhotoAnimation completed:(void (^)( RNPhotoCaptureDelegate *photoCaptureDelegate ))completed;

@property (nonatomic, readonly) AVCapturePhotoSettings *requestedPhotoSettings;

@property (nonatomic) UIImage *takenImage;
@property (nonatomic) NSData *jpegPhotoData;
@property (nonatomic) NSData *dngPhotoData;

@end
