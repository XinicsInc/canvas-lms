# frozen_string_literal: true

#
# Copyright (C) 2014 - present Instructure, Inc.
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

# Defines periodic jobs run by DelayedJobs.
#
# Scheduling is done by rufus-scheduler
#
# You should only use "cron" type jobs, not "every". Cron jobs have deterministic
# times to run which help across daemon restarts, and distributing periodic
# jobs across multiple job servers.
#
# Periodic jobs default to low priority. You can override this in the arguments
# passed to Delayed::Periodic.cron

class PeriodicJobs
  def self.compute_run_at(jitter:, local_offset:)
    now = Time.zone.now
    run_at = now

    if local_offset
      database_timzone_name = Shard.current.database_server.config[:timezone]
      # If not set, assume it is the same on the database server as on the application server
      database_timezone = (database_timzone_name ? ActiveSupport::TimeZone[database_timzone_name] : nil) || Time.zone
      run_at = now + (Time.zone.utc_offset - database_timezone.utc_offset)
      if run_at < now
        run_at += 1.day
      end
    end

    if jitter.present?
      run_at = rand((run_at + 10.seconds)..(run_at + jitter))
    end
    run_at
  end

  def self.with_each_shard_by_database_in_region(klass, method, *args, jitter: nil, local_offset: false, connection_class: nil, error_callback: nil)
    error_callback ||= -> { Canvas::Errors.capture_exception(:periodic_job, $ERROR_INFO) }

    Shard.with_each_shard(Shard.in_current_region, exception: error_callback) do
      current_shard = Shard.current(connection_class)
      strand = "#{klass}.#{method}:#{current_shard.database_server.id}"
      # TODO: allow this to work with redis jobs
      next if Delayed::Job == Delayed::Backend::ActiveRecord::Job && Delayed::Job.where(strand:, shard_id: current_shard.id, locked_by: nil).exists?

      dj_params = {
        strand:,
        priority: 40
      }
      dj_params[:run_at] = compute_run_at(jitter:, local_offset:)

      current_shard.activate do
        klass.delay(**dj_params).__send__(method, *args)
      end
    end
  end
end

def with_each_job_cluster(klass, method, *args, jitter: nil, local_offset: false)
  DatabaseServer.send_in_each_region(
    PeriodicJobs,
    :with_each_shard_by_database_in_region,
    { singleton: "periodic:region: #{klass}.#{method}" },
    klass,
    method,
    *args,
    jitter:,
    local_offset:,
    connection_class: Delayed::Backend::ActiveRecord::AbstractJob
  )
end

def with_each_shard_by_database(klass, method, *args, jitter: nil, local_offset: false, error_callback: nil)
  DatabaseServer.send_in_each_region(
    PeriodicJobs,
    :with_each_shard_by_database_in_region,
    { singleton: "periodic:region: #{klass}.#{method}" },
    klass,
    method,
    *args,
    jitter:,
    local_offset:,
    connection_class: ActiveRecord::Base,
    error_callback:
  )
end

Rails.configuration.after_initialize do
  if defined?(ActiveRecord::SessionStore) && Rails.configuration.session_store == ActiveRecord::SessionStore
    expire_after = (ConfigFile.load("session_store") || {})[:expire_after]
    expire_after ||= 1.day

    Delayed::Periodic.cron "ActiveRecord::SessionStore::Session.delete_all", "*/5 * * * *" do
      callback = -> { Canvas::Errors.capture_exception(:periodic_job, $ERROR_INFO) }
      Shard.with_each_shard(exception: callback) do
        ActiveRecord::SessionStore::Session.where("updated_at < ?", expire_after.seconds.ago).delete_all
      end
    end
  end

  persistence_token_expire_after = (ConfigFile.load("session_store") || {})[:expire_remember_me_after]
  persistence_token_expire_after ||= 1.month
  # UTC 기준 한국시간 새벽 1시 35분, 매일.
  Delayed::Periodic.cron "SessionPersistenceToken.delete_all", "35 16 * * *" do
    with_each_shard_by_database(SessionPersistenceToken, :delete_expired, persistence_token_expire_after, local_offset: false)
  end

  Delayed::Periodic.cron "ExternalFeedAggregator.process", "*/30 * * * *" do
    with_each_shard_by_database(ExternalFeedAggregator, :process)
  end

  Delayed::Periodic.cron "SummaryMessageConsolidator.process", "*/15 * * * *" do
    with_each_shard_by_database(SummaryMessageConsolidator, :process)
  end

  Delayed::Periodic.cron "CrocodocDocument.update_process_states", "*/10 * * * *" do
    if Canvas::Crocodoc.config && !Canvas::Plugin.value_to_boolean(Canvas::Crocodoc.config["disable_polling"])
      with_each_shard_by_database(CrocodocDocument, :update_process_states)
    end
  end

  # UTC 기준 한국시간 새벽 2시, 월요일
  Delayed::Periodic.cron "Reporting::CountsReport.process", "0 17 * * 0" do
    with_each_shard_by_database(Reporting::CountsReport, :process_shard)
  end

  # UTC 기준 한국시간 새벽 1시, 월요일
  Delayed::Periodic.cron "Account.update_all_update_account_associations", "0 16 * * 0" do
    with_each_shard_by_database(Account, :update_all_update_account_associations)
  end

  Delayed::Periodic.cron "StreamItem.destroy_stream_items", "45 */6 * * *" do
    with_each_shard_by_database(StreamItem, :destroy_stream_items_using_setting)
  end

  Delayed::Periodic.cron "IncomingMailProcessor::IncomingMessageProcessor#process", "*/1 * * * *" do
    DatabaseServer.send_in_each_region(
      IncomingMailProcessor::IncomingMessageProcessor,
      :queue_processors,
      { run_current_region_asynchronously: true,
        singleton: "IncomingMailProcessor::IncomingMessageProcessor.queue_processors" }
    )
  end

  Delayed::Periodic.cron "IncomingMailProcessor::Instrumentation#process", "*/5 * * * *" do
    IncomingMailProcessor::Instrumentation.process
  end

  # UTC 기준 한국시간 새벽 4시, 매일.
  Delayed::Periodic.cron "ErrorReport.destroy_error_reports", "0 19 * * *" do
    cutoff = 3.months
    if cutoff > 0
      with_each_shard_by_database(ErrorReport, :destroy_error_reports, cutoff.seconds.ago)
    end
  end

  # UTC 기준 한국시간 새벽 3시 10분, 매일.
  Delayed::Periodic.cron "Delayed::Job::Failed.cleanup_old_jobs", "10 18 * * *" do
    cutoff = 3.months
    if cutoff > 0
      with_each_job_cluster(Delayed::Job::Failed, :cleanup_old_jobs, cutoff.seconds.ago)
    end
  end

  # UTC 기준 한국시간 새벽 4시 30분, 매일.
  Delayed::Periodic.cron "Alerts::DelayedAlertSender.process", "30 19 * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(Alerts::DelayedAlertSender, :process, local_offset: false)
  end

  Delayed::Periodic.cron "Attachment.do_notifications", "*/10 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(Attachment, :do_notifications)
  end

  unless ApplicationController.test_cluster?
    # UTC 기준 한국시간 새벽 1시 37분, 매일.
    Delayed::Periodic.cron "Attachment::GarbageCollector::ContentExportAndMigrationContextType.delete_content", "37 16 * * *" do
      with_each_shard_by_database(Attachment::GarbageCollector::ContentExportAndMigrationContextType, :delete_content, jitter: 30.minutes, local_offset: false)
    end

    # UTC 기준 한국시간 새벽 3시 37분, 매일.
    Delayed::Periodic.cron "Attachment::GarbageCollector::ContentExportContextType.delete_content", "37 18 * * *" do
      with_each_shard_by_database(Attachment::GarbageCollector::ContentExportContextType, :delete_content, jitter: 30.minutes, local_offset: false)
    end
  end

  # UTC 기준 한국시간 오후 11시 45분, 매일
  Delayed::Periodic.cron "Ignore.cleanup", "45 14 * * *" do
    with_each_shard_by_database(Ignore, :cleanup, local_offset: false)
  end

  # UTC 기준 한국시간 새벽 1시, 매일
  Delayed::Periodic.cron "DelayedMessageScrubber.scrub_all", "0 16 * * *" do
    with_each_shard_by_database(DelayedMessageScrubber, :scrub, local_offset: false)
  end

  # UTC 기준 한국시간 새벽 2시, 매일
  Delayed::Periodic.cron "ConversationBatchScrubber.scrub_all", "0 17 * * *" do
    with_each_shard_by_database(ConversationBatchScrubber, :scrub, local_offset: false)
  end

  Delayed::Periodic.cron "BounceNotificationProcessor.process", "*/5 * * * *" do
    DatabaseServer.send_in_each_region(
      BounceNotificationProcessor,
      :process,
      { run_current_region_asynchronously: true }
    )
  end

  Delayed::Periodic.cron "NotificationFailureProcessor.process", "*/5 * * * *" do
    DatabaseServer.send_in_each_region(
      NotificationFailureProcessor,
      :process,
      { run_current_region_asynchronously: true,
        singleton: "NotificationFailureProcessor.process" }
    )
  end

  # Partitioner jobs
  # process and/or create once a day at midnight
  # prune every Saturday, but only after the first Thursday of the month
  # UTC 기준 한국시간 새벽 2시, 매일
  Delayed::Periodic.cron "Auditors::ActiveRecord::Partitioner.process", "0 17 * * *" do
    with_each_shard_by_database(Auditors::ActiveRecord::Partitioner, :process, jitter: 30.minutes, local_offset: false)
  end

  # UTC 기준 한국시간 새벽 2시, 매주 일요일
  Delayed::Periodic.cron "Auditors::ActiveRecord::Partitioner.prune", "0 17 * * 6" do
    if Time.now.day >= 3
      with_each_shard_by_database(
        Auditors::ActiveRecord::Partitioner, :prune, jitter: 30.minutes, local_offset: false
      )
    end
  end

  # UTC 기준 한국시간 새벽 1시, 매일
  Delayed::Periodic.cron "Quizzes::QuizSubmissionEventPartitioner.process", "0 16 * * *" do
    with_each_shard_by_database(Quizzes::QuizSubmissionEventPartitioner, :process, jitter: 30.minutes, local_offset: false)
  end

  # UTC 기준 한국시간 새벽 1시, 매주 일요일
  Delayed::Periodic.cron "Quizzes::QuizSubmissionEventPartitioner.prune", "0 16 * * 6" do
    if Time.now.day >= 3
      with_each_shard_by_database(
        Quizzes::QuizSubmissionEventPartitioner, :prune, jitter: 30.minutes, local_offset: false
      )
    end
  end

  # UTC 기준 한국시간 새벽 3시, 매일
  Delayed::Periodic.cron "Messages::Partitioner.process", "0 18 * * *" do
    with_each_shard_by_database(Messages::Partitioner, :process, jitter: 30.minutes, local_offset: false)
  end

  # UTC 기준 한국시간 오전 7시, 매주 일요일
  Delayed::Periodic.cron "Messages::Partitioner.prune", "0 22 * * 6" do
    if Time.now.day >= 3
      with_each_shard_by_database(
        Messages::Partitioner, :prune, jitter: 30.minutes, local_offset: false
      )
    end
  end

  Delayed::Periodic.cron "SimplyVersioned::Partitioner.process", "0 0 * * *" do
    with_each_shard_by_database(SimplyVersioned::Partitioner, :process, jitter: 30.minutes, local_offset: false)
  end

  if AuthenticationProvider::SAML.enabled?
    # UTC 기준 한국시간 오전 7시 15분, 매일
    Delayed::Periodic.cron "AuthenticationProvider::SAML::MetadataRefresher.refresh_providers", "15 22 * * *" do
      with_each_shard_by_database(AuthenticationProvider::SAML::MetadataRefresher, :refresh_providers, local_offset: false)
    end

    AuthenticationProvider::SAML::Federation.descendants.each do |federation|
      # UTC 기준 한국시간 0시 45분, 매일
      Delayed::Periodic.cron "AuthenticationProvider::SAML::#{federation.class_name}.refresh_providers", "45 15 * * *" do
        DatabaseServer.send_in_each_region(federation,
                                           :refresh_providers,
                                           { singleton: "AuthenticationProvider::SAML::#{federation.class_name}.refresh_providers" })
      end
    end
  end

  # UTC 기준 한국시간 0시 30분, 매일
  Delayed::Periodic.cron "AuthenticationProvider::LDAP.ensure_tls_cert_validity", "30 15 * * *" do
    with_each_shard_by_database(AuthenticationProvider::LDAP, :ensure_tls_cert_validity, local_offset: false)
  end

  Delayed::Periodic.cron "SisBatchError.cleanup_old_errors", "*/15 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(SisBatchError, :cleanup_old_errors)
  end

  Delayed::Periodic.cron "AccountReport.delete_old_rows_and_runners", "*/15 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(AccountReport, :delete_old_rows_and_runners)
  end

  Delayed::Periodic.cron "SisBatchRollBackData.cleanup_expired_data", "*/15 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(SisBatchRollBackData, :cleanup_expired_data)
  end

  Delayed::Periodic.cron "EnrollmentState.recalculate_expired_states", "*/5 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(EnrollmentState, :recalculate_expired_states)
  end

  Delayed::Periodic.cron "MissingPolicyApplicator.apply_missing_deductions", "*/5 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(MissingPolicyApplicator, :apply_missing_deductions)
  end

  Delayed::Periodic.cron "Assignment.clean_up_duplicating_assignments", "*/5 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(Assignment, :clean_up_duplicating_assignments)
  end

  Delayed::Periodic.cron "Assignment.clean_up_cloning_alignments", "*/5 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(Assignment, :clean_up_cloning_alignments)
  end

  Delayed::Periodic.cron "Assignment.clean_up_importing_assignments", "*/5 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(Assignment, :clean_up_importing_assignments)
  end

  Delayed::Periodic.cron "Assignment.clean_up_migrating_assignments", "*/5 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(Assignment, :clean_up_migrating_assignments)
  end

  Delayed::Periodic.cron "ObserverAlert.clean_up_old_alerts", "0 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(ObserverAlert, :clean_up_old_alerts)
  end

  Delayed::Periodic.cron "ObserverAlert.create_assignment_missing_alerts", "*/15 * * * *", priority: Delayed::LOW_PRIORITY do
    with_each_shard_by_database(ObserverAlert, :create_assignment_missing_alerts)
  end

  # UTC 기준 한국시간 0시 정각, 매월 1일
  Delayed::Periodic.cron "Lti::KeyStorage.rotate_keys", "0 15 1 * *", priority: Delayed::LOW_PRIORITY do
    Lti::KeyStorage.rotate_keys
  end

  Delayed::Periodic.cron "Canvas::OAuth::KeyStorage.rotate_keys", "0 15 1 * *", priority: Delayed::LOW_PRIORITY do
    Canvas::OAuth::KeyStorage.rotate_keys
  end

  Delayed::Periodic.cron "CanvasSecurity::ServicesJwt::KeyStorage.rotate_keys", "0 15 1 * *", priority: Delayed::LOW_PRIORITY do
    CanvasSecurity::ServicesJwt::KeyStorage.rotate_keys
  end

  Delayed::Periodic.cron "Purgatory.expire_old_purgatories", "0 15 * * *", priority: Delayed::LOWER_PRIORITY do
    with_each_shard_by_database(Purgatory, :expire_old_purgatories, local_offset: false)
  end

  Delayed::Periodic.cron "Feature.remove_obsolete_flags", "0 8 * * 0", priority: Delayed::LOWER_PRIORITY do
    with_each_shard_by_database(Feature, :remove_obsolete_flags)
  end

  Delayed::Periodic.cron "Assignment.disable_post_to_sis_if_grading_period_closed", "*/5 * * * *", priority: Delayed::LOWER_PRIORITY do
    with_each_shard_by_database(Assignment, :disable_post_to_sis_if_grading_period_closed)
  end

  Delayed::Periodic.cron "ScheduledSmartAlert.queue_current_jobs", "5 * * * *" do
    with_each_shard_by_database(ScheduledSmartAlert, :queue_current_jobs)
  end

  Delayed::Periodic.cron "Course.sync_with_homeroom", "5 0 * * *" do
    with_each_shard_by_database(Course, :sync_with_homeroom)
  end

  # the default is hourly, and we picked a weird minute just to avoid
  # synchronizing with other periodic jobs.
  Delayed::Periodic.cron "AssetUserAccessLog.compact", "42 * * * *" do
    # using jitter should help spread out multiple shards on the same cluster doing these
    # write-heavy updates so that they don't all hit at the same time and run immediately back to back.
    with_each_shard_by_database(AssetUserAccessLog, :compact, jitter: 15.minutes)
  end

  if MultiCache.cache.is_a?(ActiveSupport::Cache::HaStore) && MultiCache.cache.options[:consul_event] && InstStatsd.settings.present?
    Delayed::Periodic.cron "HaStore.validate_consul_event", "5 * * * *" do
      DatabaseServer.send_in_each_region(MultiCache,
                                         :validate_consul_event,
                                         {
                                           run_current_region_asynchronously: true,
                                           singleton: "HaStore.validate_consul_event"
                                         })
    end
  end

  Delayed::Periodic.cron "Canvas::LiveEvents#heartbeat", "*/1 * * * *" do
    DatabaseServer.send_in_each_region(
      Canvas::LiveEvents,
      :heartbeat,
      { run_current_region_asynchronously: true,
        singleton: "Canvas::LiveEvents#heartbeat" }
    )
  end
end
