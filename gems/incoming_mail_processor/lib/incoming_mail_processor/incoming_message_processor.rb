# frozen_string_literal: true

#
# Copyright (C) 2013 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require "mail"
require "canvas_errors"

module IncomingMailProcessor
  class IncomingMessageProcessor
    extend HtmlTextHelper

    MailboxClasses = {
      imap: IncomingMailProcessor::ImapMailbox,
      directory: IncomingMailProcessor::DirectoryMailbox,
      pop3: IncomingMailProcessor::Pop3Mailbox,
      sqs: IncomingMailProcessor::SqsMailbox,
    }.freeze

    ImportantHeaders = %w[To From Subject Content-Type].freeze

    BULK_PRECEDENCE_VALUES = %w[bulk list junk].freeze
    private_constant :BULK_PRECEDENCE_VALUES

    class << self
      attr_accessor :mailbox_accounts, :settings, :deprecated_settings, :logger

      def create_mailbox(account)
        mailbox_class = get_mailbox_class(account)
        mailbox = mailbox_class.new(account.config)
        mailbox.set_timeout_method(&method(:timeout_method))
        mailbox
      end

      def error_report_category
        "incoming_message_processor"
      end

      def bounce_message?(mail)
        mail.header.fields.any? do |field|
          case field.name
          when "Auto-Submitted" # RFC-3834
            field.value != "no"
          when "Precedence" # old kludgey stuff uses this
            BULK_PRECEDENCE_VALUES.include?(field.value)
          when "X-Auto-Response-Suppress", # Exchange sets this
              # some other random headers I found that are easy to check
              "X-Autoreply",
              "X-Autorespond",
              "X-Autoresponder"
            true
          else
            # not a bounce header we care about
            false
          end
        end
      end

      def utf8ify(string, encoding)
        encoding ||= "UTF-8"
        encoding = encoding.upcase
        encoding = "UTF-8" if encoding == "UTF8"

        # change encoding; if it throws an exception (i.e. unrecognized encoding), just strip invalid UTF-8
        begin
          new_string = string.encode("UTF-8", encoding)
        rescue EncodingError
          # ignore
        end
        new_string&.valid_encoding? ? new_string : Utf8Cleaner.strip_invalid_utf8(string)
      end

      def extract_address_tag(message, account)
        addr, domain = account.address.split(/@/)
        regex = Regexp.new("#{Regexp.escape(addr)}\\+([^@]+)@#{Regexp.escape(domain)}")
        message.to&.each do |address|
          if (match = regex.match(address))
            return match[1]
          end
        end

        # if no match is found, return false
        # so that self.process message stops processing.
        false
      end

      private

      def mailbox_keys
        MailboxClasses.keys.map(&:to_s)
      end

      def get_mailbox_class(account)
        MailboxClasses.fetch(account.protocol)
      end

      def timeout_method(&)
        Canvas.timeout_protection("incoming_message_processor", raise_on_timeout: true, &)
      end

      def configure_settings(config)
        @settings = IncomingMailProcessor::Settings.new
        @deprecated_settings = IncomingMailProcessor::DeprecatedSettings.new

        config.symbolize_keys.each do |key, value|
          if IncomingMailProcessor::Settings.members.map(&:to_sym).include?(key)
            settings.send(:"#{key}=", value)
          elsif IncomingMailProcessor::DeprecatedSettings.members.map(&:to_sym).include?(key)
            logger&.warn("deprecated setting sent to IncomingMessageProcessor: #{key}")
            deprecated_settings.send(:"#{key}=", value)
          else
            raise "unrecognized setting sent to IncomingMessageProcessor: #{key}"
          end
        end
      end

      def configure_accounts(account_configs)
        flat_account_configs = flatten_account_configs(account_configs)
        self.mailbox_accounts = flat_account_configs.map do |mailbox_protocol, mailbox_config|
          error_folder = mailbox_config.delete(:error_folder)
          address = mailbox_config[:address] || mailbox_config[:username]
          IncomingMailProcessor::MailboxAccount.new({
                                                      protocol: mailbox_protocol.to_sym,
                                                      config: mailbox_config,
                                                      address:,
                                                      error_folder:,
                                                    })
        end
      end

      def flatten_account_configs(account_configs)
        account_configs.each_with_object([]) do |(mailbox_protocol, mailbox_config), flat_account_configs|
          flat_mailbox_configs = flatten_mailbox_overrides(mailbox_config)
          flat_mailbox_configs.each do |single_mailbox_config|
            flat_account_configs << [mailbox_protocol, single_mailbox_config]
          end
        end
      end

      def flatten_mailbox_overrides(mailbox_config)
        mailbox_defaults = mailbox_config.except("accounts")
        mailbox_overrides = mailbox_config["accounts"] || [{}]
        mailbox_overrides.map do |override_config|
          mailbox_defaults.merge(override_config).symbolize_keys
        end
      end
    end

    def initialize(message_handler, error_reporter)
      @message_handler = message_handler
      @error_reporter = error_reporter
    end

    def self.queue_processors
      if run_periodically?
        imp = new(IncomingMail::MessageHandler.new, ErrorReport::Reporter.new)
        workers.times do |worker_id|
          if dedicated_workers_per_mailbox
            # Launch one per mailbox
            mailbox_accounts.each do |account|
              imp.delay(singleton: "IncomingMailProcessor::IncomingMessageProcessor#process:#{worker_id}:#{account.address}")
                 .process({ worker_id:, mailbox_account_address: account.address })
            end
          else
            # Just launch the one
            imp.delay(singleton: "IncomingMailProcessor::IncomingMessageProcessor#process:#{worker_id}")
               .process({ worker_id: })
          end
        end
      end
    end

    # See config/incoming_mail.yml.example for documentation on how to configure incoming mail
    def self.configure(config)
      configure_settings(config.except(*mailbox_keys))
      configure_accounts(config.slice(*mailbox_keys))
    end

    def self.workers
      settings.workers || 1
    end

    # True if we should launch N workers per mailbox, false to just launch N workers overall
    def self.dedicated_workers_per_mailbox
      settings.dedicated_workers_per_mailbox.nil? ? false : settings.dedicated_workers_per_mailbox
    end

    def self.run_periodically?
      if settings.run_periodically.nil?
        # check backwards compatibility settings
        deprecated_settings.poll_interval == 0 && deprecated_settings.ignore_stdin == true
      else
        !!settings.run_periodically
      end
    end

    def self.healthy?
      mailbox_accounts.each do |account|
        mailbox = create_mailbox(account)
        mailbox.connect
        mailbox.disconnect
      end
      true
    end

    def process(opts = {})
      accounts_to_process = if opts[:mailbox_account_address]
                              # Find the one with that address, or do nothing if none exists (probably means we're in the middle of a deploy)
                              self.class.mailbox_accounts.select { |a| a.address == opts[:mailbox_account_address] }
                            else
                              self.class.mailbox_accounts
                            end

      accounts_to_process.each do |account|
        mailbox = self.class.create_mailbox(account)
        mailbox_opts = {}
        mailbox_opts = { offset: opts[:worker_id], stride: self.class.workers } if opts[:worker_id] && self.class.workers > 1
        process_mailbox(mailbox, account, mailbox_opts)
      end
    end

    def process_single(incoming_message, tag, mailbox_account = IncomingMailProcessor::MailboxAccount.new)
      return if self.class.bounce_message?(incoming_message)

      body, html_body = extract_body(incoming_message)

      handle = @message_handler.handle(mailbox_account.address, body, html_body, incoming_message, tag)

      report_stats(incoming_message, mailbox_account)

      handle
    end

    private

    def extract_body(incoming_message)
      if incoming_message.multipart?
        html_part = incoming_message.html_part
        text_part = incoming_message.text_part

        html_body = self.class.utf8ify(html_part.body.decoded, html_part.charset) if html_part
        text_body = self.class.utf8ify(text_part.body.decoded, text_part.charset) if text_part
      else
        case incoming_message.mime_type
        when "text/plain", nil
          text_body = self.class.utf8ify(incoming_message.body.decoded, incoming_message.charset)
        when "text/html"
          html_body = self.class.utf8ify(incoming_message.body.decoded, incoming_message.charset)
        else
          raise "Unrecognized Content-Type: #{incoming_message.mime_type.inspect}"
        end
      end

      if html_body && !text_body
        text_body = self.class.html_to_text(html_body)
      end

      if text_body && !html_body
        html_body = self.class.format_message(text_body).first
      end

      [text_body, html_body]
    end

    def report_stats(incoming_message, mailbox_account)
      InstStatsd::Statsd.distributed_increment("incoming_mail_processor.incoming_message_processed.#{mailbox_account.escaped_address}",
                                               short_stat: "incoming_mail_processor.incoming_message_processed",
                                               tags: { mailbox: mailbox_account.escaped_address })
      age = age(incoming_message)
      if age
        stat_name = "incoming_mail_processor.message_age.#{mailbox_account.escaped_address}"
        InstStatsd::Statsd.timing(stat_name,
                                  age,
                                  short_stat: "incoming_mail_processor.message_age",
                                  tags: { mailbox: mailbox_account.escaped_address })
      end
    end

    def age(message)
      datetime = message.date
      (Time.now - datetime).to_i * 1000 if datetime # age in ms, please
    end

    def process_mailbox(mailbox, account, opts = {})
      error_folder = account.error_folder
      mailbox.connect
      mailbox.each_message(opts) do |message_id, raw_contents|
        message, errors = parse_message(raw_contents)
        if message && errors.blank?
          process_message(message, account)
          mailbox.delete_message(message_id)
        else
          mailbox.move_message(message_id, error_folder)
          if message
            @error_reporter.log_error(self.class.error_report_category, {
                                        message: "Error parsing email",
                                        backtrace: message.errors.flatten.map(&:to_s).join("\n"),
                                        from: message.from.try(:first),
                                        to: message.to.to_s,
                                      })
          end
        end
      end
      mailbox.disconnect
    rescue => e
      # any exception that makes it here probably means the connection is broken
      # skip this account, but the rest of the accounts should still be tried
      CanvasErrors.capture_exception(self.class.error_report_category, e, {})
    end

    def parse_message(raw_contents)
      message = Mail.new(raw_contents)
      errors = select_relevant_errors(message)

      # access some of the fields to make sure they don't raise errors when accessed
      message.subject

      [message, errors]
    rescue => e
      CanvasErrors.capture_exception(self.class.error_report_category, e, {})
      nil
    end

    def select_relevant_errors(message)
      # message.errors is an array of arrays containing header parsing errors:
      # [["header-name", "header-value", parser_exception], ...]
      message.errors.select do |error|
        IncomingMessageProcessor::ImportantHeaders.include?(error[0])
      end
    end

    def process_message(message, account)
      tag = self.class.extract_address_tag(message, account)
      # TODO: Add bounce processing and handling of other email to the default notification address.
      return unless tag

      process_single(message, tag, account)
    rescue => e
      CanvasErrors.capture_exception(self.class.error_report_category,
                                     e,
                                     from: message.from.try(:first),
                                     to: message.to.to_s)
    end
  end
end
