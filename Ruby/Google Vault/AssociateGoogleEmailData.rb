# Menu Title: Associate Google Email Data
# Needs Case: true
# Needs Selected Items: false

# Define the date time format used to convert "Tag" nodes with a "TagDataType" of "DateTime"
# to an actual Joda DateTime object before storing as custom metadata
# http://joda-time.sourceforge.net/apidocs/org/joda/time/format/DateTimeFormat.html
date_time_format_pattern = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"

script_directory = File.dirname(__FILE__)

# Load JAR with dialogs classes
require File.join(script_directory,"Nx.jar")
java_import "com.nuix.nx.NuixConnection"
java_import "com.nuix.nx.LookAndFeelHelper"
java_import "com.nuix.nx.dialogs.ChoiceDialog"
java_import "com.nuix.nx.dialogs.TabbedCustomDialog"
java_import "com.nuix.nx.dialogs.CommonDialogs"
java_import "com.nuix.nx.dialogs.ProgressDialog"
LookAndFeelHelper.setWindowsIfMetal
NuixConnection.setUtilities($utilities)
NuixConnection.setCurrentNuixVersion(NUIX_VERSION)

# Load classes for parsing MBOX and XML
load File.join(script_directory,"GoogleMboxXref.rb_")
load File.join(script_directory,"GoogleXmlObjects.rb_")
# Load logging class
load File.join(script_directory,"Logger.rb_")

# We will need this to parse the DateTime values from the XML
java_import "org.joda.time.format.DateTimeFormat"

# If user has selected some MBOX files, lets update only the emails of those MBOX items.  We will only
# generate the XREF data for those select MBOX, and only then if we're in a version of Nuix pre 7.4
selected_mbox_items = []
if $current_selected_items.nil? == false && $current_selected_items.size > 0
	selected_mbox_items = $current_selected_items.select{|i| i.getType.getName == "application/mbox"}
end

# Build settings dialog
dialog = TabbedCustomDialog.new("Associate Google Email Data")
main_tab = dialog.addTab("main_tab","Main")
if selected_mbox_items.size > 0
	main_tab.appendHeader("Processing only emails of #{selected_mbox_items.size} selected MBOX items")
end
main_tab.appendCheckBox("apply_label_tags","Apply Tags for GMail Labels",true)
main_tab.appendTextField("tag_prefix","Gmail Label Tag Prefix","GMailLabels")
main_tab.enabledOnlyWhenChecked("tag_prefix","apply_label_tags")
main_tab.appendDirectoryChooser("log_directory","Log Directory")
main_tab.appendHeader("XML Files")
main_tab.appendPathList("xml_file_paths")
main_tab.getControl("xml_file_paths").setDirectoriesButtonVisible(false)
main_tab.appendCheckBox("data_is_pre_74","MBOX was processed pre Nuix 7.4",false)

# Define some settings validations
dialog.validateBeforeClosing do |values|
	# Validate provided paths
	if values["xml_file_paths"].size < 1
		CommonDialogs.showWarning("Please select at least one XML file.")
		next false
	else
		values["xml_file_paths"].each do |xml_file_path|
			invalid_paths = []
			if !java.io.File.new(xml_file_path).exists
				invalid_paths << xml_file_path
			end
			if invalid_paths.size > 0
				CommonDialogs.showWarning("#{invalid_paths.size} XML file paths are invalid:\n#{invalid_paths.take(10).join("\n")}\n#{invalid_paths.size > 10 ? "..." : ""}")
				next false
			end
		end
	end

	# Validate log directory was provided
	if values["log_directory"].strip.empty?
		CommonDialogs.showWarning("Please provide a non-empty value for 'Log Directory'.")
		next false
	end

	# Get user confirmation about closing all workbench tabs
	if CommonDialogs.getConfirmation("The script needs to close all workbench tabs, proceed?") == false
		next false
	end
	next true
end

# Display settings dialog
dialog.display

# User hit okay, validations passed, lets do this!
if dialog.getDialogResult == true
	# Applying custom metadata via script in GUI can cause errors so we close
	# all workbench tabs to prevent them
	$window.closeAllTabs

	# Build pattern for parsing DateTime values in "Tag" nodes
	date_time_format = DateTimeFormat.forPattern(date_time_format_pattern)

	# Load dialog settings
	values = dialog.toMap
	tag_prefix = values["tag_prefix"]
	xml_file_paths = values["xml_file_paths"]
	apply_label_tags = values["apply_label_tags"]
	data_is_pre_74 = values["data_is_pre_74"]

	# Track errors, warnings, successes and start time
	error_count = 0
	warning_count = 0
	match_count = 0
	skipped_attached_email_count = 0
	start_time = Time.now

	# Show progress dialog while we do some work
	ProgressDialog.forBlock do |pd|
		pd.setTitle("Associate Google Email Data")
		pd.setSubStatus("Errors: #{error_count}, Warnings: #{warning_count}, Matches: #{match_count}, Skipped Attached Emails: #{skipped_attached_email_count}")

		# Setup logging
		timestamp = Time.now.strftime("%Y%m%d_%H-%M-%S")
		if !java.io.File.new(values["log_directory"]).exists
			java.io.File.new(values["log_directory"]).mkdirs
		end
		log_file_path = "#{timestamp}_AssociateGoogleEmailDataLog.txt"
		log_file_path = File.join(values["log_directory"],log_file_path)
		pd.logMessage("Logging output to: #{log_file_path}")
		Logger.log_file = log_file_path
		pd.onMessageLogged do |message|
			Logger.log(message)
		end

		xref_csv_path = "#{timestamp}_AssociateGoogleEmailDataXref.csv"
		xref_csv_path = File.join(values["log_directory"],xref_csv_path)

		status_csv_path = "#{timestamp}_AssociateGoogleEmailDataPerItemStatus.csv"
		status_csv_path = File.join(values["log_directory"],status_csv_path)

		# Parse 'Document' nodes from XML files user specified
		pd.setMainStatusAndLogIt("Parsing XML files...")
		data = GoogleXmlData.new
		xml_file_paths.each do |xml_file_path|
			pd.logMessage("Parsing: #{xml_file_path}")
			begin
				data.parse_xml_file(xml_file_path)
			rescue Exception => exc
				pd.logMessage("!!! Error while parsing XML file '#{xml_file_path}':")
				pd.logMessage(exc.message)
				error_count += 1
				pd.setSubStatus("Errors: #{error_count}, Warnings: #{warning_count}, Matches: #{match_count}, Skipped Attached Emails: #{skipped_attached_email_count}")
			end
		end

		pd.logMessage("Total Document Nodes Parsed: #{data.total_documents}")
		pd.logMessage("Distinct 'TagName' Values:")
		data.distinct_tag_names.each do |name|
			pd.logMessage("\t#{name}")
		end

		# Build hash for quick lookup of XML entries
		pd.setMainStatusAndLogIt("Indexing XML Data...")
		external_filename_lookup = {}
		data.each_document do |document|
			external_filename_lookup[document.external_file_name] = document
		end

		# Nuix 7.4 captures "From" property, eliminating the need to parse the MBOX anymore, so
		# we check if this is Nuix 7.4 or above and skip all the MBOX xref stuff if we can
		nuix_7dot4_or_above = NuixConnection.getCurrentNuixVersion.isAtLeast("7.4")

		if nuix_7dot4_or_above
			pd.logMessage("Detected Nuix 7.4 or higher")
		end

		# Added a checkbox allowing the user to force the script to use the old logic for
		# instances where they may have processed the data in a version of Nuix prior to 7.4
		# but then run this script against that data in 7.4 or higher.  When this is the case
		# were going to set nuix_7dot4_or_above to false so the old logic is used.
		if data_is_pre_74
			nuix_7dot4_or_above = false
			pd.logMessage("Forcing script to use old technique for data processed pre Nuix 7.4")
		end

		mbox_items = []
		if nuix_7dot4_or_above
			pd.setMainStatusAndLogIt("Nuix 7.4 or higher detected, skipping step building Xref from MBOX Files...")
		else
			# Locate MBOX items so we may parse out XREF data to connect them with XML entries
			# We are looking specifically for the "From_" MBOX header which basically acts as an
			# email boundary.  For each email we also located the associated "Message-ID".
			# Google value metadata XML contains data in the "From_" header so we can use as XREF
			# from XML to "Message-ID" Nuix captured as metadata for emails
			pd.setMainStatusAndLogIt("Extracting Xref from MBOX Files...")
			xref = GoogleMboxXref.new
			mbox_items = []
			if selected_mbox_items.size > 0
				mbox_items = selected_mbox_items
			else
				mbox_items = $current_case.search("mime-type:\"application/mbox\"")
			end
		end

		if mbox_items.size < 1 && !nuix_7dot4_or_above
			pd.logMessage("Case contains no MBOX (application/mbox) items")
			pd.setMainStatusAndLogIt("Completed #{Time.at(Time.now - start_time).gmtime.strftime("%H:%M:%S")}")
			pd.setMainProgress(1,1)
			warning_count += 1
			pd.setSubStatus("Errors: #{error_count}, Warnings: #{warning_count}, Matches: #{match_count}, Skipped Attached Emails: #{skipped_attached_email_count}")
		else
			# Only need to do this for data processed in Nuix before 7.4
			if !nuix_7dot4_or_above
				pd.setMainProgress(0,mbox_items.size)
				mbox_items.each_with_index do |mbox_item,mbox_index|
					pd.setMainProgress(mbox_index+1)
					begin
						pd.logMessage("  Processing MBOX: #{mbox_item.getName}")
						xref.build_xref(mbox_item)
					rescue Exception => exc
						pd.logMessage("!!! Error while parsing MBOX '#{mbox_item.getName}':")
						pd.logMessage(exc.message)
						pd.logMessage(exc.backtrace.join("\n"))
						error_count += 1
						pd.setSubStatus("Errors: #{error_count}, Warnings: #{warning_count}, Matches: #{match_count}, Skipped Attached Emails: #{skipped_attached_email_count}")
					end
				end
				pd.logMessage("MBox Xref Records Found: #{xref.size}")

				# Save the From_ to Message-ID xref data to CSV
				pd.logMessage("Saving Xref CSV: #{xref_csv_path}")
				xref.save_csv(xref_csv_path)
			end

			# Regex we will use to get from identifier we need from property "MBOX From Line" if we are in Nuix 7.4 or higher
			from_regex = /^From ([0-9]+-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.mbox).*$/


			# We are going to group matches items by the labels associated to those
			# items in the XML file.  We group them up so we can tag in batches
			grouped_by_label = Hash.new{|h,k|h[k]=[]}

			# Get the emails we will be updating.  If spefic MBOX items were selected at the beginning only process their emails
			# otherwise we just going to try and process all emails in the case
			email_items = []
			if selected_mbox_items.size > 0
				path_guids = selected_mbox_items.map{|i|i.getGuid}
				selected_mbox_email_query = "path-guid:(#{path_guids.join(" OR ")}) AND kind:email"
				pd.logMessage("Query: #{selected_mbox_email_query}")
				pd.setMainStatusAndLogIt("Finding Email Items for #{selected_mbox_items.size} selected MBOX items...")
				email_items = $current_case.search(selected_mbox_email_query)
			else
				pd.setMainStatusAndLogIt("Finding Email Items...")
				email_items = $current_case.search("kind:email")
			end
			pd.logMessage("Email Item Count: #{email_items.size}")
			pd.setMainProgress(0,email_items.size)

			# Iterate each email item and attempt to match it against our XREF
			CSV.open(status_csv_path,"w:utf-8") do |csv|
				csv << [
					"Item GUID",
					"Item Name",
					"Item Message ID",
					"Resolved From Line",
					"Success",
					"Issue Message"
				]

				email_items.each_with_index do |item,item_index|
					status_entry = {
						:message_id => "",
						:from_line => "",
						:item_success => false,
						:issue_message => "",
					}

					pd.setMainProgress(item_index+1)
					item_properties = item.getProperties
					message_id = item_properties["Message-ID"]
					status_entry[:message_id] = message_id || "No Message ID Property"
					if message_id.nil?
						# Somehow email did not have a "Message-ID" property so we cannot match it
						status_entry[:issue_message] = "!!! WARNING: Skipping item without 'Message-ID': #{item.getGuid}"
						pd.logMessage(status_entry[:issue_message])
						warning_count += 1
						pd.setSubStatus("Errors: #{error_count}, Warnings: #{warning_count}, Matches: #{match_count}, Skipped Attached Emails: #{skipped_attached_email_count}")
					else
						from_id = ""
						# Only use XREF in versions < Nuix 7.4, data processed in a version after that should have this as a property named "MBOX From Line"
						if nuix_7dot4_or_above
							mbox_from_line = item_properties["MBOX From Line"]
							if mbox_from_line.nil? || mbox_from_line.strip.empty?
								status_entry[:issue_message] = "!!! WARNING: Skipping item without 'MBOX From Line' property: #{item.getGuid}, data may have been processed in version before 7.4"
								pd.logMessage(status_entry[:issue_message])
								warning_count += 1
								# Record per item status results for this item
								csv << [
									item.getGuid,
									item.getLocalisedName,
									status_entry[:message_id],
									status_entry[:from_line],
									status_entry[:item_success],
									status_entry[:issue_message],
								]
								# Get iterator to move on to next item
								next
							else
								# From line captured by Nuix has a bit more than we need so we get just the part relevant from it
								from_id = mbox_from_line.gsub(from_regex,"\\1").strip
							end
						else
							from_id = xref.from_id_for_message_id(message_id)
						end
						status_entry[:from_line] = from_id || "Unable to resolve From line"
						if from_id.nil?
							# Looks like XREF did not have an entry for this "Message-ID"
							if item.isTopLevel == false
								status_entry[:issue_message] = "*** Skipping attached email item without associated MBOX id"
								pd.logMessage(status_entry[:issue_message])
								pd.logMessage("\tGUID: #{item.getGuid}")
								pd.logMessage("\tMessage-ID: #{message_id}")
								skipped_attached_email_count += 1
								pd.setSubStatus("Errors: #{error_count}, Warnings: #{warning_count}, Matches: #{match_count}, Skipped Attached Emails: #{skipped_attached_email_count}")
							else
								status_entry[:issue_message] = "!!! WARNING: Skipping item without associated MBOX id"
								pd.logMessage(status_entry[:issue_message])
								pd.logMessage("\tGUID: #{item.getGuid}")
								pd.logMessage("\tMessage-ID: #{message_id}")
								warning_count += 1
								pd.setSubStatus("Errors: #{error_count}, Warnings: #{warning_count}, Matches: #{match_count}, Skipped Attached Emails: #{skipped_attached_email_count}")
							end
						else
							document = external_filename_lookup[from_id]
							if !document.nil?
								# We were able to correlate this email to its entry in the XML data
								match_count += 1
								status_entry[:item_success] = true
								pd.setSubStatus("Errors: #{error_count}, Warnings: #{warning_count}, Matches: #{match_count}, Skipped Attached Emails: #{skipped_attached_email_count}")
								
								# Group item by labels associated in XML data
								labels = document.labels
								labels.each do |label|
									grouped_by_label[label] << item
								end

								# Record XML file we used to associate this record as custom metadata
								item.getCustomMetadata["XmlExternalFileName"] = from_id
								# Record XML "Tag" data as custom metadata
								document.annotate_item(item,date_time_format)
							else
								status_entry[:issue_message] = "!!! WARNING: Skipping item without associated XML file"
								pd.logMessage(status_entry[:issue_message])
								pd.logMessage("\tGUID: #{item.getGuid}")
								pd.logMessage("\tMessage-ID: #{message_id}")
								warning_count += 1
								pd.setSubStatus("Errors: #{error_count}, Warnings: #{warning_count}, Matches: #{match_count}, Skipped Attached Emails: #{skipped_attached_email_count}")
							end
						end
					end
					# Record per item status results for this item
					csv << [
						item.getGuid,
						item.getLocalisedName,
						status_entry[:message_id],
						status_entry[:from_line],
						status_entry[:item_success],
						status_entry[:issue_message],
					]
				end
			end
			pd.logMessage("Matched Email Items: #{match_count}")

			# Apply labels as tags using groups so we perform fewer tagging operations
			if apply_label_tags
				pd.setMainStatusAndLogIt("Applying Labels as Tags...")
				annotater = $utilities.getBulkAnnotater
				grouped_by_label.each do |label,items|
					tag = "#{tag_prefix}|#{label}"
					pd.logMessage("\tApplying label '#{label}' as tag '#{tag}' to #{items.size} items...")
					annotater.addTag(tag,items)
				end
			end

			# We are done!
			pd.setMainStatusAndLogIt("Completed #{Time.at(Time.now - start_time).gmtime.strftime("%H:%M:%S")}")
			pd.setMainProgress(1,1)
			pd.setSubStatusAndLogIt("Errors: #{error_count}, Warnings: #{warning_count}, Matches: #{match_count}, Skipped Attached Emails: #{skipped_attached_email_count}")

			$window.openTab("workbench",{:search=>""})
		end
	end
end