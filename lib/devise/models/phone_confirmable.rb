module Devise
  module Models
    # Confirmable is responsible to verify if an account is already confirmed to
    # sign in, and to send phones with confirmation instructions.
    # Confirmation instructions are sent to the user phone after creating a
    # record and when manually requested by a new confirmation instruction request.
    #
    # Confirmable tracks the following columns:
    #
    # * phone_confirmation_token   - A unique random token
    # * phone_confirmed_at         - A timestamp when the user clicked the confirmation link
    # * phone_confirmation_sent_at - A timestamp when the phone_confirmation_token was generated (not sent)
    # * unconfirmed_phone    - An phone address copied from the phone attr. After confirmation
    #                          this value is copied to the phone attr then cleared
    #
    # == Options
    #
    # PhoneConfirmable adds the following options to +magic+:
    #
    #   * +allow_unconfirmed_phone_access_for+: the time you want to allow the user to access their account
    #     before confirming it. After this period, the user access is denied. You can
    #     use this to let your user access some features of your application without
    #     confirming the account, but blocking it after a certain period (ie 7 days).
    #     By default allow_unconfirmed_phone_access_for is zero, it means users always have to confirm to sign in.
    #   * +phone_reconfirmable+: requires any phone changes to be confirmed (exactly the same way as
    #     initial account confirmation) to be applied. Requires additional unconfirmed_phone
    #     db field to be set up (t.reconfirmable in migrations). Until confirmed, new phone is
    #     stored in unconfirmed phone column, and copied to phone column on successful
    #     confirmation. Also, when used in conjunction with `send_phone_changed_notification`,
    #     the notification is sent to the original phone when the change is requested,
    #     not when the unconfirmed phone is confirmed.
    #   * +confirm_phone_within+: the time before a sent confirmation token becomes invalid.
    #     You can use this to force the user to confirm within a set period of time.
    #     Confirmable will not generate a new token if a repeat confirmation is requested
    #     during this time frame, unless the user's phone changed too.
    #
    # == Examples
    #
    #   User.find(1).phone_confirm       # returns true unless it's already confirmed
    #   User.find(1).phone_confirmed?    # true/false
    #   User.find(1).send_phone_confirmation_instructions # manually send instructions
    #
    module PhoneConfirmable
      extend ActiveSupport::Concern
      
      included do
        before_create :generate_phone_confirmation_token, if: :phone_confirmation_required?
        after_create :skip_phone_reconfirmation_in_callback!, if: :send_phone_confirmation_notification?
        if respond_to?(:after_commit) # ActiveRecord
          after_commit :send_on_create_phone_confirmation_instructions, on: :create, if: :send_phone_confirmation_notification?
          after_commit :send_phone_reconfirmation_instructions, on: :update, if: :phone_reconfirmation_required?
        else # Mongoid
          after_create :send_on_create_phone_confirmation_instructions, if: :send_phone_confirmation_notification?
          after_update :send_phone_reconfirmation_instructions, if: :phone_reconfirmation_required?
        end
        before_update :postpone_phone_change_until_confirmation_and_regenerate_phone_confirmation_token, if: :postpone_phone_change?
      end

      def initialize(*args, &block)
        @bypass_phone_confirmation_postpone = false
        @skip_phone_reconfirmation_in_callback = false
        @phone_reconfirmation_required = false
        @skip_phone_confirmation_notification = false
        @raw_phone_confirmation_token = nil
        super
      end

      def self.required_fields(klass)
        required_methods = [:phone_confirmation_token, :phone_confirmed_at, :phone_confirmation_sent_at]
        required_methods << :unconfirmed_phone if klass.phone_reconfirmable
        required_methods
      end

      # Confirm a user by setting it's phone_confirmed_at to actual time. If the user
      # is already confirmed, add an error to phone field. If the user is invalid
      # add errors
      def phone_confirm(args={})
        pending_any_phone_confirmation do
          if phone_confirmation_period_expired?
            self.errors.add(:phone, :confirmation_period_expired,
              period: Devise::TimeInflector.time_ago_in_words(self.class.confirm_phone_within.ago))
            return false
          end

          self.phone_confirmed_at = Time.now.utc

          saved = if pending_phone_reconfirmation?
            skip_phone_reconfirmation!
            self.phone = unconfirmed_phone
            self.unconfirmed_phone = nil

            # We need to validate in such cases to enforce e-mail uniqueness
            save(validate: true)
          else
            save(validate: args[:ensure_valid] == true)
          end

          after_phone_confirmation if saved
          saved
        end
      end

      # Verifies whether a user is confirmed or not
      def phone_confirmed?
        !!phone_confirmed_at
      end

      def pending_phone_reconfirmation?
        self.class.phone_reconfirmable && unconfirmed_phone.present?
      end

      # Send confirmation instructions by phone
      def send_phone_confirmation_instructions
        unless @raw_phone_confirmation_token
          generate_phone_confirmation_token!
        end

        opts = pending_phone_reconfirmation? ? { to: unconfirmed_phone } : { }
        DeviseTexter.delay.confirmation_instructions(self, @raw_phone_confirmation_token)
      end

      def send_phone_reconfirmation_instructions
        @phone_reconfirmation_required = false

        unless @skip_phone_confirmation_notification
          send_phone_confirmation_instructions
        end
      end

      # Resend confirmation token.
      # Regenerates the token if the period is expired.
      def resend_phone_confirmation_instructions
        pending_any_phone_confirmation do
          send_phone_confirmation_instructions
        end
      end

      # Overwrites active_for_authentication? for confirmation
      # by verifying whether a user is active to sign in or not. If the user
      # is already confirmed, it should never be blocked. Otherwise we need to
      # calculate if the confirm time has not expired for this user.
      def active_for_authentication?
        super && (!phone_confirmation_required? || phone_confirmed? || phone_confirmation_period_valid?)
      end

      # The message to be shown if the account is inactive.
      def inactive_message
        !phone_confirmed? ? :unconfirmed : super
      end

      # If you don't want confirmation to be sent on create, neither a code
      # to be generated, call skip_phone_confirmation!
      def skip_phone_confirmation!
        self.phone_confirmed_at = Time.now.utc
      end

      # Skips sending the confirmation/reconfirmation notification phone after_create/after_update. Unlike
      # #skip_phone_confirmation!, record still requires confirmation.
      def skip_phone_confirmation_notification!
        @skip_phone_confirmation_notification = true
      end

      # If you don't want reconfirmation to be sent, neither a code
      # to be generated, call skip_phone_reconfirmation!
      def skip_phone_reconfirmation!
        @bypass_phone_confirmation_postpone = true
      end

      protected

        # To not require reconfirmation after creating with #save called in a
        # callback call skip_create_confirmation!
        def skip_phone_reconfirmation_in_callback!
          @skip_phone_reconfirmation_in_callback = true
        end

        # A callback method used to deliver confirmation
        # instructions on creation. This can be overridden
        # in models to map to a nice sign up e-mail.
        def send_on_create_phone_confirmation_instructions
          send_phone_confirmation_instructions
        end

        # Callback to overwrite if confirmation is required or not.
        def phone_confirmation_required?
          !phone_confirmed?
        end

        # Checks if the confirmation for the user is within the limit time.
        # We do this by calculating if the difference between today and the
        # confirmation sent date does not exceed the confirm in time configured.
        # allow_unconfirmed_phone_access_for is a model configuration, must always be an integer value.
        #
        # Example:
        #
        #   # allow_unconfirmed_phone_access_for = 1.day and phone_confirmation_sent_at = today
        #   phone_confirmation_period_valid?   # returns true
        #
        #   # allow_unconfirmed_phone_access_for = 5.days and phone_confirmation_sent_at = 4.days.ago
        #   phone_confirmation_period_valid?   # returns true
        #
        #   # allow_unconfirmed_phone_access_for = 5.days and phone_confirmation_sent_at = 5.days.ago
        #   phone_confirmation_period_valid?   # returns false
        #
        #   # allow_unconfirmed_phone_access_for = 0.days
        #   phone_confirmation_period_valid?   # will always return false
        #
        #   # allow_unconfirmed_phone_access_for = nil
        #   phone_confirmation_period_valid?   # will always return true
        #
        def phone_confirmation_period_valid?
          self.class.allow_unconfirmed_phone_access_for.nil? || (phone_confirmation_sent_at && phone_confirmation_sent_at.utc >= self.class.allow_unconfirmed_phone_access_for.ago)
        end

        # Checks if the user confirmation happens before the token becomes invalid
        # Examples:
        #
        #   # confirm_phone_within = 3.days and phone_confirmation_sent_at = 2.days.ago
        #   phone_confirmation_period_expired?  # returns false
        #
        #   # confirm_phone_within = 3.days and phone_confirmation_sent_at = 4.days.ago
        #   phone_confirmation_period_expired?  # returns true
        #
        #   # confirm_phone_within = nil
        #   phone_confirmation_period_expired?  # will always return false
        #
        def phone_confirmation_period_expired?
          self.class.confirm_phone_within && self.phone_confirmation_sent_at && (Time.now.utc > self.phone_confirmation_sent_at.utc + self.class.confirm_phone_within)
        end

        # Checks whether the record requires any confirmation.
        def pending_any_phone_confirmation
          if (!phone_confirmed? || pending_phone_reconfirmation?)
            yield
          else
            self.errors.add(:phone, :already_confirmed)
            false
          end
        end

        # Generates a new random token for confirmation, and stores
        # the time this token is being generated in phone_confirmation_sent_at
        def generate_phone_confirmation_token
          if self.phone_confirmation_token && !phone_confirmation_period_expired?
            @raw_phone_confirmation_token = self.phone_confirmation_token
          else
            self.phone_confirmation_token = @raw_phone_confirmation_token = current_otp
            self.phone_confirmation_sent_at = Time.now.utc
          end
        end

        def generate_phone_confirmation_token!
          generate_phone_confirmation_token && save(validate: false)
        end

        if Devise.activerecord51?
          def postpone_phone_change_until_confirmation_and_regenerate_phone_confirmation_token
            @phone_reconfirmation_required = true
            self.unconfirmed_phone = self.phone
            self.phone = self.phone_in_database
            self.phone_confirmation_token = nil
            generate_phone_confirmation_token
          end
        else
          def postpone_phone_change_until_confirmation_and_regenerate_phone_confirmation_token
            @phone_reconfirmation_required = true
            self.unconfirmed_phone = self.phone
            self.phone = self.phone_was
            self.phone_confirmation_token = nil
            generate_phone_confirmation_token
          end
        end

        if Devise.activerecord51?
          def postpone_phone_change?
            postpone = self.class.phone_reconfirmable &&
              will_save_change_to_phone? &&
              !@bypass_phone_confirmation_postpone &&
              self.phone.present? &&
              (!@skip_phone_reconfirmation_in_callback || !self.phone_in_database.nil?)
            @bypass_phone_confirmation_postpone = false
            postpone
          end
        else
          def postpone_phone_change?
            postpone = self.class.phone_reconfirmable &&
              phone_changed? &&
              !@bypass_phone_confirmation_postpone &&
              self.phone.present? &&
              (!@skip_phone_reconfirmation_in_callback || !self.phone_was.nil?)
            @bypass_phone_confirmation_postpone = false
            postpone
          end
        end

        def phone_reconfirmation_required?
          self.class.phone_reconfirmable && @phone_reconfirmation_required && (self.phone.present? || self.unconfirmed_phone.present?)
        end

        def send_phone_confirmation_notification?
          phone_confirmation_required? && !@skip_phone_confirmation_notification && self.phone.present?
        end

        # With reconfirmable, notify the original phone when the user first
        # requests the phone change, instead of when the change is confirmed.
        def send_phone_changed_notification?
          if self.class.phone_reconfirmable
            self.class.send_phone_changed_notification && phone_reconfirmation_required?
          else
            super
          end
        end

        # A callback initiated after successfully confirming. This can be
        # used to insert your own logic that is only run after the user successfully
        # confirms.
        #
        # Example:
        #
        #   def after_phone_confirmation
        #     self.update_attribute(:invite_code, nil)
        #   end
        #
        def after_phone_confirmation
        end

      class_methods do
        # Attempt to find a user by its phone. If a record is found, send new
        # confirmation instructions to it. If not, try searching for a user by unconfirmed_phone
        # field. If no user is found, returns a new user with an phone not found error.
        # Options must contain the user phone
        def send_phone_confirmation_instructions(attributes={})
          phone_confirmable = find_by_unconfirmed_phone_with_errors(attributes) if phone_reconfirmable
          unless phone_confirmable.try(:persisted?)
            phone_confirmable = find_or_initialize_with_errors(phone_confirmation_keys, attributes, :not_found)
          end
          phone_confirmable.resend_phone_confirmation_instructions if phone_confirmable.persisted?
          phone_confirmable
        end

        # Find a user by its confirmation token and try to confirm it.
        # If no user is found, returns a new user with an error.
        # If the user is already confirmed, create an error for the user
        # Options must have the phone_confirmation_token
        def confirm_by_token(phone_confirmation_token)
          phone_confirmable = find_first_by_auth_conditions(phone_confirmation_token: phone_confirmation_token)
          unless phone_confirmable
            phone_confirmable = find_or_initialize_with_error_by(:phone_confirmation_token, phone_confirmation_token)
          end

          phone_confirmable.confirm if phone_confirmable.persisted?
          phone_confirmable
        end

        # Find a record for confirmation by unconfirmed phone field
        def find_by_unconfirmed_phone_with_errors(attributes = {})
          attributes = attributes.slice(*phone_confirmation_keys).permit!.to_h if attributes.respond_to? :permit
          unconfirmed_required_attributes = phone_confirmation_keys.map { |k| k == :phone ? :unconfirmed_phone : k }
          unconfirmed_attributes = attributes.symbolize_keys
          unconfirmed_attributes[:unconfirmed_phone] = unconfirmed_attributes.delete(:phone)
          find_or_initialize_with_errors(unconfirmed_required_attributes, unconfirmed_attributes, :not_found)
        end

        Devise::Models.config(self, :allow_unconfirmed_phone_access_for, :phone_confirmation_keys, :phone_reconfirmable, :confirm_phone_within)
      end
    end
  end
end
