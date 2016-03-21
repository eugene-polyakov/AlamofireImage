//
//  UIImage+AlamofirePersistentImage.swift
//  AlamofireImage
//
//  Created by E on 3/20/16.
//  Copyright © 2016 Alamofire. All rights reserved.
//

import UIKit
import Alamofire

final class Lifted<T> {
    let value: T
    init(_ x: T) {
        value = x
    }
}

extension UIImageView {
    
    private struct AssociatedKeys {
        static var SharedPersistentImageCacheKey = "afp_UIImageView.PersistentCache"
        static var ActiveCacheLoaderID = "afp_UIImageView.ActiveCacheLoaderID"
    }
    
    public class var afp_sharedPersistentImageCache: PersistentImageStorage? {
        get {
            if let liftedCache = objc_getAssociatedObject(self, &AssociatedKeys.SharedPersistentImageCacheKey) as? Lifted<PersistentImageStorage> {
                return liftedCache.value
            } else {
            return nil
            }
        }
        set (cache) {
            objc_setAssociatedObject(self, &AssociatedKeys.SharedPersistentImageCacheKey, cache == nil ? nil : Lifted<PersistentImageStorage>(cache!), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    var afp_activeLoaderID: String? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.ActiveCacheLoaderID) as? String
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.ActiveCacheLoaderID, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    
    // MARK: - Image Download
    
    /**
    Asynchronously downloads an image from the specified URL, applies the specified image filter to the downloaded
    image and sets it once finished while executing the image transition.
    
    If the image is cached locally, the image is set immediately. Otherwise the specified placehoder image will be
    set immediately, and then the remote image will be set once the image request is finished.
    
    The `completion` closure is called after the image download and filtering are complete, but before the start of
    the image transition. Please note it is no longer the responsibility of the `completion` closure to set the
    image. It will be set automatically. If you require a second notification after the image transition completes,
    use a `.Custom` image transition with a `completion` closure. The `.Custom` `completion` closure is called when
    the image transition is finished.
    
    - parameter URL:                        The URL used for the image request.
    - parameter placeholderImage:           The image to be set initially until the image request finished. If
    `nil`, the image view will not change its image until the image
    request finishes. Defaults to `nil`.
    - parameter filter:                     The image filter applied to the image after the image request is
    finished. Defaults to `nil`.
    - parameter progress:                   The closure to be executed periodically during the lifecycle of the
    request. Defaults to `nil`.
    - parameter progressQueue:              The dispatch queue to call the progress closure on. Defaults to the
    main queue.
    - parameter imageTransition:            The image transition animation applied to the image when set.
    Defaults to `.None`.
    - parameter runImageTransitionIfCached: Whether to run the image transition if the image is cached. Defaults
    to `false`.
    - parameter completion:                 A closure to be executed when the image request finishes. The closure
    has no return value and takes three arguments: the original request,
    the response from the server and the result containing either the
    image or the error that occurred. If the image was returned from the
    image cache, the response will be `nil`. Defaults to `nil`.
    */
    public func afp_setImageWithURL(
        URL: NSURL,
        placeholderImage: UIImage? = nil,
        filter: ImageFilter? = nil,
        progress: ImageDownloader.ProgressHandler? = nil,
        progressQueue: dispatch_queue_t = dispatch_get_main_queue(),
        imageTransition: ImageTransition = .None,
        runImageTransitionIfCached: Bool = false,
        completion: (Response<UIImage, NSError> -> Void)? = nil)
    {
        afp_setImageWithURLRequest(
            URLRequestWithURL(URL),
            placeholderImage: placeholderImage,
            filter: filter,
            progress: progress,
            progressQueue: progressQueue,
            imageTransition: imageTransition,
            runImageTransitionIfCached: runImageTransitionIfCached,
            completion: completion
        )
    }
    
    /**
     Asynchronously downloads an image from the specified URL Request, applies the specified image filter to the downloaded
     image and sets it once finished while executing the image transition.
     
     If the image is cached locally, the image is set immediately. Otherwise the specified placehoder image will be
     set immediately, and then the remote image will be set once the image request is finished.
     
     The `completion` closure is called after the image download and filtering are complete, but before the start of
     the image transition. Please note it is no longer the responsibility of the `completion` closure to set the
     image. It will be set automatically. If you require a second notification after the image transition completes,
     use a `.Custom` image transition with a `completion` closure. The `.Custom` `completion` closure is called when
     the image transition is finished.
     
     - parameter URLRequest:                 The URL request.
     - parameter placeholderImage:           The image to be set initially until the image request finished. If
     `nil`, the image view will not change its image until the image
     request finishes. Defaults to `nil`.
     - parameter filter:                     The image filter applied to the image after the image request is
     finished. Defaults to `nil`.
     - parameter progress:                   The closure to be executed periodically during the lifecycle of the
     request. Defaults to `nil`.
     - parameter progressQueue:              The dispatch queue to call the progress closure on. Defaults to the
     main queue.
     - parameter imageTransition:            The image transition animation applied to the image when set.
     Defaults to `.None`.
     - parameter runImageTransitionIfCached: Whether to run the image transition if the image is cached. Defaults
     to `false`.
     - parameter completion:                 A closure to be executed when the image request finishes. The closure
     has no return value and takes three arguments: the original request,
     the response from the server and the result containing either the
     image or the error that occurred. If the image was returned from the
     image cache, the response will be `nil`. Defaults to `nil`.
     */
    public func afp_setImageWithURLRequest(
        URLRequest: URLRequestConvertible,
        placeholderImage: UIImage? = nil,
        filter: ImageFilter? = nil,
        progress: ImageDownloader.ProgressHandler? = nil,
        progressQueue: dispatch_queue_t = dispatch_get_main_queue(),
        imageTransition: ImageTransition = .None,
        runImageTransitionIfCached: Bool = false,
        completion: (Response<UIImage, NSError> -> Void)? = nil)
    {
        guard !isURLRequestURLEqualToActiveRequestURL(URLRequest) else { return }
        

        let imageDownloader = af_imageDownloader ?? UIImageView.af_sharedImageDownloader
        let imageCache = UIImageView.afp_sharedPersistentImageCache

        af_cancelImageRequest()
        
        if let _cache = imageCache, _id = afp_activeLoaderID {
            _cache.cancelLoadForID(_id)
        }
        
        // Use the image from the image cache if it exists
        var cacheKey = URLRequest.URLRequest.URLString
        if let id = filter?.identifier {
            cacheKey += "-" + id
        }
        
        let cachedResponseBlock:UIImage->Void = { (image) in
            let response = Response<UIImage, NSError>(
                request: URLRequest.URLRequest,
                response: nil,
                data: nil,
                result: .Success(image)
            )
            
            completion?(response)
            
            dispatch_async(dispatch_get_main_queue(), { () -> Void in
                if runImageTransitionIfCached {
                    let tinyDelay = dispatch_time(DISPATCH_TIME_NOW, Int64(0.001 * Float(NSEC_PER_SEC)))
                    
                    // Need to let the runloop cycle for the placeholder image to take affect
                    dispatch_after(tinyDelay, dispatch_get_main_queue()) {
                        self.runImageTransition(imageTransition, withImage: image)
                    }
                } else {
                    self.image = image
                }
            })
            
        }
        
        let downloadID = NSUUID().UUIDString

        let downloadBlock:()->() = {
            let requestReceipt = imageDownloader.downloadImage(
                URLRequest: URLRequest,
                receiptID: downloadID,
                filter: filter,
                progress: progress,
                progressQueue: progressQueue,
                completion: { [weak self] response in
                    guard let strongSelf = self else { return }
                    
                    completion?(response)
                    
                    guard
                        strongSelf.isURLRequestURLEqualToActiveRequestURL(response.request) &&
                            strongSelf.af_activeRequestReceipt?.receiptID == downloadID
                        else {
                            return
                    }
                    
                    if let image = response.result.value {
                        strongSelf.runImageTransition(imageTransition, withImage: image)
                        imageCache?.addImage(image, withIdentifier: cacheKey)
                    }
                    
                    strongSelf.af_activeRequestReceipt = nil
                }
            )
            
            self.af_activeRequestReceipt = requestReceipt
        }
        
        let cached = imageCache?.imageWithIdentifier(cacheKey, responder: { (image) in
            if let _image = image {
                cachedResponseBlock(_image)
            } else {
                downloadBlock()
            }
        })
        
        if let _cached = cached {
            switch (_cached) {
                case .HaveCachedImage(let image): cachedResponseBlock(image)
                case .WillLoadAsync(_): if let placeholderImage = placeholderImage { self.image = placeholderImage }
            }
        }
        
    }
    
    // MARK: - Image Download Cancellation
    
    /**
    Cancels the active download request, if one exists.
    */
    public func afp_cancelImageRequest() {
        let imageCache = UIImageView.afp_sharedPersistentImageCache

        if let activeLoadID = afp_activeLoaderID {
            imageCache?.cancelLoadForID(activeLoadID)
        }
        guard let activeRequestReceipt = af_activeRequestReceipt else { return }
        
        let imageDownloader = af_imageDownloader ?? UIImageView.af_sharedImageDownloader
        imageDownloader.cancelRequestForRequestReceipt(activeRequestReceipt)
        
        af_activeRequestReceipt = nil
    }
    
    // MARK: - Private - URL Request Helper Methods
    
    private func URLRequestWithURL(URL: NSURL) -> NSURLRequest {
        let mutableURLRequest = NSMutableURLRequest(URL: URL)
        
        for mimeType in Request.acceptableImageContentTypes {
            mutableURLRequest.addValue(mimeType, forHTTPHeaderField: "Accept")
        }
        
        return mutableURLRequest
    }
    
    private func isURLRequestURLEqualToActiveRequestURL(URLRequest: URLRequestConvertible?) -> Bool {
        if let
            currentRequest = af_activeRequestReceipt?.request.task.originalRequest
            where currentRequest.URLString == URLRequest?.URLRequest.URLString
        {
            return true
        }
        
        return false
    }
    }