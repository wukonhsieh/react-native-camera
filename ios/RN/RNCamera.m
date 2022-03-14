#import "RNCamera.h"
#import "RNCameraUtils.h"
#import "RNImageUtils.h"
#import "RNFileSystem.h"
#import "RNPhotoCaptureDelegate.h"
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/UIView+React.h>


@interface RNCamera ()

@property (nonatomic, weak) RCTBridge *bridge;

@property (nonatomic, assign, getter=isSessionPaused) BOOL paused;
@property (nonatomic, assign) BOOL hasUltraWildLen;
@property (nonatomic, strong) RCTPromiseResolveBlock videoRecordedResolve;
@property (nonatomic, strong) RCTPromiseRejectBlock videoRecordedReject;
@property (nonatomic, strong) id faceDetectorManager;

@property (nonatomic, copy) RCTDirectEventBlock onCameraReady;
@property (nonatomic, copy) RCTDirectEventBlock onMountError;
@property (nonatomic, copy) RCTDirectEventBlock onBarCodeRead;
@property (nonatomic, copy) RCTDirectEventBlock onFacesDetected;
@property (nonatomic, copy) RCTDirectEventBlock onPictureSaved;
@property (nonatomic, copy) RCTDirectEventBlock onStateChanged;

@property (nonatomic) NSMutableDictionary<NSNumber *, RNPhotoCaptureDelegate *> *inProgressPhotoCaptureDelegates;
@end

@implementation RNCamera

static NSDictionary *defaultFaceDetectorOptions = nil;

- (id)initWithBridge:(RCTBridge *)bridge
{
    if ((self = [super init])) {
        self.bridge = bridge;
        self.session = [AVCaptureSession new];
        self.sessionQueue = dispatch_queue_create("cameraQueue", DISPATCH_QUEUE_SERIAL);
        self.faceDetectorManager = [self createFaceDetectorManager];
#if !(TARGET_IPHONE_SIMULATOR)
        self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.previewLayer.needsDisplayOnBoundsChange = YES;
#endif
        self.paused = NO;
        self.hasUltraWildLen = NO;
        [self changePreviewOrientation:[UIApplication sharedApplication].statusBarOrientation];
        [self initializeCaptureSessionInput];
        [self startSession];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationChanged:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
        self.autoFocus = -1;
        self.focusX = 0.0;
        self.focusY = 0.0;
        self.exposureBias = 0.0;

        //        [[NSNotificationCenter defaultCenter] addObserver:self
        //                                                 selector:@selector(bridgeDidForeground:)
        //                                                     name:EX_UNVERSIONED(@"EXKernelBridgeDidForegroundNotification")
        //                                                   object:self.bridge];
        //
        //        [[NSNotificationCenter defaultCenter] addObserver:self
        //                                                 selector:@selector(bridgeDidBackground:)
        //                                                     name:EX_UNVERSIONED(@"EXKernelBridgeDidBackgroundNotification")
        //                                                   object:self.bridge];

    }
    return self;
}

- (void)onReady:(NSDictionary *)event
{
    if (_onCameraReady) {
        _onCameraReady(nil);
    }
}

- (void)onMountingError:(NSDictionary *)event
{
    if (_onMountError) {
        _onMountError(event);
    }
}

- (void)onCodeRead:(NSDictionary *)event
{
    if (_onBarCodeRead) {
        _onBarCodeRead(event);
    }
}

- (void)onPictureSaved:(NSDictionary *)event
{
    if (_onPictureSaved) {
        _onPictureSaved(event);
    }
}

- (void)onStateChanged:(NSDictionary *)event
{
    if (_onStateChanged) {
        _onStateChanged(event);
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.previewLayer.frame = self.bounds;
    [self setBackgroundColor:[UIColor blackColor]];
    [self.layer insertSublayer:self.previewLayer atIndex:0];
}

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
    [self insertSubview:view atIndex:atIndex + 1];
    [super insertReactSubview:view atIndex:atIndex];
    return;
}

- (void)removeReactSubview:(UIView *)subview
{
    [subview removeFromSuperview];
    [super removeReactSubview:subview];
    return;
}

- (void)removeFromSuperview
{
    RCTLog(@"=== removeFromSuperview ===");
    if (self.videoCaptureDeviceInput != nil) {
      AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
      if (device != nil) {
        RCTLog(@"=== clear observers ===");
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"videoZoomFactor"];
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"whiteBalanceMode"];
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"deviceWhiteBalanceGains"];
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"ISO"];
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"exposureMode"];
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"exposureDuration"];
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"exposureTargetBias"];
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"exposureTargetOffset"];
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"focusMode"];
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"lensPosition"];
        [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"isAdjustingFocus"];
      }
    }

    [self stopSession];
    [super removeFromSuperview];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
    self.videoCaptureDeviceInput = nil;
}

-(void)updateType
{
    RCTLog(@"=== updateType ===");
    dispatch_async(self.sessionQueue, ^{
        [self initializeCaptureSessionInput];
        if (!self.session.isRunning) {
            [self startSession];
        }
    });
}

-(void)updateLensMode
{
    RCTLog(@"=== updateLensMode ===");
    dispatch_async(self.sessionQueue, ^{
        [self initializeCaptureSessionInput];
        if (!self.session.isRunning) {
            [self startSession];
        }
    });
}

- (void)updateFlashMode
{
    RCTLog(@"=== updateFlashMode ===");
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (self.flashMode == RNCameraFlashModeTorch) {
        if (![device hasTorch])
            return;
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }
        if (device.hasTorch && [device isTorchModeSupported:AVCaptureTorchModeOn])
        {
            NSError *error = nil;
            if ([device lockForConfiguration:&error]) {
                [device setFlashMode:AVCaptureFlashModeOff];
                [device setTorchMode:AVCaptureTorchModeOn];
                [device unlockForConfiguration];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
            }
        }
    } else {
        if (![device hasFlash])
            return;
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }
        if (device.hasFlash && [device isFlashModeSupported:self.flashMode])
        {
            NSError *error = nil;
            if ([device lockForConfiguration:&error]) {
                if ([device isTorchModeSupported:AVCaptureTorchModeOff]) {
                    [device setTorchMode:AVCaptureTorchModeOff];
                }
                [device setFlashMode:self.flashMode];
                [device unlockForConfiguration];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updateFocusMode
{
    RCTLog(@"=== updateFocusMode ===");
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if ([device isFocusModeSupported:self.autoFocus]) {
        if ([device lockForConfiguration:&error]) {
            [device setFocusMode:self.autoFocus];

            if (!self.autoFocus) {
                if (![device respondsToSelector:@selector(isLockingFocusWithCustomLensPositionSupported)] || ![device isLockingFocusWithCustomLensPositionSupported]) {
                    return;
                }

                // update focus depth
                __weak __typeof__(device) weakDevice = device;
                [device setFocusModeLockedWithLensPosition:self.focusDepth completionHandler:^(CMTime syncTime) {
                    [weakDevice unlockForConfiguration];
                }];
            }

        } else {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updateFocusDepth
{
    RCTLog(@"=== updateFocusDepth ===");
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (device == nil || self.autoFocus < 0 || device.focusMode != RNCameraAutoFocusOff || device.position == RNCameraTypeFront) {
        return;
    }

    if (self.lensMode > 0) {
        return;
    }

    if (![device respondsToSelector:@selector(isLockingFocusWithCustomLensPositionSupported)] || ![device isLockingFocusWithCustomLensPositionSupported]) {
        RCTLogWarn(@"%s: Setting focusDepth isn't supported for this camera device", __func__);
        return;
    }

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    __weak __typeof__(device) weakDevice = device;
    [device setFocusModeLockedWithLensPosition:self.focusDepth completionHandler:^(CMTime syncTime) {
        [weakDevice unlockForConfiguration];
    }];
}


- (void)updateFocusPoint
{
    RCTLog(@"=== updateFocusPoint ===");
    if (self.autoFocus != AVCaptureFocusModeContinuousAutoFocus) {
        return;
    }

    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if ([device isFocusModeSupported:self.autoFocus]) {
        if ([device lockForConfiguration:&error]) {
            CGPoint newFocusPointOfInterest;
            newFocusPointOfInterest.x = self.focusX;
            newFocusPointOfInterest.y = self.focusY;
            [device setFocusPointOfInterest:newFocusPointOfInterest];
            [device setFocusMode:self.autoFocus];
        } else {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
        }
    }

    [device unlockForConfiguration];
}

/**
 * Update iso and duration for custom exposure
 */
- (void)updateExposure
{
    RCTLog(@"=== updateExposure ===");
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;
    __weak __typeof__(device) weakDevice = device;

    CMTime duration = CMTimeMakeWithSeconds(self.duration, 1000 * 1000 * 1000);
    float iso = self.iso;

    if (![device isExposureModeSupported: self.exposure]) {
      RCTLog(@"The exposure mode not supported!!!!! (exposure: %ld)", self.exposure);
      return;
    }

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if (self.exposure != RNCameraExposureCustom) {
        [device setExposureMode:self.exposure];
        [self.session commitConfiguration];
        [weakDevice unlockForConfiguration];
        return;
    }

    RCTLog(@"reset exposure bias to 0.");
    [device setExposureTargetBias:0 completionHandler:^(CMTime syncTime) {
        [device setExposureMode:self.exposure];
        RCTLog(@"set exposure to ISO: %f, duration: %f", iso, self.duration);
        [device setExposureModeCustomWithDuration:duration ISO:iso completionHandler:^(CMTime syncTime) {
            [weakDevice unlockForConfiguration];
        }];
    }];
    [self.session commitConfiguration];
}

- (void)updateExposureBias
{
    RCTLog(@"=== updateExposureBias ===");
    if (self.exposure != RNCameraExposureLocked) {
        RCTLog(@"exposure is not RNCameraExposureLocked, skips.");
        return;
    }

    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;
    __weak __typeof__(device) weakDevice = device;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    RCTLog(@"%f, %f, %f", self.exposureBias, device.minExposureTargetBias, device.maxExposureTargetBias);
    if (self.exposureBias >= device.minExposureTargetBias && self.exposureBias <= device.maxExposureTargetBias) {
        [device setExposureTargetBias:self.exposureBias completionHandler:^(CMTime syncTime) {
            RCTLog(@"%f, done.", self.exposureBias);
            [weakDevice unlockForConfiguration];
        }];
    }

    [self.session commitConfiguration];
}


- (void)updateZoom {
    RCTLog(@"=== updateZoom ===");
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    // if has ultrawild len, and using multiple cameras mode
    if (self.lensMode == 1 && self.hasUltraWildLen) {
      device.videoZoomFactor = (device.activeFormat.videoMaxZoomFactor - 2.0) * self.zoom + 2.0;
    } else {
      device.videoZoomFactor = (device.activeFormat.videoMaxZoomFactor - 1.0) * self.zoom + 1.0;
    }
    [device unlockForConfiguration];
}

- (void)updateWhiteBalance
{
    RCTLog(@"=== updateWhiteBalance ===");
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (self.whiteBalance == RNCameraWhiteBalanceAuto) {
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }

        [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
        [device unlockForConfiguration];
    } else {
        if (!device.isLockingWhiteBalanceWithCustomDeviceGainsSupported) {
          return;
        }
        __weak __typeof__(device) weakDevice = device;
        if (self.whiteBalance == RNCameraWhiteBalanceCustom) {
            AVCaptureWhiteBalanceTemperatureAndTintValues temperatureAndTint = {
                .temperature = self.temperature,
                .tint = self.tint,
            };
            AVCaptureWhiteBalanceGains rgbGains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:temperatureAndTint];
            rgbGains.redGain = MAX(1.0, rgbGains.redGain);
            rgbGains.greenGain = MAX(1.0, rgbGains.greenGain);
            rgbGains.blueGain = MAX(1.0, rgbGains.blueGain);
            if ([device lockForConfiguration:&error]) {
                [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:rgbGains completionHandler:^(CMTime syncTime) {
                    RCTLog(@"updateWhiteBalance custom configs set");
                    [weakDevice unlockForConfiguration];
                }];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
                return;
            }
        } else {
            AVCaptureWhiteBalanceTemperatureAndTintValues temperatureAndTint = {
                .temperature = [RNCameraUtils temperatureForWhiteBalance:self.whiteBalance],
                .tint = 0,
            };
            AVCaptureWhiteBalanceGains rgbGains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:temperatureAndTint];
            if ([device lockForConfiguration:&error]) {
                [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:rgbGains completionHandler:^(CMTime syncTime) {
                    [weakDevice unlockForConfiguration];
                }];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
                return;
            }
        }
    }
    [self.session commitConfiguration];
}

- (void)updatePictureSize
{
    [self updateSessionPreset:self.pictureSize];
}

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
- (void)updateFaceDetecting:(id)faceDetecting
{
    [_faceDetectorManager setIsEnabled:faceDetecting];
}

- (void)updateFaceDetectionMode:(id)requestedMode
{
    [_faceDetectorManager setMode:requestedMode];
}

- (void)updateFaceDetectionLandmarks:(id)requestedLandmarks
{
    [_faceDetectorManager setLandmarksDetected:requestedLandmarks];
}

- (void)updateFaceDetectionClassifications:(id)requestedClassifications
{
    [_faceDetectorManager setClassificationsDetected:requestedClassifications];
}
#endif

- (void) exposureOffsetWithResolve:(RCTPromiseResolveBlock)resolve andReject:(RCTPromiseRejectBlock)reject {
    if (!self.videoCaptureDeviceInput) {
        reject(nil, nil, nil);
        return;
    }
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    resolve(@(device.exposureTargetOffset));
}



- (AVCapturePhotoSettings *)currentPhotoSettings
{
	BOOL lensStabilizationEnabled = NO;
	BOOL rawEnabled = NO;
	AVCapturePhotoSettings *photoSettings = nil;
  AVCaptureDevice *device = [self.videoCaptureDeviceInput device];

	if (lensStabilizationEnabled && self.photoOutput.isLensStabilizationDuringBracketedCaptureSupported) {
		NSArray *bracketedSettings = nil;
		if (device.exposureMode == AVCaptureExposureModeCustom) {
			bracketedSettings = @[[AVCaptureManualExposureBracketedStillImageSettings manualExposureSettingsWithExposureDuration:AVCaptureExposureDurationCurrent ISO:AVCaptureISOCurrent]];
		} else {
      bracketedSettings = @[[AVCaptureAutoExposureBracketedStillImageSettings autoExposureSettingsWithExposureTargetBias:AVCaptureExposureTargetBiasCurrent]];
		}

		if (rawEnabled && self.photoOutput.availableRawPhotoPixelFormatTypes.count) {
      photoSettings = [AVCapturePhotoBracketSettings photoBracketSettingsWithRawPixelFormatType:(OSType)(((NSNumber *)self.photoOutput.availableRawPhotoPixelFormatTypes[0]).unsignedLongValue) processedFormat:nil bracketedSettings:bracketedSettings];
		} else {
      photoSettings = [AVCapturePhotoBracketSettings photoBracketSettingsWithRawPixelFormatType:0 processedFormat:@{ AVVideoCodecKey : AVVideoCodecJPEG } bracketedSettings:bracketedSettings];
		}
		((AVCapturePhotoBracketSettings *)photoSettings).lensStabilizationEnabled = YES;

	} else {
		if (rawEnabled && self.photoOutput.availableRawPhotoPixelFormatTypes.count > 0) {
			photoSettings = [AVCapturePhotoSettings photoSettingsWithRawPixelFormatType:(OSType)(((NSNumber *)self.photoOutput.availableRawPhotoPixelFormatTypes[0]).unsignedLongValue) processedFormat:@{ AVVideoCodecKey : AVVideoCodecJPEG }];
		} else {
			photoSettings = [AVCapturePhotoSettings photoSettings];
		}
	}

  // flash mode
  photoSettings.flashMode = AVCaptureFlashModeOff;

	if (photoSettings.availablePreviewPhotoPixelFormatTypes.count > 0) {
		photoSettings.previewPhotoFormat = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey : photoSettings.availablePreviewPhotoPixelFormatTypes[0] }; // The first format in the array is the preferred format
	}

	if (device.exposureMode == AVCaptureExposureModeCustom) {
		photoSettings.autoStillImageStabilizationEnabled = NO;
	}

	photoSettings.highResolutionPhotoEnabled = YES;

	return photoSettings;
}

- (void)takePicture:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];

    // AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    AVCaptureConnection *connection = [self.photoOutput connectionWithMediaType:AVMediaTypeVideo];

    // Fix orientation to portrait mode
    int orientation = AVCaptureVideoOrientationPortrait;
//    if ([options[@"orientation"] integerValue]) {
//        orientation = [options[@"orientation"] integerValue];
//    } else {
//        orientation = [RNCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]];
//    }
    [connection setVideoOrientation:orientation];

    RCTLog(@"takePicture ---------START");
    RCTLog(@"takePicture device iso %f", device.ISO);
    RCTLog(@"takePicture device duration %f", CMTimeGetSeconds(device.exposureDuration));
    RCTLog(@"takePicture device bias %f", device.exposureTargetBias);
    RCTLog(@"takePicture device offset %f", device.exposureTargetOffset);
    RCTLog(@"takePicture device R gain %f", device.deviceWhiteBalanceGains.redGain);
    RCTLog(@"takePicture device G gain %f", device.deviceWhiteBalanceGains.greenGain);
    RCTLog(@"takePicture device B gain %f", device.deviceWhiteBalanceGains.blueGain);
    RCTLog(@"takePicture device wb mode %ld", device.whiteBalanceMode);
    RCTLog(@"takePicture device mode %ld", device.exposureMode);
    RCTLog(@"takePicture pictureSize: %@", self.pictureSize);
    RCTLog(@"takePicture adjustingExposure: %@", device.isAdjustingExposure ? @"TRUE" : @"FALSE");
    RCTLog(@"takePicture adjustingWhiteBalance: %@", device.isAdjustingWhiteBalance ? @"TRUE" : @"FALSE");
    RCTLog(@"takePicture adjustingFocus: %@", device.isAdjustingFocus ? @"TRUE" : @"FALSE");
    RCTLog(@"takePicture lensPosition: %f", device.lensPosition);
    RCTLog(@"takePicture ---------END");

    // new APIs
    __weak typeof(self) weakSelf = self;
    RNCamera* strongSelf = weakSelf;

    AVCapturePhotoSettings *settings = [self currentPhotoSettings];
    // Use a separate object for the photo capture delegate to isolate each capture life cycle.
    RNPhotoCaptureDelegate *photoCaptureDelegate = [[RNPhotoCaptureDelegate alloc] initWithRequestedPhotoSettings:settings willCapturePhotoAnimation:^{
      // pass
    } completed:^(RNPhotoCaptureDelegate *photoCaptureDelegate) {
      self.inProgressPhotoCaptureDelegates[@(photoCaptureDelegate.requestedPhotoSettings.uniqueID)] = nil;
      BOOL useFastMode = options[@"fastMode"] && [options[@"fastMode"] boolValue];
      if (useFastMode) {
          resolve(nil);
      }

      UIImage *takenImage = photoCaptureDelegate.takenImage;
      CGImageRef takenCGImage = takenImage.CGImage;
      CGSize previewSize;
      if (UIInterfaceOrientationIsPortrait([[UIApplication sharedApplication] statusBarOrientation])) {
        previewSize = CGSizeMake(strongSelf.previewLayer.frame.size.height, strongSelf.previewLayer.frame.size.width);
      } else {
        previewSize = CGSizeMake(strongSelf.previewLayer.frame.size.width, strongSelf.previewLayer.frame.size.height);
      }
      CGRect cropRect = CGRectMake(0, 0, CGImageGetWidth(takenCGImage), CGImageGetHeight(takenCGImage));
      CGRect croppedSize = AVMakeRectWithAspectRatioInsideRect(previewSize, cropRect);
      takenImage = [RNImageUtils cropImage:takenImage toRect:croppedSize];

      if ([options[@"mirrorImage"] boolValue]) {
          takenImage = [RNImageUtils mirrorImage:takenImage];
      }
      if ([options[@"forceUpOrientation"] boolValue]) {
          takenImage = [RNImageUtils forceUpOrientation:takenImage];
      }

      if ([options[@"width"] integerValue]) {
          takenImage = [RNImageUtils scaleImage:takenImage toWidth:[options[@"width"] integerValue]];
      }

      // // dump EXIF
      // CFDictionaryRef exifAttachments = CMGetAttachment(photoCaptureDelegate.sampleBufferData, kCGImagePropertyExifDictionary, NULL);
      // if (exifAttachments) {
      //   // Do something with the attachments.
      //   NSLog(@"attachements: %@", exifAttachments);
      //
      // } else {
      //   NSLog(@"no attachments");
      // }

      NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
      float quality = [options[@"quality"] floatValue];
      NSData *takenImageData = UIImageJPEGRepresentation(takenImage, quality);
      if ([options[@"preview"] boolValue]) {
          RCTLog(@"===== is preview =====");
          // no need for exif
          NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".jpg"];
          response[@"uri"] = [RNImageUtils writeImage:takenImageData toPath:path];
      } else {
          RCTLog(@"===== is NOT preview =====");
          // Save images to tmp dir instead of cache dir to keep exif
          NSString *documentsDirectory = NSTemporaryDirectory();
          NSString *fullPath = [[documentsDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]] stringByAppendingPathExtension:@"jpg"];

          response[@"uri"] = [RNImageUtils writeImage:photoCaptureDelegate.jpegPhotoData toPath:fullPath];
      }
      response[@"width"] = @(takenImage.size.width);
      response[@"height"] = @(takenImage.size.height);

      if ([options[@"base64"] boolValue]) {
          response[@"base64"] = [takenImageData base64EncodedStringWithOptions:0];
      }

      // if ([options[@"exif"] boolValue]) {
      //     int imageRotation;
      //     switch (takenImage.imageOrientation) {
      //         case UIImageOrientationLeft:
      //         case UIImageOrientationRightMirrored:
      //             imageRotation = 90;
      //             break;
      //         case UIImageOrientationRight:
      //         case UIImageOrientationLeftMirrored:
      //             imageRotation = -90;
      //             break;
      //         case UIImageOrientationDown:
      //         case UIImageOrientationDownMirrored:
      //             imageRotation = 180;
      //             break;
      //         case UIImageOrientationUpMirrored:
      //         default:
      //             imageRotation = 0;
      //             break;
      //     }
      //     [RNImageUtils updatePhotoMetadata:imageSampleBuffer withAdditionalData:@{ @"Orientation": @(imageRotation) } inResponse:response]; // TODO
      // }

      if (useFastMode) {
          [strongSelf onPictureSaved:@{@"data": response, @"id": options[@"id"]}];
      } else {
          resolve(response);
      }
    }];

    dispatch_async( self.sessionQueue, ^{
      self.inProgressPhotoCaptureDelegates[@(photoCaptureDelegate.requestedPhotoSettings.uniqueID)] = photoCaptureDelegate;
      [self.photoOutput capturePhotoWithSettings:settings delegate:photoCaptureDelegate];
    });


    // // old APIs
    // __weak typeof(self) weakSelf = self;
    // [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler: ^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
    //     RNCamera* strongSelf = weakSelf;
    //     if (imageSampleBuffer && !error && strongSelf) {
    //         BOOL useFastMode = options[@"fastMode"] && [options[@"fastMode"] boolValue];
    //         if (useFastMode) {
    //             resolve(nil);
    //         }
    //         NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];
    //
    //         UIImage *takenImage = [UIImage imageWithData:imageData];
    //
    //         CGImageRef takenCGImage = takenImage.CGImage;
    //         CGSize previewSize;
    //         if (UIInterfaceOrientationIsPortrait([[UIApplication sharedApplication] statusBarOrientation])) {
    //             previewSize = CGSizeMake(strongSelf.previewLayer.frame.size.height, strongSelf.previewLayer.frame.size.width);
    //         } else {
    //             previewSize = CGSizeMake(strongSelf.previewLayer.frame.size.width, strongSelf.previewLayer.frame.size.height);
    //         }
    //         CGRect cropRect = CGRectMake(0, 0, CGImageGetWidth(takenCGImage), CGImageGetHeight(takenCGImage));
    //         CGRect croppedSize = AVMakeRectWithAspectRatioInsideRect(previewSize, cropRect);
    //         takenImage = [RNImageUtils cropImage:takenImage toRect:croppedSize];
    //
    //         if ([options[@"mirrorImage"] boolValue]) {
    //             takenImage = [RNImageUtils mirrorImage:takenImage];
    //         }
    //         if ([options[@"forceUpOrientation"] boolValue]) {
    //             takenImage = [RNImageUtils forceUpOrientation:takenImage];
    //         }
    //
    //         if ([options[@"width"] integerValue]) {
    //             takenImage = [RNImageUtils scaleImage:takenImage toWidth:[options[@"width"] integerValue]];
    //         }
    //
    //
    //         // dump EXIF
    //         CFDictionaryRef exifAttachments = CMGetAttachment( imageSampleBuffer, kCGImagePropertyExifDictionary, NULL);
    //         if (exifAttachments) {
    //           // Do something with the attachments.
    //           NSLog(@"attachements: %@", exifAttachments);
    //
    //         } else {
    //           NSLog(@"no attachments");
    //         }
    //
    //
    //         NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
    //         float quality = [options[@"quality"] floatValue];
    //         NSData *takenImageData = UIImageJPEGRepresentation(takenImage, quality);
    //         if ([options[@"preview"] boolValue]) {
    //             // no need for exif
    //             NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".jpg"];
    //             response[@"uri"] = [RNImageUtils writeImage:takenImageData toPath:path];
    //         } else {
    //             // Save images to tmp dir instead of cache dir to keep exif
    //             NSString *documentsDirectory = NSTemporaryDirectory();
    //             NSString *fullPath = [[documentsDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]] stringByAppendingPathExtension:@"jpg"];
    //
    //             response[@"uri"] = [RNImageUtils writeImage:imageData toPath:fullPath];
    //         }
    //         response[@"width"] = @(takenImage.size.width);
    //         response[@"height"] = @(takenImage.size.height);
    //
    //         if ([options[@"base64"] boolValue]) {
    //             response[@"base64"] = [takenImageData base64EncodedStringWithOptions:0];
    //         }
    //
    //         if ([options[@"exif"] boolValue]) {
    //             int imageRotation;
    //             switch (takenImage.imageOrientation) {
    //                 case UIImageOrientationLeft:
    //                 case UIImageOrientationRightMirrored:
    //                     imageRotation = 90;
    //                     break;
    //                 case UIImageOrientationRight:
    //                 case UIImageOrientationLeftMirrored:
    //                     imageRotation = -90;
    //                     break;
    //                 case UIImageOrientationDown:
    //                 case UIImageOrientationDownMirrored:
    //                     imageRotation = 180;
    //                     break;
    //                 case UIImageOrientationUpMirrored:
    //                 default:
    //                     imageRotation = 0;
    //                     break;
    //             }
    //             [RNImageUtils updatePhotoMetadata:imageSampleBuffer withAdditionalData:@{ @"Orientation": @(imageRotation) } inResponse:response]; // TODO
    //         }
    //
    //         if (useFastMode) {
    //             [strongSelf onPictureSaved:@{@"data": response, @"id": options[@"id"]}];
    //         } else {
    //             resolve(response);
    //         }
    //     } else {
    //         reject(@"E_IMAGE_CAPTURE_FAILED", @"Image could not be captured", error);
    //     }
    // }];
}

- (void)record:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    if (_movieFileOutput == nil) {
        // At the time of writing AVCaptureMovieFileOutput and AVCaptureVideoDataOutput (> GMVDataOutput)
        // cannot coexist on the same AVSession (see: https://stackoverflow.com/a/4986032/1123156).
        // We stop face detection here and restart it in when AVCaptureMovieFileOutput finishes recording.
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager stopFaceDetection];
#endif
        [self setupMovieFileCapture];
    }

    if (self.movieFileOutput == nil || self.movieFileOutput.isRecording || _videoRecordedResolve != nil || _videoRecordedReject != nil) {
      return;
    }

    if (options[@"maxDuration"]) {
        Float64 maxDuration = [options[@"maxDuration"] floatValue];
        self.movieFileOutput.maxRecordedDuration = CMTimeMakeWithSeconds(maxDuration, 30);
    }

    if (options[@"maxFileSize"]) {
        self.movieFileOutput.maxRecordedFileSize = [options[@"maxFileSize"] integerValue];
    }

    if (options[@"quality"]) {
        [self updateSessionPreset:[RNCameraUtils captureSessionPresetForVideoResolution:(RNCameraVideoResolution)[options[@"quality"] integerValue]]];
    }

    [self updateSessionAudioIsMuted:!!options[@"mute"]];

    AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
    [connection setVideoOrientation:[RNCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]]];

    if (options[@"codec"]) {
      AVVideoCodecType videoCodecType = options[@"codec"];
      if (@available(iOS 10, *)) {
        if ([self.movieFileOutput.availableVideoCodecTypes containsObject:videoCodecType]) {
          [self.movieFileOutput setOutputSettings:@{AVVideoCodecKey:videoCodecType} forConnection:connection];
          self.videoCodecType = videoCodecType;
        } else {
          RCTLogWarn(@"%s: Video Codec '%@' is not supported on this device.", __func__, videoCodecType);
        }
      } else {
        RCTLogWarn(@"%s: Setting videoCodec is only supported above iOS version 10.", __func__);
      }
    }

    dispatch_async(self.sessionQueue, ^{
        [self updateFlashMode];
        NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".mov"];
        NSURL *outputURL = [[NSURL alloc] initFileURLWithPath:path];
        [self.movieFileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
        self.videoRecordedResolve = resolve;
        self.videoRecordedReject = reject;
    });
}

- (void)stopRecording
{
    [self.movieFileOutput stopRecording];
}

- (void)resumePreview
{
    [[self.previewLayer connection] setEnabled:YES];
}

- (void)pausePreview
{
    [[self.previewLayer connection] setEnabled:NO];
}

- (void)startSession
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif
    //    NSDictionary *cameraPermissions = [EXCameraPermissionRequester permissions];
    //    if (![cameraPermissions[@"status"] isEqualToString:@"granted"]) {
    //        [self onMountingError:@{@"message": @"Camera permissions not granted - component could not be rendered."}];
    //        return;
    //    }
    dispatch_async(self.sessionQueue, ^{
        if (self.presetCamera == AVCaptureDevicePositionUnspecified) {
            return;
        }
        // // Fix resolution to 1920 * 1080
        // self.session.sessionPreset = AVCaptureSessionPreset1920x1080;
        // self.session.sessionPreset = AVCaptureSessionPresetPhoto;

        // // still image output
        // AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        // if ([self.session canAddOutput:stillImageOutput]) {
        //     stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
        //     [self.session addOutput:stillImageOutput];
        //     // [stillImageOutput setHighResolutionStillImageOutputEnabled:YES];
        //     self.stillImageOutput = stillImageOutput;
        // }

        // photo output
        AVCapturePhotoOutput *photoOutput = [[AVCapturePhotoOutput alloc] init];
        if ( [self.session canAddOutput:photoOutput] ) {
          [self.session addOutput:photoOutput];
          self.photoOutput = photoOutput;
          self.photoOutput.highResolutionCaptureEnabled = YES;

          self.inProgressPhotoCaptureDelegates = [NSMutableDictionary dictionary];
        } else {
          NSLog( @"Could not add photo output to the session" );
          return;
        }

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager maybeStartFaceDetectionOnSession:_session withPreviewLayer:_previewLayer];
#else
        // If AVCaptureVideoDataOutput is not required because of Google Vision
        // (see comment in -record), we go ahead and add the AVCaptureMovieFileOutput
        // to avoid an exposure rack on some devices that can cause the first few
        // frames of the recorded output to be underexposed.
        [self setupMovieFileCapture];
#endif
        [self setupOrDisableBarcodeScanner];

        __weak RNCamera *weakSelf = self;
        [self setRuntimeErrorHandlingObserver:
         [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:self.session queue:nil usingBlock:^(NSNotification *note) {
            RNCamera *strongSelf = weakSelf;
            dispatch_async(strongSelf.sessionQueue, ^{
                // Manually restarting the session since it must
                // have been stopped due to an error.
                [strongSelf.session startRunning];
                [strongSelf onReady:nil];
            });
        }]];

        [self.session startRunning];
        [self onReady:nil];
    });
}

- (void)stopSession
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif
    dispatch_async(self.sessionQueue, ^{
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager stopFaceDetection];
#endif
        [self.previewLayer removeFromSuperlayer];
        [self.session commitConfiguration];
        [self.session stopRunning];
        for (AVCaptureInput *input in self.session.inputs) {
            [self.session removeInput:input];
        }

        for (AVCaptureOutput *output in self.session.outputs) {
            [self.session removeOutput:output];
        }
    });
}

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change  context: (void *)context
{
  __weak typeof(self) weakSelf = self;
  RNCamera* strongSelf = weakSelf;
  if (keyPath == @"deviceWhiteBalanceGains") {
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    AVCaptureWhiteBalanceGains wbGains = device.deviceWhiteBalanceGains;
    AVCaptureWhiteBalanceTemperatureAndTintValues wb = [device temperatureAndTintValuesForDeviceWhiteBalanceGains: wbGains];
    [strongSelf onStateChanged:@{
      @"redGain": @(wbGains.redGain),
      @"greenGain": @(wbGains.greenGain),
      @"blueGain": @(wbGains.blueGain),
      @"temperature": @(wb.temperature),
      @"tint": @(wb.tint)
    }];

  } else if (keyPath == @"ISO") {
    [strongSelf onStateChanged:@{
      @"iso": [change objectForKey:NSKeyValueChangeNewKey]
    }];
  } else if (keyPath == @"exposureDuration") {
    [strongSelf onStateChanged:@{
      @"duration": [change objectForKey:NSKeyValueChangeNewKey]
    }];
  } else {
    [strongSelf onStateChanged:@{
      keyPath: [change objectForKey:NSKeyValueChangeNewKey]
    }];
  }
}

- (void)initializeCaptureSessionInput
{
    if (self.videoCaptureDeviceInput.device.position == self.presetCamera) {
        return;
    }
    __block UIInterfaceOrientation interfaceOrientation;

    void (^statusBlock)() = ^() {
        interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    };
    if ([NSThread isMainThread]) {
        statusBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), statusBlock);
    }

    AVCaptureVideoOrientation orientation = [RNCameraUtils videoOrientationForInterfaceOrientation:interfaceOrientation];
    dispatch_async(self.sessionQueue, ^{
        [self.session beginConfiguration];

        NSError *error = nil;
        AVCaptureDevice *captureDevice;
        if (self.lensMode == 0) {
          // default use single camera
          captureDevice = [RNCameraUtils deviceWithMediaType:AVMediaTypeVideo preferringPosition:self.presetCamera];

        } else {
          self.hasUltraWildLen = NO;
          AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[
            AVCaptureDeviceTypeBuiltInUltraWideCamera
          ] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
          if ([session.devices count] > 0) {
            self.hasUltraWildLen = YES;
          }

          // use multiple camera if supports
          NSArray<AVCaptureDeviceType>* deviceTypes = @[
            AVCaptureDeviceTypeBuiltInTripleCamera,
            AVCaptureDeviceTypeBuiltInDualCamera,
            AVCaptureDeviceTypeBuiltInDualWideCamera,
            AVCaptureDeviceTypeBuiltInWideAngleCamera,
            AVCaptureDeviceTypeBuiltInTrueDepthCamera
          ];
          AVCaptureDeviceDiscoverySession *backVideoDeviceDiscoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
          captureDevice = backVideoDeviceDiscoverySession.devices.firstObject;
        }
        AVCaptureDeviceInput *captureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];

        if (error || captureDeviceInput == nil) {
            RCTLog(@"%s: %@", __func__, error);
            return;
        }

        [self.session removeInput:self.videoCaptureDeviceInput];
        if ([self.session canAddInput:captureDeviceInput]) {
            [self.session addInput:captureDeviceInput];

            // clear old observer
            if (self.videoCaptureDeviceInput != nil) {
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"videoZoomFactor"];
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"whiteBalanceMode"];
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"deviceWhiteBalanceGains"];
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"ISO"];
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"exposureMode"];
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"exposureDuration"];
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"exposureTargetBias"];
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"exposureTargetOffset"];
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"focusMode"];
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"lensPosition"];
              [[self.videoCaptureDeviceInput device] removeObserver:self forKeyPath:@"isAdjustingFocus"];
            }

            self.videoCaptureDeviceInput = captureDeviceInput;
            AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
            if (device == nil) {
              RCTLog(@"device is null!!!!!");
            }

            [self updateFlashMode];
            [self updateZoom];
            [self updateFocusMode];
            [self updateFocusDepth];
            [self updateWhiteBalance];
            [self updatePictureSize];
            [self updateExposure];
            [self.previewLayer.connection setVideoOrientation:orientation];
            [self _updateMetadataObjectsToRecognize];

            // monitor properties changes
            if (device != nil) {
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"videoZoomFactor" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"whiteBalanceMode" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"deviceWhiteBalanceGains" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"ISO" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"exposureMode" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"exposureDuration" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"exposureTargetBias" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"exposureTargetOffset" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"focusMode" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"lensPosition" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
              [[self.videoCaptureDeviceInput device] addObserver:self forKeyPath:@"isAdjustingFocus" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
            }
        }

        // // update settings again, after it is ready.
        // dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), self.sessionQueue, ^{;
        //     [self updateExposure];
        // });

        [self.session commitConfiguration];
    });
}

#pragma mark - internal

- (void)updateSessionPreset:(AVCaptureSessionPreset)preset
{
#if !(TARGET_IPHONE_SIMULATOR)
    if (preset) {
        if (self.isDetectingFaces && [preset isEqual:AVCaptureSessionPresetPhoto]) {
            RCTLog(@"AVCaptureSessionPresetPhoto not supported during face detection. Falling back to AVCaptureSessionPresetHigh");
            preset = AVCaptureSessionPresetHigh;
        }
        dispatch_async(self.sessionQueue, ^{
            [self.session beginConfiguration];
            if ([self.session canSetSessionPreset:preset]) {
                self.session.sessionPreset = preset;
                RCTLog(@"Set session-preset to %@", preset);
            } else {
                RCTLog(@"Failed to set session-preset - %@", preset);
            }
            [self.session commitConfiguration];
        });
    }
#endif
}

- (void)updateSessionAudioIsMuted:(BOOL)isMuted
{
    dispatch_async(self.sessionQueue, ^{
        [self.session beginConfiguration];

        for (AVCaptureDeviceInput* input in [self.session inputs]) {
            if ([input.device hasMediaType:AVMediaTypeAudio]) {
                if (isMuted) {
                    [self.session removeInput:input];
                }
                [self.session commitConfiguration];
                return;
            }
        }

        if (!isMuted) {
            NSError *error = nil;

            AVCaptureDevice *audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioCaptureDevice error:&error];

            if (error || audioDeviceInput == nil) {
                RCTLogWarn(@"%s: %@", __func__, error);
                return;
            }

            if ([self.session canAddInput:audioDeviceInput]) {
                [self.session addInput:audioDeviceInput];
            }
        }

        [self.session commitConfiguration];
    });
}

- (void)bridgeDidForeground:(NSNotification *)notification
{
    if (![self.session isRunning] && [self isSessionPaused]) {
        self.paused = NO;
        dispatch_async( self.sessionQueue, ^{
            [self.session startRunning];
        });
    }
}

- (void)bridgeDidBackground:(NSNotification *)notification
{
    if ([self.session isRunning] && ![self isSessionPaused]) {
        self.paused = YES;
        dispatch_async( self.sessionQueue, ^{
            [self.session stopRunning];
        });
    }
}

- (void)orientationChanged:(NSNotification *)notification
{
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    [self changePreviewOrientation:orientation];
}

- (void)changePreviewOrientation:(UIInterfaceOrientation)orientation
{
    __weak typeof(self) weakSelf = self;
    AVCaptureVideoOrientation videoOrientation = [RNCameraUtils videoOrientationForInterfaceOrientation:orientation];
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.previewLayer.connection.isVideoOrientationSupported) {
            [strongSelf.previewLayer.connection setVideoOrientation:videoOrientation];
        }
    });
}

# pragma mark - AVCaptureMetadataOutput

- (void)setupOrDisableBarcodeScanner
{
    [self _setupOrDisableMetadataOutput];
    [self _updateMetadataObjectsToRecognize];
}

- (void)_setupOrDisableMetadataOutput
{
    if ([self isReadingBarCodes] && (_metadataOutput == nil || ![self.session.outputs containsObject:_metadataOutput])) {
        AVCaptureMetadataOutput *metadataOutput = [[AVCaptureMetadataOutput alloc] init];
        if ([self.session canAddOutput:metadataOutput]) {
            [metadataOutput setMetadataObjectsDelegate:self queue:self.sessionQueue];
            [self.session addOutput:metadataOutput];
            self.metadataOutput = metadataOutput;
        }
    } else if (_metadataOutput != nil && ![self isReadingBarCodes]) {
        [self.session removeOutput:_metadataOutput];
        _metadataOutput = nil;
    }
}

- (void)_updateMetadataObjectsToRecognize
{
    if (_metadataOutput == nil) {
        return;
    }

    NSArray *availableRequestedObjectTypes = [[NSArray alloc] init];
    NSArray *requestedObjectTypes = [NSArray arrayWithArray:self.barCodeTypes];
    NSArray *availableObjectTypes = _metadataOutput.availableMetadataObjectTypes;

    for(NSString *objectType in requestedObjectTypes) {
        if ([availableObjectTypes containsObject:objectType]) {
            availableRequestedObjectTypes = [availableRequestedObjectTypes arrayByAddingObject:objectType];
        }
    }

    [_metadataOutput setMetadataObjectTypes:availableRequestedObjectTypes];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection
{
    for(AVMetadataObject *metadata in metadataObjects) {
        if([metadata isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
            AVMetadataMachineReadableCodeObject *codeMetadata = (AVMetadataMachineReadableCodeObject *) metadata;
            for (id barcodeType in self.barCodeTypes) {
                if ([metadata.type isEqualToString:barcodeType]) {
                    AVMetadataMachineReadableCodeObject *transformed = (AVMetadataMachineReadableCodeObject *)[_previewLayer transformedMetadataObjectForMetadataObject:metadata];
                    NSDictionary *event = @{
                                            @"type" : codeMetadata.type,
                                            @"data" : codeMetadata.stringValue,
                                            @"bounds": @{
                                                @"origin": @{
                                                    @"x": [NSString stringWithFormat:@"%f", transformed.bounds.origin.x],
                                                    @"y": [NSString stringWithFormat:@"%f", transformed.bounds.origin.y]
                                                },
                                                @"size": @{
                                                    @"height": [NSString stringWithFormat:@"%f", transformed.bounds.size.height],
                                                    @"width": [NSString stringWithFormat:@"%f", transformed.bounds.size.width]
                                                }
                                            }
                                            };

                    [self onCodeRead:event];
                }
            }
        }
    }
}

# pragma mark - AVCaptureMovieFileOutput

- (void)setupMovieFileCapture
{
    AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];

    if ([self.session canAddOutput:movieFileOutput]) {
        [self.session addOutput:movieFileOutput];
        self.movieFileOutput = movieFileOutput;
    }
}

- (void)cleanupMovieFileCapture
{
    if ([_session.outputs containsObject:_movieFileOutput]) {
        [_session removeOutput:_movieFileOutput];
        _movieFileOutput = nil;
    }
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    BOOL success = YES;
    if ([error code] != noErr) {
        NSNumber *value = [[error userInfo] objectForKey:AVErrorRecordingSuccessfullyFinishedKey];
        if (value) {
            success = [value boolValue];
        }
    }
    if (success && self.videoRecordedResolve != nil) {
      AVVideoCodecType videoCodec = self.videoCodecType;
      if (videoCodec == nil) {
        videoCodec = [self.movieFileOutput.availableVideoCodecTypes firstObject];
      }

      self.videoRecordedResolve(@{ @"uri": outputFileURL.absoluteString, @"codec":videoCodec });
    } else if (self.videoRecordedReject != nil) {
        self.videoRecordedReject(@"E_RECORDING_FAILED", @"An error occurred while recording a video.", error);
    }
    self.videoRecordedResolve = nil;
    self.videoRecordedReject = nil;
    self.videoCodecType = nil;

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
    [self cleanupMovieFileCapture];

    // If face detection has been running prior to recording to file
    // we reenable it here (see comment in -record).
    [_faceDetectorManager maybeStartFaceDetectionOnSession:_session withPreviewLayer:_previewLayer];
#endif

    // if (self.session.sessionPreset != AVCaptureSessionPreset1920x1080) {
    //     [self updateSessionPreset:AVCaptureSessionPreset1920x1080];
    // }
}

# pragma mark - Face detector

- (id)createFaceDetectorManager
{
    Class faceDetectorManagerClass = NSClassFromString(@"RNFaceDetectorManager");
    Class faceDetectorManagerStubClass = NSClassFromString(@"RNFaceDetectorManagerStub");

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
    if (faceDetectorManagerClass) {
        return [[faceDetectorManagerClass alloc] initWithSessionQueue:_sessionQueue delegate:self];
    } else if (faceDetectorManagerStubClass) {
        return [[faceDetectorManagerStubClass alloc] init];
    }
#endif

    return nil;
}

- (void)onFacesDetected:(NSArray<NSDictionary *> *)faces
{
    if (_onFacesDetected) {
        _onFacesDetected(@{
                           @"type": @"face",
                           @"faces": faces
                           });
    }
}

@end
