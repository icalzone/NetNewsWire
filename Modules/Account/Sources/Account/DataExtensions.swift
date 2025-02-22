//
//  DataExtensions.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 10/7/17.
//  Copyright © 2017 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import Articles
import Parser

public extension Notification.Name {
	static let feedSettingDidChange = Notification.Name(rawValue: "FeedSettingDidChangeNotification")
}

public extension Feed {

	static let FeedSettingUserInfoKey = "feedSetting"

	struct FeedSettingKey {
		public static let homePageURL = "homePageURL"
		public static let iconURL = "iconURL"
		public static let faviconURL = "faviconURL"
		public static let name = "name"
		public static let editedName = "editedName"
		public static let authors = "authors"
		public static let contentHash = "contentHash"
		public static let conditionalGetInfo = "conditionalGetInfo"
		public static let cacheControlInfo = "cacheControlInfo"
	}
}

extension Feed {

	func takeSettings(from parsedFeed: ParsedFeed) {
		iconURL = parsedFeed.iconURL
		faviconURL = parsedFeed.faviconURL
		homePageURL = parsedFeed.homePageURL
		name = parsedFeed.title
		authors = Author.authorsWithParsedAuthors(parsedFeed.authors)
	}

	func postFeedSettingDidChangeNotification(_ codingKey: FeedMetadata.CodingKeys) {
		let userInfo = [Feed.FeedSettingUserInfoKey: codingKey.stringValue]
		NotificationCenter.default.post(name: .feedSettingDidChange, object: self, userInfo: userInfo)
	}
}

public extension Article {

	var account: Account? {
		AccountManager.shared.existingAccount(with: accountID)
	}

	var feed: Feed? {
		return account?.existingFeed(withFeedID: feedID)
	}
}
