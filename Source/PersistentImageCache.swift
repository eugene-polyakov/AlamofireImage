//
//  PersistentImageCache.swift
//  AlamofireImage
//
//  Created by E on 3/20/16.
//  Copyright © 2016 Alamofire. All rights reserved.
//

import Foundation
#if os(iOS) || os(tvOS) || os(watchOS)
    import UIKit
#elseif os(OSX)
    import Cocoa
#endif

/// The `PersistentImageCache` protocol defines a set of APIs for adding, removing and fetching images from a cache.

public enum PersistentStorageResponse {
    case HaveCachedImage(image:UIImage)
    case WillLoadAsync(id:String)
}

public protocol PersistentImageStorage {
    /// Adds the image to the cache with the given identifier.
    func addImage(image: Image, withIdentifier identifier: String)
    
    /// Returns the image in the cache associated with the given identifier.
    func imageWithIdentifier(identifier: String, responder:(Image?)->()) -> PersistentStorageResponse
    func imageWithIdentifier(identifier: String, loaderID: String, responder:(Image?)->()) -> PersistentStorageResponse
    
    func cancelLoadForID(id:String)
}

public class FileImageStorage: PersistentImageStorage {
    
    var fileQueue = dispatch_queue_create("file_writer", DISPATCH_QUEUE_CONCURRENT)
    
    let cacheURL = NSFileManager.defaultManager().URLsForDirectory(.CachesDirectory, inDomains: .UserDomainMask).first!.URLByAppendingPathComponent("imageCache")
    static let cs = NSCharacterSet(charactersInString: "/\\?%*|\"<>:")
    
    var memoryCache: NSCache = {
        let cache = NSCache()
        return cache
    }()

    func sync(lock: AnyObject, closure: () -> Void) {
        objc_sync_enter(lock)
        closure()
        objc_sync_exit(lock)
    }
    
    let cancelledIds = NSMutableSet()
    let runningIds = NSMutableSet()
    
    public init() {
        do {
            var isDirectory:ObjCBool = false
            if NSFileManager.defaultManager().fileExistsAtPath(cacheURL.filePathURL!.absoluteString, isDirectory: &isDirectory) {
                if !isDirectory {
                    try NSFileManager.defaultManager().removeItemAtURL(cacheURL)
                    try NSFileManager.defaultManager().createDirectoryAtURL(cacheURL, withIntermediateDirectories: true, attributes: nil)
                }
            } else {
                try NSFileManager.defaultManager().createDirectoryAtURL(cacheURL, withIntermediateDirectories: true, attributes: nil)
            }
        } catch (let error) {
            fatalError("Cannot create image cache directory - \(error)")
        }
    }
    
    private func sanitizedCacheURL(string:String) -> NSURL {
        let fileName = string.stringByReplacingOccurrencesOfString("/", withString: "_").stringByReplacingOccurrencesOfString(":", withString: "_")
        let url = cacheURL.URLByAppendingPathComponent(fileName)
        return url
    }

    public func addImage(image: Image, withIdentifier identifier: String) {
        memoryCache.setObject(image, forKey: identifier)
        dispatch_async(fileQueue) { () -> Void in
            let url = self.sanitizedCacheURL(identifier)
            #if os(iOS) || os(tvOS) || os(watchOS)
                let data = UIImagePNGRepresentation(image)
            #elseif os(OSX)
                let rep = image.representations.first!
                let data = rep.representationUsingType(NSPNGFileType, properties:nil)
            #endif
            data?.writeToURL(url, atomically: false)
            self.memoryCache.removeObjectForKey(identifier)
        }
    }

    public func imageWithIdentifier(identifier: String, responder:(Image?)->()) -> PersistentStorageResponse {
        return imageWithIdentifier(identifier, loaderID: NSUUID().UUIDString, responder: responder)
    }
    
    public func imageWithIdentifier(identifier: String, loaderID: String, responder:(Image?)->()) -> PersistentStorageResponse {
        if let cached = memoryCache.objectForKey(identifier) as? Image {
            return .HaveCachedImage(image: cached)
        } else {
            
            let isCancelled:()->Bool = {
                var ret = false
                self.sync(self.cancelledIds, closure: { () -> Void in
                    if self.cancelledIds.containsObject(loaderID) {
                        self.cancelledIds.removeObject(loaderID)
                        ret = true
                    } else {
                        ret = false
                    }
                })
                return ret
            }
            
            sync(runningIds) {
                self.runningIds.addObject(loaderID)
            }
            dispatch_async(fileQueue) { () -> Void in
                defer {
                    self.sync(self.runningIds) {
                        self.runningIds.removeObject(loaderID)
                    }
                }
                
                let url = self.sanitizedCacheURL(identifier)
                if isCancelled() { responder(nil); return }
                if let data = NSData(contentsOfURL: url) {
                    if isCancelled() { responder(nil); return }
                    if let image = Image(data: data) {
                        image.af_inflate()
                        if isCancelled() { responder(nil); return }
                        responder(image)
                    } else {
                        responder(nil)
                    }
                } else {
                    responder(nil)
                }
            }
            return .WillLoadAsync(id: loaderID)
        }
    }
    
    public func cancelLoadForID(id: String) {
        self.sync(self.runningIds) { () -> Void in
            if self.runningIds.containsObject(id) {
                self.sync(self.cancelledIds, closure: { () -> Void in
                    self.cancelledIds.addObject(id)
                })
            }
        }
    }
    
}