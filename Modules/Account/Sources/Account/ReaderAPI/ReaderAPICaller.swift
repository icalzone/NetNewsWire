//
//  ReaderAPICaller.swift
//  Account
//
//  Created by Jeremy Beker on 5/28/19.
//  Copyright © 2019 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSWeb
import Secrets

enum CreateReaderAPISubscriptionResult {
	case created(ReaderAPISubscription)
	case notFound
}

final class ReaderAPICaller: NSObject {

	enum ItemIDType {
		case unread
		case starred
		case allForAccount
		case allForFeed
	}

	private enum ReaderState: String {
		case read = "user/-/state/com.google/read"
		case starred = "user/-/state/com.google/starred"
	}

	private enum ReaderStreams: String {
		case readingList = "user/-/state/com.google/reading-list"
	}

	private enum ReaderAPIEndpoints: String {
		case login = "/accounts/ClientLogin"
		case token = "/reader/api/0/token"
		case disableTag = "/reader/api/0/disable-tag"
		case renameTag = "/reader/api/0/rename-tag"
		case tagList = "/reader/api/0/tag/list"
		case subscriptionList = "/reader/api/0/subscription/list"
		case subscriptionEdit = "/reader/api/0/subscription/edit"
		case subscriptionAdd = "/reader/api/0/subscription/quickadd"
		case contents = "/reader/api/0/stream/items/contents"
		case itemIds = "/reader/api/0/stream/items/ids"
		case editTag = "/reader/api/0/edit-tag"
	}

	private var transport: Transport!
	private let uriComponentAllowed: CharacterSet

	private var accessToken: String?

	weak var accountMetadata: AccountMetadata?

	var variant: ReaderAPIVariant = .generic
	var credentials: Credentials?

	var server: String? {
		return apiBaseURL?.host
	}

	private var apiBaseURL: URL? {
		switch variant {
		case .generic, .freshRSS:
			guard let accountMetadata = accountMetadata else {
				return nil
			}
			return accountMetadata.endpointURL
		default:
			return URL(string: variant.host)
		}
	}

	init(transport: Transport) {
		self.transport = transport

		var urlHostAllowed = CharacterSet.urlHostAllowed
		urlHostAllowed.remove("+")
		urlHostAllowed.remove("&")
		uriComponentAllowed = urlHostAllowed
		super.init()
	}

	func cancelAll() {
		transport.cancelAll()
	}

	func validateCredentials(endpoint: URL, completion: @escaping (Result<Credentials?, Error>) -> Void) {
		guard let credentials = credentials else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		var request = URLRequest(url: endpoint.appendingPathComponent(ReaderAPIEndpoints.login.rawValue), credentials: credentials)
		addVariantHeaders(&request)

		transport.send(request: request) { result in
			switch result {
			case .success(let (_, data)):
				guard let resultData = data else {
					completion(.failure(TransportError.noData))
					break
				}

				// Convert the return data to UTF8 and then parse out the Auth token
				guard let rawData = String(data: resultData, encoding: .utf8) else {
					completion(.failure(TransportError.noData))
					break
				}

				var authData: [String: String] = [:]
				rawData.split(separator: "\n").forEach({ (line: Substring) in
					let items = line.split(separator: "=").map {String($0)}
					if items.count == 2 {
						authData[items[0]] = items[1]
					}
				})

				guard let authString = authData["Auth"] else {
					completion(.failure(CredentialsError.incompleteCredentials))
					break
				}

				// Save Auth Token for later use
				self.credentials = Credentials(type: .readerAPIKey, username: credentials.username, secret: authString)

				completion(.success(self.credentials))
			case .failure(let error):
				if let transportError = error as? TransportError, case .httpError(let code) = transportError, code == 404 {
					completion(.failure(ReaderAPIAccountDelegateError.urlNotFound))
				} else {
					completion(.failure(error))
				}
			}
		}

	}

	func requestAuthorizationToken(endpoint: URL, completion: @escaping (Result<String, Error>) -> Void) {
		// If we have a token already, use it
		if let accessToken = accessToken {
			completion(.success(accessToken))
			return
		}

		// Otherwise request one.
		guard let credentials = credentials else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		var request = URLRequest(url: endpoint.appendingPathComponent(ReaderAPIEndpoints.token.rawValue), credentials: credentials)
		addVariantHeaders(&request)

		transport.send(request: request) { result in
			switch result {
			case .success(let (_, data)):
				guard let resultData = data else {
					completion(.failure(TransportError.noData))
					break
				}

				// Convert the return data to UTF8 and then parse out the Auth token
				guard let accessToken = String(data: resultData, encoding: .utf8) else {
					completion(.failure(TransportError.noData))
					break
				}

				self.accessToken = accessToken
				completion(.success(accessToken))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func retrieveTags(completion: @escaping (Result<[ReaderAPITag]?, Error>) -> Void) {
		guard let baseURL = apiBaseURL else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		var url = baseURL
			.appendingPathComponent(ReaderAPIEndpoints.tagList.rawValue)
			.appendingQueryItem(URLQueryItem(name: "output", value: "json"))

		if variant == .inoreader {
			url = url?.appendingQueryItem(URLQueryItem(name: "types", value: "1"))
		}

		guard let callURL = url else {
			completion(.failure(TransportError.noURL))
			return
		}

		var request = URLRequest(url: callURL, credentials: credentials)
		addVariantHeaders(&request)

		transport.send(request: request, resultType: ReaderAPITagContainer.self) { result in
			switch result {
			case .success(let (_, wrapper)):
				completion(.success(wrapper?.tags))
			case .failure(let error):
				completion(.failure(error))
			}
		}

	}

	func renameTag(oldName: String, newName: String, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let baseURL = apiBaseURL else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		self.requestAuthorizationToken(endpoint: baseURL) { (result) in
			switch result {
			case .success(let token):
				var request = URLRequest(url: baseURL.appendingPathComponent(ReaderAPIEndpoints.renameTag.rawValue), credentials: self.credentials)
				self.addVariantHeaders(&request)
				request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
				request.httpMethod = "POST"

				guard let encodedOldName = self.encodeForURLPath(oldName), let encodedNewName = self.encodeForURLPath(newName) else {
					completion(.failure(ReaderAPIAccountDelegateError.invalidParameter))
					return
				}

				let oldTagName = "user/-/label/\(encodedOldName)"
				let newTagName = "user/-/label/\(encodedNewName)"
				let postDataString = "T=\(token)&s=\(oldTagName)&dest=\(newTagName)"
				let postData = Data(postDataString.utf8)

				self.transport.send(request: request, method: HTTPMethod.post, payload: postData, completion: { (result) in
					switch result {
					case .success:
						completion(.success(()))
					case .failure(let error):
						completion(.failure(error))
					}
				})

			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func deleteTag(folder: Folder, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let baseURL = apiBaseURL else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		guard let folderExternalID = folder.externalID else {
			completion(.failure(ReaderAPIAccountDelegateError.invalidParameter))
			return
		}

		self.requestAuthorizationToken(endpoint: baseURL) { (result) in
			switch result {
			case .success(let token):
				var request = URLRequest(url: baseURL.appendingPathComponent(ReaderAPIEndpoints.disableTag.rawValue), credentials: self.credentials)
				self.addVariantHeaders(&request)
				request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
				request.httpMethod = "POST"

				let postDataString = "T=\(token)&s=\(folderExternalID)"
				let postData = Data(postDataString.utf8)

				self.transport.send(request: request, method: HTTPMethod.post, payload: postData, completion: { (result) in
					switch result {
					case .success:
						completion(.success(()))
					case .failure(let error):
						completion(.failure(error))
					}
				})

			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func retrieveSubscriptions(completion: @escaping (Result<[ReaderAPISubscription]?, Error>) -> Void) {
		guard let baseURL = apiBaseURL else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		let url = baseURL
			.appendingPathComponent(ReaderAPIEndpoints.subscriptionList.rawValue)
			.appendingQueryItem(URLQueryItem(name: "output", value: "json"))

		guard let callURL = url else {
			completion(.failure(TransportError.noURL))
			return
		}

		var request = URLRequest(url: callURL, credentials: credentials)
		addVariantHeaders(&request)

		transport.send(request: request, resultType: ReaderAPISubscriptionContainer.self) { result in
			switch result {
			case .success(let (_, container)):
				completion(.success(container?.subscriptions))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func createSubscription(url: String, name: String?, folder: Folder?, completion: @escaping (Result<CreateReaderAPISubscriptionResult, Error>) -> Void) {
		guard let baseURL = apiBaseURL else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		func findSubscription(streamID: String, completion: @escaping (Result<CreateReaderAPISubscriptionResult, Error>) -> Void) {
			// There is no call to get a single subscription entry, so we get them all,
			// look up the one we just subscribed to and return that
			self.retrieveSubscriptions(completion: { (result) in
				switch result {
				case .success(let subscriptions):
					guard let subscriptions = subscriptions else {
						completion(.failure(AccountError.createErrorNotFound))
						return
					}

					guard let subscription = subscriptions.first(where: { (sub) -> Bool in
						sub.feedID == streamID
					}) else {
						completion(.failure(AccountError.createErrorNotFound))
						return
					}

					completion(.success(.created(subscription)))

				case .failure(let error):
					completion(.failure(error))
				}
			})
		}

		self.requestAuthorizationToken(endpoint: baseURL) { (result) in
			switch result {
			case .success(let token):
				let callURL = baseURL
					.appendingPathComponent(ReaderAPIEndpoints.subscriptionAdd.rawValue)

				var request = URLRequest(url: callURL, credentials: self.credentials)
				self.addVariantHeaders(&request)
				request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
				request.httpMethod = "POST"

				guard let encodedFeedURL = self.encodeForURLPath(url) else {
					completion(.failure(ReaderAPIAccountDelegateError.invalidParameter))
					return
				}
				let postDataString = "T=\(token)&quickadd=\(encodedFeedURL)"
				let postData = Data(postDataString.utf8)

				self.transport.send(request: request, method: HTTPMethod.post, data: postData, resultType: ReaderAPIQuickAddResult.self, completion: { (result) in
					switch result {
					case .success(let (_, subResult)):

						switch subResult?.numResults {
						case 0:
							completion(.success(.notFound))
						default:
							guard let streamId = subResult?.streamId else {
								completion(.failure(AccountError.createErrorNotFound))
								return
							}

							findSubscription(streamID: streamId, completion: completion)
						}

					case .failure(let error):
						completion(.failure(error))
					}

				})

			case .failure(let error):
				completion(.failure(error))
			}

		}

	}

	func renameSubscription(subscriptionID: String, newName: String, completion: @escaping (Result<Void, Error>) -> Void) {
		changeSubscription(subscriptionID: subscriptionID, title: newName, completion: completion)
	}

	func deleteSubscription(subscriptionID: String, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let baseURL = apiBaseURL else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		self.requestAuthorizationToken(endpoint: baseURL) { (result) in
			switch result {
			case .success(let token):
				var request = URLRequest(url: baseURL.appendingPathComponent(ReaderAPIEndpoints.subscriptionEdit.rawValue), credentials: self.credentials)
				self.addVariantHeaders(&request)
				request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
				request.httpMethod = "POST"

				let postDataString = "T=\(token)&s=\(subscriptionID)&ac=unsubscribe"
				let postData = Data(postDataString.utf8)

				self.transport.send(request: request, method: HTTPMethod.post, payload: postData, completion: { (result) in
					switch result {
					case .success:
						completion(.success(()))
					case .failure(let error):
						completion(.failure(error))
					}
				})

			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func createTagging(subscriptionID: String, tagName: String, completion: @escaping (Result<Void, Error>) -> Void) {
		changeSubscription(subscriptionID: subscriptionID, addTagName: tagName, completion: completion)
	}

	func deleteTagging(subscriptionID: String, tagName: String, completion: @escaping (Result<Void, Error>) -> Void) {
		changeSubscription(subscriptionID: subscriptionID, removeTagName: tagName, completion: completion)
	}

	func moveSubscription(subscriptionID: String, fromTag: String, toTag: String, completion: @escaping (Result<Void, Error>) -> Void) {
		changeSubscription(subscriptionID: subscriptionID, removeTagName: fromTag, addTagName: toTag, completion: completion)
	}

	private func changeSubscription(subscriptionID: String, removeTagName: String? = nil, addTagName: String? = nil, title: String? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
		guard removeTagName != nil || addTagName != nil || title != nil else {
			completion(.failure(ReaderAPIAccountDelegateError.invalidParameter))
			return
		}

		guard let baseURL = apiBaseURL else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		self.requestAuthorizationToken(endpoint: baseURL) { (result) in
			switch result {
			case .success(let token):
				var request = URLRequest(url: baseURL.appendingPathComponent(ReaderAPIEndpoints.subscriptionEdit.rawValue), credentials: self.credentials)
				self.addVariantHeaders(&request)
				request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
				request.httpMethod = "POST"

				var postString = "T=\(token)&s=\(subscriptionID)&ac=edit"
				if let fromLabel = self.encodeForURLPath(removeTagName) {
					postString += "&r=user/-/label/\(fromLabel)"
				}
				if let toLabel = self.encodeForURLPath(addTagName) {
					postString += "&a=user/-/label/\(toLabel)"
				}
				if let encodedTitle = self.encodeForURLPath(title) {
					postString += "&t=\(encodedTitle)"
				}
				let postData = postString.data(using: String.Encoding.utf8)

				self.transport.send(request: request, method: HTTPMethod.post, payload: postData!, completion: { (result) in
					switch result {
					case .success:
						completion(.success(()))
					case .failure(let error):
						completion(.failure(error))
					}
				})

			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func retrieveEntries(articleIDs: [String], completion: @escaping (Result<([ReaderAPIEntry]?), Error>) -> Void) {

		guard !articleIDs.isEmpty else {
			completion(.success(([ReaderAPIEntry]())))
			return
		}

		guard let baseURL = apiBaseURL else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		self.requestAuthorizationToken(endpoint: baseURL) { (result) in
			switch result {
			case .success(let token):
				var request = URLRequest(url: baseURL.appendingPathComponent(ReaderAPIEndpoints.contents.rawValue), credentials: self.credentials)
				self.addVariantHeaders(&request)
				request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
				request.httpMethod = "POST"

				// Get ids from above into hex representation of value
				let idsToFetch = articleIDs.map({ articleID -> String in
					if self.variant == .theOldReader {
						return "i=tag:google.com,2005:reader/item/\(articleID)"
					} else {
						let idValue = Int(articleID)!
						let idHexString = String(idValue, radix: 16, uppercase: false)
						return "i=tag:google.com,2005:reader/item/\(idHexString)"
					}
				}).joined(separator: "&")

				let postDataString = "T=\(token)&output=json&\(idsToFetch)"
				let postData = Data(postDataString.utf8)

				self.transport.send(request: request, method: HTTPMethod.post, data: postData, resultType: ReaderAPIEntryWrapper.self, completion: { (result) in
					switch result {
					case .success(let (_, entryWrapper)):
						guard let entryWrapper = entryWrapper else {
							completion(.failure(ReaderAPIAccountDelegateError.invalidResponse))
							return
						}

						completion(.success((entryWrapper.entries)))
					case .failure(let error):
						completion(.failure(error))
					}
				})

			case .failure(let error):
				completion(.failure(error))
			}
		}

	}

	func retrieveItemIDs(type: ItemIDType, feedID: String? = nil, completion: @escaping ((Result<[String], Error>) -> Void)) {
		guard let baseURL = apiBaseURL else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		var queryItems = [
			URLQueryItem(name: "n", value: "1000"),
			URLQueryItem(name: "output", value: "json")
		]

		switch type {
		case .allForAccount:
			let since: Date = {
				if let lastArticleFetch = self.accountMetadata?.lastArticleFetchStartTime {
					return lastArticleFetch
				} else {
					return Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
				}
			}()

			let sinceTimeInterval = since.timeIntervalSince1970
			queryItems.append(URLQueryItem(name: "ot", value: String(Int(sinceTimeInterval))))
			queryItems.append(URLQueryItem(name: "s", value: ReaderStreams.readingList.rawValue))
		case .allForFeed:
			guard let feedID = feedID else {
				completion(.failure(ReaderAPIAccountDelegateError.invalidParameter))
				return
			}
			let sinceTimeInterval = (Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()).timeIntervalSince1970
			queryItems.append(URLQueryItem(name: "ot", value: String(Int(sinceTimeInterval))))
			queryItems.append(URLQueryItem(name: "s", value: feedID))
		case .unread:
			queryItems.append(URLQueryItem(name: "s", value: ReaderStreams.readingList.rawValue))
			queryItems.append(URLQueryItem(name: "xt", value: ReaderState.read.rawValue))
		case .starred:
			queryItems.append(URLQueryItem(name: "s", value: ReaderState.starred.rawValue))
		}

		let url = baseURL
			.appendingPathComponent(ReaderAPIEndpoints.itemIds.rawValue)
			.appendingQueryItems(queryItems)

		guard let callURL = url else {
			completion(.failure(TransportError.noURL))
			return
		}

		var request: URLRequest = URLRequest(url: callURL, credentials: credentials)
		addVariantHeaders(&request)

		self.transport.send(request: request, resultType: ReaderAPIReferenceWrapper.self) { result in
			switch result {
			case .success(let (response, entries)):
				guard let entriesItemRefs = entries?.itemRefs, entriesItemRefs.count > 0 else {
					completion(.success([String]()))
					return
				}
				let dateInfo = HTTPDateInfo(urlResponse: response)
				let itemIDs = entriesItemRefs.compactMap { $0.itemId }
				self.retrieveItemIDs(type: type, url: callURL, dateInfo: dateInfo, itemIDs: itemIDs, continuation: entries?.continuation, completion: completion)
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func retrieveItemIDs(type: ItemIDType, url: URL, dateInfo: HTTPDateInfo?, itemIDs: [String], continuation: String?, completion: @escaping ((Result<[String], Error>) -> Void)) {
		guard let continuation = continuation else {
			if type == .allForAccount {
				self.accountMetadata?.lastArticleFetchStartTime = dateInfo?.date
				self.accountMetadata?.lastArticleFetchEndTime = Date()
			}
			completion(.success(itemIDs))
			return
		}

		guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
			completion(.failure(ReaderAPIAccountDelegateError.invalidParameter))
			return
		}

		var queryItems = urlComponents.queryItems!.filter({ $0.name != "c" })
		queryItems.append(URLQueryItem(name: "c", value: continuation))
		urlComponents.queryItems = queryItems

		guard let callURL = urlComponents.url else {
			completion(.failure(TransportError.noURL))
			return
		}

		var request: URLRequest = URLRequest(url: callURL, credentials: credentials)
		addVariantHeaders(&request)

		self.transport.send(request: request, resultType: ReaderAPIReferenceWrapper.self) { result in
			switch result {
			case .success(let (_, entries)):
				guard let entriesItemRefs = entries?.itemRefs, entriesItemRefs.count > 0 else {
					self.retrieveItemIDs(type: type, url: callURL, dateInfo: dateInfo, itemIDs: itemIDs, continuation: entries?.continuation, completion: completion)
					return
				}
				var totalItemIDs = itemIDs
				totalItemIDs.append(contentsOf: entriesItemRefs.compactMap { $0.itemId })
				self.retrieveItemIDs(type: type, url: callURL, dateInfo: dateInfo, itemIDs: totalItemIDs, continuation: entries?.continuation, completion: completion)
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	func createUnreadEntries(entries: [String], completion: @escaping (Result<Void, Error>) -> Void) {
		updateStateToEntries(entries: entries, state: .read, add: false, completion: completion)
	}

	func deleteUnreadEntries(entries: [String], completion: @escaping (Result<Void, Error>) -> Void) {
		updateStateToEntries(entries: entries, state: .read, add: true, completion: completion)
	}

	func createStarredEntries(entries: [String], completion: @escaping (Result<Void, Error>) -> Void) {
		updateStateToEntries(entries: entries, state: .starred, add: true, completion: completion)
	}

	func deleteStarredEntries(entries: [String], completion: @escaping (Result<Void, Error>) -> Void) {
		updateStateToEntries(entries: entries, state: .starred, add: false, completion: completion)
	}

}

// MARK: Private

private extension ReaderAPICaller {

	func encodeForURLPath(_ pathComponent: String?) -> String? {
		guard let pathComponent = pathComponent else { return nil }
		return pathComponent.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed)
	}

	func addVariantHeaders(_ request: inout URLRequest) {
		if variant == .inoreader {
			request.addValue(SecretKey.inoreaderAppID, forHTTPHeaderField: "AppId")
			request.addValue(SecretKey.inoreaderAppKey, forHTTPHeaderField: "AppKey")
		}
	}

	private func updateStateToEntries(entries: [String], state: ReaderState, add: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let baseURL = apiBaseURL else {
			completion(.failure(CredentialsError.incompleteCredentials))
			return
		}

		self.requestAuthorizationToken(endpoint: baseURL) { (result) in
			switch result {
			case .success(let token):
				// Do POST asking for data about all the new articles
				var request = URLRequest(url: baseURL.appendingPathComponent(ReaderAPIEndpoints.editTag.rawValue), credentials: self.credentials)
				self.addVariantHeaders(&request)
				request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
				request.httpMethod = "POST"

				// Get ids from above into hex representation of value
				let idsToFetch = entries.compactMap({ idValue -> String? in
					if self.variant == .theOldReader {
						return "i=tag:google.com,2005:reader/item/\(idValue)"
					} else {
						guard let intValue = Int(idValue) else { return nil }
						let idHexString = String(format: "%.16llx", intValue)
						return "i=tag:google.com,2005:reader/item/\(idHexString)"
					}
				}).joined(separator: "&")

				let actionIndicator = add ? "a" : "r"

				let postDataString = "T=\(token)&\(idsToFetch)&\(actionIndicator)=\(state.rawValue)"
				let postData = Data(postDataString.utf8)

				self.transport.send(request: request, method: HTTPMethod.post, payload: postData, completion: { (result) in
					switch result {
					case .success:
						completion(.success(()))
					case .failure(let error):
						completion(.failure(error))
					}
				})

			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

}
