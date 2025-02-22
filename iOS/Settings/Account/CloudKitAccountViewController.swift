//
//  CloudKitAccountViewController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 3/28/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import UIKit
import SafariServices
import Account

enum CloudKitAccountViewControllerError: LocalizedError {
	case iCloudDriveMissing

	var errorDescription: String? {
		return NSLocalizedString("Unable to add iCloud Account. Please make sure you have iCloud and iCloud Drive enabled in System Settings.", comment: "Unable to add iCloud Account.")
	}
}

final class CloudKitAccountViewController: UITableViewController {

	weak var delegate: AddAccountDismissDelegate?
	@IBOutlet weak var footerLabel: UILabel!

	override func viewDidLoad() {
		super.viewDidLoad()
		setupFooter()

		tableView.register(ImageHeaderView.self, forHeaderFooterViewReuseIdentifier: "SectionHeader")
	}

	private func setupFooter() {
		footerLabel.text = NSLocalizedString("NetNewsWire will use your iCloud account to sync your subscriptions across your Mac and iOS devices.", comment: "iCloud")
	}

	@IBAction func cancel(_ sender: Any) {
		dismiss(animated: true, completion: nil)
		delegate?.dismiss()
	}

	@IBAction func add(_ sender: Any) {
		guard FileManager.default.ubiquityIdentityToken != nil else {
			presentError(CloudKitAccountViewControllerError.iCloudDriveMissing)
			return
		}

		_ = AccountManager.shared.createAccount(type: .cloudKit)
		dismiss(animated: true, completion: nil)
		delegate?.dismiss()
	}

	override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
		return section == 0 ? ImageHeaderView.rowHeight : super.tableView(tableView, heightForHeaderInSection: section)
	}

	override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
		if section == 0 {
			let headerView = tableView.dequeueReusableHeaderFooterView(withIdentifier: "SectionHeader") as! ImageHeaderView
			headerView.imageView.image = AppImage.account(.cloudKit)
			return headerView
		} else {
			return super.tableView(tableView, viewForHeaderInSection: section)
		}
	}

	@IBAction func openLimitationsAndSolutions(_ sender: Any) {
		let vc = SFSafariViewController(url: CloudKitWebDocumentation.limitationsAndSolutionsURL)
		vc.modalPresentationStyle = .pageSheet
		present(vc, animated: true)
	}
}
