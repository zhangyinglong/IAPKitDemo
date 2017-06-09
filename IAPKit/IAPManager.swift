//
//  IAPManager.swift
//  IAPKitDemo
//
//  Created by zhang yinglong on 2017/6/9.
//  Copyright © 2017年 zhang yinglong. All rights reserved.
//

import Foundation
import StoreKit

typealias SKReceiptRequestCompletion = (_ success : Bool, _ error : NSError?) -> ()
typealias SKVerifyCompletion = (_ receipt : [String: Any]?, _ error : NSError?) -> ()
typealias SKProductsRequestCompletion = ([SKProduct]) -> ()

public enum ReceiptVerifyURL: String {
    case productionURL = "https://buy.itunes.apple.com/verifyReceipt"
    case sandboxURL = "https://sandbox.itunes.apple.com/verifyReceipt"
}

/**
 Status code returned by remote server.
 */
public enum ReceiptStatus: Int {
    
    /// Not decodable status.
    case unknown = -2
    
    /// No status returned.
    case none = -1
    
    /// valid status
    case valid = 0
    
    /// The App Store could not read the JSON object you provided.
    case jsonNotReadable = 21000
    
    /// The data in the receipt-data property was malformed or missing.
    case malformedOrMissingData = 21002
    
    /// The receipt could not be authenticated.
    case receiptCouldNotBeAuthenticated = 21003
    
    /// The shared secret you provided does not match the shared secret on file for your account.
    case secretNotMatching = 21004
    
    /// The receipt server is not currently available.
    case receiptServerUnavailable = 21005
    
    /// This receipt is valid but the subscription has expired. When this status code is returned
    /// to your server, the receipt data is also decoded and returned as part of the response.
    case subscriptionExpired = 21006
    
    /// This receipt is from the test environment, but it was sent to the production environment
    /// for verification. Send it to the test environment instead.
    case testReceipt = 21007
    
    /// This receipt is from the production environment, but it was sent to the test environment
    /// for verification. Send it to the production environment instead.
    case productionEnvironment = 21008
    
    var isValid: Bool { return self == .valid}
}

final class IAPManager: NSObject {
    
    var completion: SKVerifyCompletion?
    
    var secureEntry: String?
    
    fileprivate var receipt: String? {
        get {
            if let receiptURL = Bundle.main.appStoreReceiptURL,
                let receiptData = try? Data(contentsOf: receiptURL)
            {
                return receiptData.base64EncodedString(options: .endLineWithLineFeed)
            } else {
                return nil
            }
        }
    }
    
    fileprivate func verifyReceipt(receipt: String, completion: @escaping SKVerifyCompletion) {
#if DEBUG
        let storeURL = URL(string: ReceiptVerifyURL.sandboxURL.rawValue)!
        let storeRequest = NSMutableURLRequest(url: storeURL)
#else
        let storeURL = URL(string: ReceiptVerifyURL.productionURL.rawValue)!
        let storeRequest = NSMutableURLRequest(url: storeURL)
#endif
        storeRequest.httpMethod = "POST"
        var requestContents = [ "receipt-data": receipt ]
        if let secureEntry = secureEntry {
            requestContents["password"] = secureEntry
        }
        
        do {
            storeRequest.httpBody = try JSONSerialization.data(withJSONObject: requestContents, options: [])
            
            URLSession.shared.dataTask(with: storeRequest as URLRequest) { (data, response, error) in
                if let error = error {
                    completion(nil, error as NSError)
                } else  {
                    do {
                        let receiptInfo = try JSONSerialization.jsonObject(with: data!, options: .mutableLeaves) as! [String: Any]
                        completion(receiptInfo, nil)
                    } catch let error {
                        completion(nil, error as NSError)
                    }
                }
            }.resume()
        } catch let error {
            completion(nil, error as NSError)
        }
    }
    
    public func getSKProduct(productIdentifiers: Set<String>, completion: SKProductsRequestCompletion?) {
        let request = SKProductsRequest(productIdentifiers: productIdentifiers)
        request.completion = completion
        request.delegate = self
        request.start()
    }
    
    public func buy(productIdentifiers: Set<String>) {
        getSKProduct(productIdentifiers: productIdentifiers) { $0.forEach({ $0.buy() }) }
    }
    
    public func refreshSKReceipt(completion: SKReceiptRequestCompletion?) {
        let request = SKReceiptRefreshRequest()
        request.completion = completion
        request.delegate = self
        request.start()
    }
    
}

//MARK: SKProductsRequestDelegate

extension IAPManager : SKProductsRequestDelegate {
    
    internal func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        request.completion?(response.products)
    }
    
}

//MARK: SKRequestDelegate

extension IAPManager : SKRequestDelegate {
    
    internal func requestDidFinish(_ request: SKRequest) {
        if request is SKReceiptRefreshRequest {
            let r = request as! SKReceiptRefreshRequest
            r.completion?(true, nil)
        } else {
            // todo: SKProductsRequest
        }
    }
    
    internal func request(_ request: SKRequest, didFailWithError error: Error) {
        if request is SKReceiptRefreshRequest {
            let r = request as! SKReceiptRefreshRequest
            r.completion?(false, error as NSError)
        } else {
            // todo: SKProductsRequest
        }
    }

}

//MARK: SKPaymentTransactionObserver

extension IAPManager : SKPaymentTransactionObserver {
    
    // Sent when the transaction array has changed (additions or state changes).  Client should check state of transactions and finish as appropriate.
    internal func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .purchasing: // Transaction is being added to the server queue.
                break
            case .purchased: // Transaction is in queue, user has been charged.  Client should complete the transaction.
                if let receipt = receipt {
                    verifyReceipt(receipt: receipt) { receipt, error in
                        if receipt != nil {
                            queue.finishTransaction(transaction)
                            self.completion?(receipt, nil)
                        } else {
                            self.completion?(nil, error)
                        }
                    }
                } else {
                    refreshSKReceipt() { (success, error) in
                        if success {
                            
                        } else {
                            // todo:
                        }
                    }
                }
            case .failed: // Transaction was cancelled or failed before being added to the server queue.
                self.completion?(nil, transaction.error as NSError?)
                queue.finishTransaction(transaction)
            case .restored: // Transaction was restored from user's purchase history.  Client should complete the transaction.
                break
            case .deferred: // The transaction is in the queue, but its final status is pending external action.
                break
            }
        }
    }
    
    // Sent when transactions are removed from the queue (via finishTransaction:).
    internal func paymentQueue(_ queue: SKPaymentQueue, removedTransactions transactions: [SKPaymentTransaction]) {
        
    }
    
    // Sent when an error is encountered while adding transactions from the user's purchase history back to the queue.
    internal func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
        
    }
    
    // Sent when all transactions from the user's purchase history have successfully been added back to the queue.
    internal func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        
    }
    
    // Sent when the download state has changed.
    internal func paymentQueue(_ queue: SKPaymentQueue, updatedDownloads downloads: [SKDownload]) {
        
    }
    
}

//------------------------------------------------------------------------------------------------------------------------
//MARK: extension SKProduct

public extension SKProduct {
    
    private var payment: SKPayment {
        get { return SKPayment(product: self) }
    }
    
    public var priceFormatted: String? {
        get {
            let formatter = NumberFormatter()
            formatter.numberStyle = NumberFormatter.Style.currency
            formatter.locale = self.priceLocale
            formatter.usesSignificantDigits = true
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
            return formatter.string(from: self.price)!
        }
    }
    
    public func buy() {
        if SKPaymentQueue.canMakePayments() {
            SKPaymentQueue.default().add(self.payment)
        } else {
            // todo:
        }
    }
    
}

//MARK: extension SKProductsRequest

extension SKProductsRequest {
    
    private struct AssociatedKeys {
        static var AssociatedName = "AssociatedName"
    }
    
    var completion: SKProductsRequestCompletion? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.AssociatedName) as? SKProductsRequestCompletion
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.AssociatedName, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        }
    }
    
}

//MARK: extension SKReceiptRefreshRequest

extension SKReceiptRefreshRequest {
    
    private struct AssociatedKeys {
        static var AssociatedName = "AssociatedName"
    }
    
    var completion: SKReceiptRequestCompletion? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.AssociatedName) as? SKReceiptRequestCompletion
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.AssociatedName, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        }
    }
    
}

//MARK: extension SKPaymentTransaction

extension SKPaymentTransaction {
    
    private struct AssociatedKeys {
        static var AssociatedName = "AssociatedName"
    }
    
    var retryCount: Int {
        get {
            if let count = objc_getAssociatedObject(self, &AssociatedKeys.AssociatedName) as? NSNumber {
                return count.intValue
            } else {
                return 0
            }
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.AssociatedName, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
}
