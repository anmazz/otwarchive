class UserMailer < ApplicationMailer
  helper_method :current_user
  helper_method :current_admin
  helper_method :logged_in?
  helper_method :logged_in_as_admin?

  helper :application
  helper :tags
  helper :works
  helper :users
  helper :date
  helper :series
  include HtmlCleaner

  # Send an email letting a creator know that their work has been added to a collection by an archivist
  def archivist_added_to_collection_notification(user_id, work_id, collection_id)
    @user = User.find(user_id)
    @work = Work.find(work_id)
    @collection = Collection.find(collection_id)
    mail(
      to: @user.email,
      subject: t(".subject", app_name: ArchiveConfig.APP_SHORT_NAME, collection_title: @collection.title)
    )
  end

  # Send a request to a work owner asking that they approve the inclusion
  # of their work in a collection
  def invited_to_collection_notification(user_id, work_id, collection_id)
    @user = User.find(user_id)
    @work = Work.find(work_id)
    @collection = Collection.find(collection_id)
    mail(
      to: @user.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME, collection_title: @collection.title)
       )
  end

  # We use an options hash here, instead of keyword arguments, to avoid
  # compatibility issues with resque/resque_mailer.
  def anonymous_or_unrevealed_notification(user_id, work_id, collection_id, options = {})
    options = options.with_indifferent_access

    @becoming_anonymous = options.fetch(:anonymous, false)
    @becoming_unrevealed = options.fetch(:unrevealed, false)

    return unless @becoming_anonymous || @becoming_unrevealed

    @user = User.find(user_id)
    @work = Work.find(work_id)
    @collection = Collection.find(collection_id)

    # Symbol used to pick the appropriate translation string:
    @status = if @becoming_anonymous && @becoming_unrevealed
                :anonymous_unrevealed
              elsif @becoming_anonymous
                :anonymous
              else
                :unrevealed
              end
    mail(
      to: @user.email,
      subject: t(".subject.#{@status}", app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  # Sends an invitation to join the archive
  # Must be sent synchronously as it is rescued
  # TODO refactor to make it asynchronous
  def invitation(invitation_id)
    @invitation = Invitation.find(invitation_id)
    @user_name = (@invitation.creator.is_a?(User) ? @invitation.creator.login : "")
    mail(
      to: @invitation.invitee_email,
      subject: t("user_mailer.invitation.subject", app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  # Sends an invitation to join the archive and claim stories that have been imported as part of a bulk import
  def invitation_to_claim(invitation_id, archivist_login)
    @invitation = Invitation.find(invitation_id)
    @external_author = @invitation.external_author
    @archivist = archivist_login || "An archivist"
    @token = @invitation.token
    mail(
      to: @invitation.invitee_email,
      subject: t("user_mailer.invitation_to_claim.subject", app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  # Notifies a writer that their imported works have been claimed
  def claim_notification(creator_id, claimed_work_ids)
    creator = User.find(creator_id)
    @external_email = creator.email
    @claimed_works = Work.where(id: claimed_work_ids)
    mail(
      to: creator.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  # Sends a batched subscription notification
  def batch_subscription_notification(subscription_id, entries)
    # Here we use find_by_id so that if the subscription is not found
    # then the resque job does not error and we just silently fail.
    @subscription = Subscription.find_by(id: subscription_id)
    return if @subscription.nil?

    creation_entries = JSON.parse(entries)
    @creations = []
    # look up all the creations that have generated updates for this subscription
    creation_entries.each do |creation_info|
      creation_type, creation_id = creation_info.split("_")
      creation = creation_type.constantize.where(id: creation_id).first
      next unless creation && creation.try(:posted)
      next if creation.is_a?(Chapter) && !creation.work.try(:posted)
      next if creation.try(:hidden_by_admin) || (creation.is_a?(Chapter) && creation.work.try(:hidden_by_admin))
      next if creation.pseuds.any? { |p| p.user == User.orphan_account } # no notifications for orphan works

      # TODO: allow subscriptions to orphan_account to receive notifications

      # If the subscription notification is for a user subscription, we don't
      # want to send updates about works that have recently become anonymous.
      if @subscription.subscribable_type == "User"
        next if Subscription.anonymous_creation?(creation)
      end

      @creations << creation
    end

    return if @creations.empty?

    # make sure we only notify once per creation
    @creations.uniq!

    subject = @subscription.subject_text(@creations.first)
    subject += " and #{@creations.count - 1} more" if @creations.count > 1
    I18n.with_locale(@subscription.user.preference.locale_for_mails) do
      mail(
        to: @subscription.user.email,
        subject: "[#{ArchiveConfig.APP_SHORT_NAME}] #{subject}"
      )
    end
  end

  # Emails a user to say they have been given more invitations for their friends
  def invite_increase_notification(user_id, total)
    @user = User.find(user_id)
    @total = total
    mail(
      to: @user.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  # Emails a user to say that their request for invitation codes has been declined
  def invite_request_declined(user_id, total, reason)
    @user = User.find(user_id)
    @total = total
    @reason = reason
    mail(
      to: @user.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  def collection_notification(collection_id, subject, message, email)
    @message = message
    @collection = Collection.find(collection_id)
    mail(
      to: email,
      subject: "[#{ArchiveConfig.APP_SHORT_NAME}][#{@collection.title}] #{subject}"
    )
  end

  def invalid_signup_notification(collection_id, invalid_signup_ids, email)
    @collection = Collection.find(collection_id)
    @invalid_signups = invalid_signup_ids
    @is_collection_email = (email == @collection.collection_email)
    mail(
      to: email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME, collection_title: @collection.title)
    )
  end

  # This is sent at the end of matching, i.e., after assignments are generated.
  # It is also sent when assignments are regenerated.
  def potential_match_generation_notification(collection_id, email)
    @collection = Collection.find(collection_id)
    @is_collection_email = (email == @collection.collection_email)
    mail(
      to: email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME, collection_title: @collection.title)
    )
  end

  def challenge_assignment_notification(collection_id, assigned_user_id, assignment_id)
    @collection = Collection.find(collection_id)
    @assigned_user = User.find(assigned_user_id)
    @assignment = ChallengeAssignment.find(assignment_id)
    @request = @assignment.request_signup
    mail(
      to: @assigned_user.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME, collection_title: @collection.title)
    )
  end

  # Asks a user to validate and activate their new account
  def signup_notification(user_id)
    @user = User.find(user_id)
    I18n.with_locale(@user.preference.locale_for_mails) do
      mail(
        to: @user.email,
        subject: t("user_mailer.signup_notification.subject", app_name: ArchiveConfig.APP_SHORT_NAME)
      )
    end
  end

  # Confirms to a user that their email was changed
  def change_email(user_id, old_email, new_email)
    @user = User.find(user_id)
    @old_email = old_email
    @new_email = new_email
    @pac_footer = true
    mail(
      to: @old_email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  def change_username(user, old_username)
    @user = user
    @old_username = old_username
    @new_username = user.login
    @next_change_time = user.renamed_at + ArchiveConfig.USER_RENAME_LIMIT_DAYS.days
    mail(
      to: @user.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  ### WORKS NOTIFICATIONS ###

  # Sends email when an archivist adds someone as a co-creator.
  def creatorship_notification_archivist(creatorship_id, archivist_id)
    @creatorship = Creatorship.find(creatorship_id)
    @archivist = User.find(archivist_id)
    @user = @creatorship.pseud.user
    @creation = @creatorship.creation
    mail(
      to: @user.email,
      subject: t("user_mailer.creatorship_notification_archivist.subject",
                 app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  # Sends email when a user is added as a co-creator
  def creatorship_notification(creatorship_id, adding_user_id)
    @creatorship = Creatorship.find(creatorship_id)
    @adding_user = User.find(adding_user_id)
    @user = @creatorship.pseud.user
    @creation = @creatorship.creation
    mail(
      to: @user.email,
      subject: t("user_mailer.creatorship_notification.subject",
                 app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  # Sends email when a user is added as an unapproved/pending co-creator
  def creatorship_request(creatorship_id, inviting_user_id)
    @creatorship = Creatorship.find(creatorship_id)
    @inviting_user = User.find(inviting_user_id)
    @user = @creatorship.pseud.user
    @creation = @creatorship.creation
    mail(
      to: @user.email,
      subject: t("user_mailer.creatorship_request.subject",
                 app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  # Sends emails to creators whose stories were listed as the inspiration of another work
  def related_work_notification(user_id, related_work_id)
    @user = User.find(user_id)
    @related_work = RelatedWork.find(related_work_id)
    @related_parent_link = url_for(controller: :works, action: :show, id: @related_work.parent)
    @related_child_link = url_for(controller: :works, action: :show, id: @related_work.work)
    mail(
      to: @user.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  # Emails a recipient to say that a gift has been posted for them
  def recipient_notification(user_id, work_id, collection_id = nil)
    @user = User.find(user_id)
    @work = Work.find(work_id)
    @collection = Collection.find(collection_id) if collection_id
    subject = if @collection
                t("user_mailer.recipient_notification.subject.collection",
                  app_name: ArchiveConfig.APP_SHORT_NAME,
                  collection_title: @collection.title)
              else
                t("user_mailer.recipient_notification.subject.no_collection",
                  app_name: ArchiveConfig.APP_SHORT_NAME)
              end
    mail(
      to: @user.email,
      subject: subject
    )
  end

  # Emails a prompter to say that a response has been posted to their prompt
  def prompter_notification(work_id, collection_id = nil)
    @work = Work.find(work_id)
    @collection = Collection.find(collection_id) if collection_id
    @work.challenge_claims.each do |claim|
      user = User.find(claim.request_signup.pseud.user.id)
      I18n.with_locale(user.preference.locale_for_mails) do
        mail(
          to: user.email,
          subject: "[#{ArchiveConfig.APP_SHORT_NAME}] A response to your prompt"
        )
      end
    end
  end

  # Sends email to creators when a creation is deleted
  # NOTE: this must be sent synchronously! otherwise the work will no longer be there to send
  # TODO refactor to make it asynchronous by passing the content in the method
  def delete_work_notification(user, work, deleter)
    @user = user
    @work = work
    @deleter = deleter
    download = Download.new(@work, mime_type: "text/html", include_draft_chapters: true)
    html = DownloadWriter.new(download).generate_html
    html = ::Mail::Encodings::Base64.encode(html)
    attachments["#{download.file_name}.html"] = { content: html, encoding: "base64" }
    attachments["#{download.file_name}.txt"] = { content: html, encoding: "base64" }

    mail(
      to: user.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  # Sends email to creators when a creation is deleted by an admin
  # NOTE: this must be sent synchronously! otherwise the work will no longer be there to send
  # TODO refactor to make it asynchronous by passing the content in the method
  def admin_deleted_work_notification(user, work)
    @user = user
    @work = work
    download = Download.new(@work, mime_type: "text/html", include_draft_chapters: true)
    html = DownloadWriter.new(download).generate_html
    html = ::Mail::Encodings::Base64.encode(html)
    attachments["#{download.file_name}.html"] = { content: html, encoding: "base64" }
    attachments["#{download.file_name}.txt"] = { content: html, encoding: "base64" }
    
    mail(
        to: user.email,
        subject: t("user_mailer.admin_deleted_work_notification.subject", app_name: ArchiveConfig.APP_SHORT_NAME)
      )
  end

  # Sends email to creators when a creation is hidden by an admin
  def admin_hidden_work_notification(creation_ids, user_id)
    @pac_footer = true
    @user = User.find_by(id: user_id)
    @works = Work.where(id: creation_ids)
    return if @works.empty?

    mail(
      to: @user.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME, count: @works.size)
    )
  end

  def admin_spam_work_notification(creation_id, user_id)
    @user = User.find_by(id: user_id)
    @work = Work.find_by(id: creation_id)

    mail(
      to: @user.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME)
    )
  end

  ### OTHER NOTIFICATIONS ###

  # archive feedback
  def feedback(feedback_id)
    feedback = Feedback.find(feedback_id)
    return unless feedback.email

    @summary = feedback.summary
    @comment = feedback.comment
    @username = feedback.username if feedback.username.present?
    @language = feedback.language
    mail(
      to: feedback.email,
      subject: default_i18n_subject(app_name: ArchiveConfig.APP_SHORT_NAME, summary: strip_html_breaks_simple(feedback.summary))
    )
  end

  def abuse_report(abuse_report_id)
    abuse_report = AbuseReport.find(abuse_report_id)
    @username = abuse_report.username
    @email = abuse_report.email
    @url = abuse_report.url
    @summary = abuse_report.summary
    @comment = abuse_report.comment
    mail(
      to: abuse_report.email,
      subject: t("user_mailer.abuse_report.subject", app_name: ArchiveConfig.APP_SHORT_NAME, summary: strip_html_breaks_simple(@summary))
    )
  end
end
