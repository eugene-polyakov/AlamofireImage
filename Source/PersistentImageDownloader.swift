//
//  PersistentImageDownloader.swift
//  AlamofireImage
//
//  Created by E on 3/20/16.
//  Copyright © 2016 Alamofire. All rights reserved.
//

import Foundation
import Alamofire

public class PersistentImageDownloader: ImageDownloader {

    let imageStorage: PersistentImageStorage?
    
    required public init(
        sessionManager: Manager,
        downloadPrioritization: DownloadPrioritization = .FIFO,
        maximumActiveDownloads: Int = 4,
        imageCache: ImageRequestCache? = AutoPurgingImageCache(),
        imageStorage: PersistentImageStorage? )
    {
        self.imageStorage = imageStorage
        super.init(sessionManager: sessionManager, downloadPrioritization: downloadPrioritization, maximumActiveDownloads: maximumActiveDownloads, imageCache: imageCache)
    }
    
    /**
     Creates a download request using the internal Alamofire `Manager` instance for the specified URL request.
     
     If the same download request is already in the queue or currently being downloaded, the filter and completion
     handler are appended to the already existing request. Once the request completes, all filters and completion
     handlers attached to the request are executed in the order they were added. Additionally, any filters attached
     to the request with the same identifiers are only executed once. The resulting image is then passed into each
     completion handler paired with the filter.
     
     You should not attempt to directly cancel the `request` inside the request receipt since other callers may be
     relying on the completion of that request. Instead, you should call `cancelRequestForRequestReceipt` with the
     returned request receipt to allow the `ImageDownloader` to optimize the cancellation on behalf of all active
     callers.
     
     - parameter URLRequest:     The URL request.
     - parameter receiptID:      The `identifier` for the `RequestReceipt` returned. Defaults to a new, randomly
     generated UUID.
     - parameter filter:         The image filter to apply to the image after the download is complete. Defaults
     to `nil`.
     - parameter progress:       The closure to be executed periodically during the lifecycle of the request.
     Defaults to `nil`.
     - parameter progressQueue:  The dispatch queue to call the progress closure on. Defaults to the main queue.
     - parameter completion:     The closure called when the download request is complete. Defaults to `nil`.
     
     - returns: The request receipt for the download request if available. `nil` if the image is stored in the image
     cache and the URL request cache policy allows the cache to be used.
     */
    public override func downloadImage(
        URLRequest URLRequest: URLRequestConvertible,
        receiptID: String = NSUUID().UUIDString,
        filter: ImageFilter? = nil,
        progress: ProgressHandler? = nil,
        progressQueue: dispatch_queue_t = dispatch_get_main_queue(),
        completion: CompletionHandler?)
        -> RequestReceipt?
    {
        var request: Request!
        
        dispatch_sync(synchronizationQueue) {
            // 1) Append the filter and completion handler to a pre-existing request if it already exists
            let identifier = ImageDownloader.identifierForURLRequest(URLRequest)
            
            if let responseHandler = self.responseHandlers[identifier] {
                responseHandler.operations.append(id: receiptID, filter: filter, completion: completion)
                request = responseHandler.request
                return
            }
            
            // 2) Attempt to load the image from the image cache if the cache policy allows it
            switch URLRequest.URLRequest.cachePolicy {
            case .UseProtocolCachePolicy, .ReturnCacheDataElseLoad, .ReturnCacheDataDontLoad:
                if let image = self.imageCache?.imageForRequest(
                    URLRequest.URLRequest,
                    withAdditionalIdentifier: filter?.identifier)
                {
                    dispatch_async(dispatch_get_main_queue()) {
                        let response = Response<Image, NSError>(
                            request: URLRequest.URLRequest,
                            response: nil,
                            data: nil,
                            result: .Success(image)
                        )
                        
                        completion?(response)
                    }
                    
                    return
                }
            default:
                break
            }
            
            // 2.5) Load original from storage
            

            
            // 3) Create the request and set up authentication, validation and response serialization
            request = self.sessionManager.request(URLRequest)
            
            
            if let storage = self.imageStorage {
                let cacheKey = URLRequest.URLRequest.URLString
                
                let storageResponse = storage.imageWithIdentifier(cacheKey, responder: { [weak self] image -> () in
                    guard let strongSelf = self else { return }
                    if let _image = image {
                        request.cancel()
                        request = nil
                        let responseHandler = strongSelf.safelyRemoveResponseHandlerWithIdentifier(identifier)
                        dispatch_sync(strongSelf.responseQueue, {
                            PersistentImageDownloader.processImageAndRespond(responseHandler, image: _image, request: URLRequest.URLRequest, response: nil, imageCache: strongSelf.imageCache)
                        })
                    } else {
                        // 5) Either start the request or enqueue it depending on the current active request count
                        if strongSelf.isActiveRequestCountBelowMaximumLimit() {
                            strongSelf.startRequest(request)
                        } else {
                            strongSelf.enqueueRequest(request)
                        }
                    }
                    })
                
                switch storageResponse {
                case .HaveCachedImage(let image):
                    dispatch_async(dispatch_get_main_queue()) {
                        let response = Response<Image, NSError>(
                            request: URLRequest.URLRequest,
                            response: nil,
                            data: nil,
                            result: .Success(image)
                        )
                        
                        completion?(response)
                    }
                    
                    return
                default: break
                }
                
            }
            
            
            if let credential = self.credential {
                request.authenticate(usingCredential: credential)
            }
            
            request.validate()
            
            if let progress = progress {
                request.progress { bytesRead, totalBytesRead, totalExpectedBytesToRead in
                    dispatch_async(progressQueue) {
                        progress(
                            bytesRead: bytesRead,
                            totalBytesRead: totalBytesRead,
                            totalExpectedBytesToRead: totalExpectedBytesToRead
                        )
                    }
                }
            }
            
            request.response(
                queue: self.responseQueue,
                responseSerializer: Request.imageResponseSerializer(),
                completionHandler: { [weak self] response in
                    guard let strongSelf = self, let request = response.request else { return }
                    
                    if let responseHandler = strongSelf.safelyRemoveExistingResponseHandlerWithIdentifier(identifier) {
                    
                        switch response.result {
                        case .Success(let image):
                            PersistentImageDownloader.processImageAndRespond(responseHandler, image: image, request: request, response: response, imageCache: self?.imageCache)
                            strongSelf.imageStorage?.addImage(image, withIdentifier: identifier)
                        case .Failure:
                            for (_, _, completion) in responseHandler.operations {
                                dispatch_async(dispatch_get_main_queue()) { completion?(response) }
                            }
                        }
                    }
                    
                    strongSelf.safelyDecrementActiveRequestCount()
                    strongSelf.safelyStartNextRequestIfNecessary()
                }
            )
            
            // 4) Store the response handler for use when the request completes
            let responseHandler = ResponseHandler(
                request: request,
                id: receiptID,
                filter: filter,
                completion: completion
            )
            
            self.responseHandlers[identifier] = responseHandler
            
        }
        
        if let request = request {
            return RequestReceipt(request: request, receiptID: receiptID)
        }
        
        return nil
    }

    class func processImageAndRespond(responseHandler: ResponseHandler, image: Image, request: NSURLRequest, response:Response<Image, NSError>?, imageCache:ImageRequestCache?) {
            var filteredImages: [String: Image] = [:]
            
            for (_, filter, completion) in responseHandler.operations {
                var filteredImage: Image
                
                if let filter = filter {
                    if let alreadyFilteredImage = filteredImages[filter.identifier] {
                        filteredImage = alreadyFilteredImage
                    } else {
                        filteredImage = filter.filter(image)
                        filteredImages[filter.identifier] = filteredImage
                    }
                } else {
                    filteredImage = image
                }
                
                imageCache?.addImage(
                    filteredImage,
                    forRequest: request,
                    withAdditionalIdentifier: filter?.identifier
                )
                
                let _response = Response<Image, NSError>(
                    request: response?.request ?? request,
                    response: response?.response,
                    data: response?.data,
                    result: .Success(filteredImage),
                    timeline: response?.timeline ?? Timeline()
                )

                dispatch_async(dispatch_get_main_queue()) {
                    
                    completion?(_response)
                }
        }
    }
    
    public override func cancelRequestForRequestReceipt(requestReceipt: RequestReceipt) {
        super.cancelRequestForRequestReceipt(requestReceipt)
        imageStorage?.cancelLoadForID(requestReceipt.receiptID)
    }
    
    func safelyRemoveExistingResponseHandlerWithIdentifier(identifier: String) -> ResponseHandler? {
        var responseHandler: ResponseHandler!
        
        dispatch_sync(synchronizationQueue) {
            responseHandler = self.responseHandlers.removeValueForKey(identifier)
        }
        
        return responseHandler
    }


}
