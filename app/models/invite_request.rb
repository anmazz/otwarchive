class InviteRequest < ApplicationRecord
  validates :email, presence: true, email_format: true
  validates :email, uniqueness: { message: "is already part of our queue." }
  before_validation :compare_with_users, on: :create
  before_validation :set_simplified_email, on: :create
  validate :simplified_email_uniqueness, on: :create

  # Borrow the blacklist cleaner but just strip out all the periods for all domains
  def set_simplified_email
    return if email.blank?
    simplified = AdminBlacklistedEmail.canonical_email(email).split('@')
    self.simplified_email = simplified.first.delete(".").gsub(/\+.+$/, "") + "@#{simplified.last}"
  end

  # Doing this with a method so the error message makes more sense
  def simplified_email_uniqueness
    # Exit if raw email uniqueness error already exists
    return if errors.of_kind?(:email, :taken)

    if InviteRequest.where(simplified_email: simplified_email).exists?
      errors.add(:email, "is already part of our queue.")
    end
  end

  def proposed_fill_time
    admin_settings = AdminSetting.current
    number_of_rounds = (self.position.to_f/admin_settings.invite_from_queue_number.to_f).ceil - 1
    proposed_time = admin_settings.invite_from_queue_at + (admin_settings.invite_from_queue_frequency * number_of_rounds).hours
    Time.current > proposed_time ? Time.current : proposed_time
  end

  def position
    InviteRequest.where("id <= ?", id).count
  end

  #Ensure that invite request is for a new user
  def compare_with_users
    if User.find_by(email: self.email)
      errors.add(:email, "is already being used by an account holder.")
      throw :abort
    end
  end

  #Turn a request into an invite and then remove it from the queue
  def invite_and_remove(creator=nil)
    invitation = creator ? creator.invitations.build(invitee_email: self.email, from_queue: true) :
                                       Invitation.new(invitee_email: self.email, from_queue: true)
    if invitation.save
      self.destroy
    end
  end
end
