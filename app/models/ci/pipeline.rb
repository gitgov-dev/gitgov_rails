# frozen_string_literal: true

module Ci
  class Pipeline < ApplicationRecord
    extend Gitlab::Ci::Model
    include Ci::HasStatus
    include Importable
    include AfterCommitQueue
    include Presentable
    include Gitlab::OptimisticLocking
    include Gitlab::Utils::StrongMemoize
    include AtomicInternalId
    include EnumWithNil
    include Ci::HasRef
    include ShaAttribute
    include FromUnion
    include UpdatedAtFilterable

    PROJECT_ROUTE_AND_NAMESPACE_ROUTE = {
      project: [:project_feature, :route, { namespace: :route }]
    }.freeze

    BridgeStatusError = Class.new(StandardError)

    sha_attribute :source_sha
    sha_attribute :target_sha

    belongs_to :project, inverse_of: :all_pipelines
    belongs_to :user
    belongs_to :auto_canceled_by, class_name: 'Ci::Pipeline'
    belongs_to :pipeline_schedule, class_name: 'Ci::PipelineSchedule'
    belongs_to :merge_request, class_name: 'MergeRequest'
    belongs_to :external_pull_request
    belongs_to :ci_ref, class_name: 'Ci::Ref', foreign_key: :ci_ref_id, inverse_of: :pipelines

    has_internal_id :iid, scope: :project, presence: false, track_if: -> { !importing? }, ensure_if: -> { !importing? }, init: ->(s) do
      s&.project&.all_pipelines&.maximum(:iid) || s&.project&.all_pipelines&.count
    end

    has_many :stages, -> { order(position: :asc) }, inverse_of: :pipeline
    has_many :statuses, class_name: 'CommitStatus', foreign_key: :commit_id, inverse_of: :pipeline
    has_many :latest_statuses_ordered_by_stage, -> { latest.order(:stage_idx, :stage) }, class_name: 'CommitStatus', foreign_key: :commit_id, inverse_of: :pipeline
    has_many :processables, class_name: 'Ci::Processable', foreign_key: :commit_id, inverse_of: :pipeline
    has_many :bridges, class_name: 'Ci::Bridge', foreign_key: :commit_id, inverse_of: :pipeline
    has_many :builds, foreign_key: :commit_id, inverse_of: :pipeline
    has_many :job_artifacts, through: :builds
    has_many :trigger_requests, dependent: :destroy, foreign_key: :commit_id # rubocop:disable Cop/ActiveRecordDependent
    has_many :variables, class_name: 'Ci::PipelineVariable'
    has_many :deployments, through: :builds
    has_many :environments, -> { distinct }, through: :deployments
    has_many :latest_builds, -> { latest }, foreign_key: :commit_id, inverse_of: :pipeline, class_name: 'Ci::Build'
    has_many :downloadable_artifacts, -> { not_expired.downloadable }, through: :latest_builds, source: :job_artifacts

    has_many :messages, class_name: 'Ci::PipelineMessage', inverse_of: :pipeline

    # Merge requests for which the current pipeline is running against
    # the merge request's latest commit.
    has_many :merge_requests_as_head_pipeline, foreign_key: "head_pipeline_id", class_name: 'MergeRequest'

    has_many :pending_builds, -> { pending }, foreign_key: :commit_id, class_name: 'Ci::Build'
    has_many :failed_builds, -> { latest.failed }, foreign_key: :commit_id, class_name: 'Ci::Build', inverse_of: :pipeline
    has_many :retryable_builds, -> { latest.failed_or_canceled.includes(:project) }, foreign_key: :commit_id, class_name: 'Ci::Build'
    has_many :cancelable_statuses, -> { cancelable }, foreign_key: :commit_id, class_name: 'CommitStatus'
    has_many :manual_actions, -> { latest.manual_actions.includes(:project) }, foreign_key: :commit_id, class_name: 'Ci::Build'
    has_many :scheduled_actions, -> { latest.scheduled_actions.includes(:project) }, foreign_key: :commit_id, class_name: 'Ci::Build'

    has_many :auto_canceled_pipelines, class_name: 'Ci::Pipeline', foreign_key: 'auto_canceled_by_id'
    has_many :auto_canceled_jobs, class_name: 'CommitStatus', foreign_key: 'auto_canceled_by_id'
    has_many :sourced_pipelines, class_name: 'Ci::Sources::Pipeline', foreign_key: :source_pipeline_id

    has_one :source_pipeline, class_name: 'Ci::Sources::Pipeline', inverse_of: :pipeline

    has_one :chat_data, class_name: 'Ci::PipelineChatData'

    has_many :triggered_pipelines, through: :sourced_pipelines, source: :pipeline
    has_many :child_pipelines, -> { merge(Ci::Sources::Pipeline.same_project) }, through: :sourced_pipelines, source: :pipeline
    has_one :triggered_by_pipeline, through: :source_pipeline, source: :source_pipeline
    has_one :parent_pipeline, -> { merge(Ci::Sources::Pipeline.same_project) }, through: :source_pipeline, source: :source_pipeline
    has_one :source_job, through: :source_pipeline, source: :source_job
    has_one :source_bridge, through: :source_pipeline, source: :source_bridge

    has_one :pipeline_config, class_name: 'Ci::PipelineConfig', inverse_of: :pipeline

    has_many :daily_build_group_report_results, class_name: 'Ci::DailyBuildGroupReportResult', foreign_key: :last_pipeline_id
    has_many :latest_builds_report_results, through: :latest_builds, source: :report_results

    accepts_nested_attributes_for :variables, reject_if: :persisted?

    delegate :id, to: :project, prefix: true
    delegate :full_path, to: :project, prefix: true

    validates :sha, presence: { unless: :importing? }
    validates :ref, presence: { unless: :importing? }
    validates :tag, inclusion: { in: [false], if: :merge_request? }

    validates :external_pull_request, presence: { if: :external_pull_request_event? }
    validates :external_pull_request, absence: { unless: :external_pull_request_event? }
    validates :tag, inclusion: { in: [false], if: :external_pull_request_event? }

    validates :status, presence: { unless: :importing? }
    validate :valid_commit_sha, unless: :importing?
    validates :source, exclusion: { in: %w(unknown), unless: :importing? }, on: :create

    after_create :keep_around_commits, unless: :importing?

    # We use `Ci::PipelineEnums.sources` here so that EE can more easily extend
    # this `Hash` with new values.
    enum_with_nil source: ::Ci::PipelineEnums.sources

    enum_with_nil config_source: ::Ci::PipelineEnums.config_sources

    # We use `Ci::PipelineEnums.failure_reasons` here so that EE can more easily
    # extend this `Hash` with new values.
    enum failure_reason: ::Ci::PipelineEnums.failure_reasons

    enum locked: { unlocked: 0, artifacts_locked: 1 }

    state_machine :status, initial: :created do
      event :enqueue do
        transition [:created, :manual, :waiting_for_resource, :preparing, :skipped, :scheduled] => :pending
        transition [:success, :failed, :canceled] => :running

        # this is needed to ensure tests to be covered
        transition [:running] => :running
      end

      event :request_resource do
        transition any - [:waiting_for_resource] => :waiting_for_resource
      end

      event :prepare do
        transition any - [:preparing] => :preparing
      end

      event :run do
        transition any - [:running] => :running
      end

      event :skip do
        transition any - [:skipped] => :skipped
      end

      event :drop do
        transition any - [:failed] => :failed
      end

      event :succeed do
        transition any - [:success] => :success
      end

      event :cancel do
        transition any - [:canceled] => :canceled
      end

      event :block do
        transition any - [:manual] => :manual
      end

      event :delay do
        transition any - [:scheduled] => :scheduled
      end

      # IMPORTANT
      # Do not add any operations to this state_machine
      # Create a separate worker for each new operation

      before_transition [:created, :waiting_for_resource, :preparing, :pending] => :running do |pipeline|
        pipeline.started_at = Time.current
      end

      before_transition any => [:success, :failed, :canceled] do |pipeline|
        pipeline.finished_at = Time.current
        pipeline.update_duration
      end

      before_transition any => [:manual] do |pipeline|
        pipeline.update_duration
      end

      before_transition canceled: any - [:canceled] do |pipeline|
        pipeline.auto_canceled_by = nil
      end

      before_transition any => :failed do |pipeline, transition|
        transition.args.first.try do |reason|
          pipeline.failure_reason = reason
        end
      end

      after_transition [:created, :waiting_for_resource, :preparing, :pending] => :running do |pipeline|
        pipeline.run_after_commit { PipelineMetricsWorker.perform_async(pipeline.id) }
      end

      after_transition any => [:success] do |pipeline|
        pipeline.run_after_commit { PipelineMetricsWorker.perform_async(pipeline.id) }
      end

      after_transition [:created, :waiting_for_resource, :preparing, :pending, :running] => :success do |pipeline|
        # We wait a little bit to ensure that all BuildFinishedWorkers finish first
        # because this is where some metrics like code coverage is parsed and stored
        # in CI build records which the daily build metrics worker relies on.
        pipeline.run_after_commit { Ci::DailyBuildGroupReportResultsWorker.perform_in(10.minutes, pipeline.id) }
      end

      after_transition do |pipeline, transition|
        next if transition.loopback?

        pipeline.run_after_commit do
          PipelineHooksWorker.perform_async(pipeline.id)
          ExpirePipelineCacheWorker.perform_async(pipeline.id) if pipeline.cacheable?
        end
      end

      after_transition any => ::Ci::Pipeline.completed_statuses do |pipeline|
        pipeline.run_after_commit do
          pipeline.persistent_ref.delete

          pipeline.all_merge_requests.each do |merge_request|
            next unless merge_request.auto_merge_enabled?

            AutoMergeProcessWorker.perform_async(merge_request.id)
          end

          if pipeline.auto_devops_source?
            self.class.auto_devops_pipelines_completed_total.increment(status: pipeline.status)
          end
        end
      end

      after_transition any => ::Ci::Pipeline.completed_statuses do |pipeline|
        next unless pipeline.bridge_triggered?
        next unless pipeline.bridge_waiting?

        pipeline.run_after_commit do
          ::Ci::PipelineBridgeStatusWorker.perform_async(pipeline.id)
        end
      end

      after_transition any => [:success, :failed] do |pipeline|
        ref_status = pipeline.ci_ref&.update_status_by!(pipeline)

        pipeline.run_after_commit do
          PipelineNotificationWorker.perform_async(pipeline.id, ref_status: ref_status)
        end
      end

      after_transition any => [:failed] do |pipeline|
        next unless pipeline.auto_devops_source?

        pipeline.run_after_commit { AutoDevops::DisableWorker.perform_async(pipeline.id) }
      end

      after_transition any => [:success] do |pipeline|
        next unless Gitlab::Ci::Features.keep_latest_artifacts_for_ref_enabled?(pipeline.project)

        pipeline.run_after_commit do
          Ci::PipelineSuccessUnlockArtifactsWorker.perform_async(pipeline.id)
        end
      end
    end

    scope :internal, -> { where(source: internal_sources) }
    scope :no_child, -> { where.not(source: :parent_pipeline) }
    scope :ci_sources, -> { where(config_source: ::Ci::PipelineEnums.ci_config_sources_values) }
    scope :for_user, -> (user) { where(user: user) }
    scope :for_sha, -> (sha) { where(sha: sha) }
    scope :for_source_sha, -> (source_sha) { where(source_sha: source_sha) }
    scope :for_sha_or_source_sha, -> (sha) { for_sha(sha).or(for_source_sha(sha)) }
    scope :for_ref, -> (ref) { where(ref: ref) }
    scope :for_id, -> (id) { where(id: id) }
    scope :for_iid, -> (iid) { where(iid: iid) }
    scope :created_after, -> (time) { where('ci_pipelines.created_at > ?', time) }
    scope :created_before_id, -> (id) { where('ci_pipelines.id < ?', id) }
    scope :before_pipeline, -> (pipeline) { created_before_id(pipeline.id).outside_pipeline_family(pipeline) }

    scope :outside_pipeline_family, ->(pipeline) do
      where.not(id: pipeline.same_family_pipeline_ids)
    end

    scope :with_reports, -> (reports_scope) do
      where('EXISTS (?)', ::Ci::Build.latest.with_reports(reports_scope).where('ci_pipelines.id=ci_builds.commit_id').select(1))
    end

    scope :with_only_interruptible_builds, -> do
      where('NOT EXISTS (?)',
        Ci::Build.where('ci_builds.commit_id = ci_pipelines.id')
                 .with_status(:running, :success, :failed)
                 .not_interruptible
      )
    end

    # Returns the pipelines in descending order (= newest first), optionally
    # limited to a number of references.
    #
    # ref - The name (or names) of the branch(es)/tag(s) to limit the list of
    #       pipelines to.
    # sha - The commit SHA (or mutliple SHAs) to limit the list of pipelines to.
    # limit - This limits a backlog search, default to 100.
    def self.newest_first(ref: nil, sha: nil, limit: 100)
      relation = order(id: :desc)
      relation = relation.where(ref: ref) if ref
      relation = relation.where(sha: sha) if sha

      if limit
        ids = relation.limit(limit).select(:id)
        relation = relation.where(id: ids)
      end

      relation
    end

    def self.latest_status(ref = nil)
      newest_first(ref: ref).pluck(:status).first
    end

    def self.latest_successful_for_ref(ref)
      newest_first(ref: ref).success.take
    end

    def self.latest_successful_for_sha(sha)
      newest_first(sha: sha).success.take
    end

    def self.latest_successful_for_refs(refs)
      relation = newest_first(ref: refs).success

      relation.each_with_object({}) do |pipeline, hash|
        hash[pipeline.ref] ||= pipeline
      end
    end

    # Returns a Hash containing the latest pipeline for every given
    # commit.
    #
    # The keys of this Hash are the commit SHAs, the values the pipelines.
    #
    # commits - The list of commit SHAs to get the pipelines for.
    # ref - The ref to scope the data to (e.g. "master"). If the ref is not
    #       given we simply get the latest pipelines for the commits, regardless
    #       of what refs the pipelines belong to.
    def self.latest_pipeline_per_commit(commits, ref = nil)
      p1 = arel_table
      p2 = arel_table.alias

      # This LEFT JOIN will filter out all but the newest row for every
      # combination of (project_id, sha) or (project_id, sha, ref) if a ref is
      # given.
      cond = p1[:sha].eq(p2[:sha])
        .and(p1[:project_id].eq(p2[:project_id]))
        .and(p1[:id].lt(p2[:id]))

      cond = cond.and(p1[:ref].eq(p2[:ref])) if ref
      join = p1.join(p2, Arel::Nodes::OuterJoin).on(cond)

      relation = where(sha: commits)
        .where(p2[:id].eq(nil))
        .joins(join.join_sources)

      relation = relation.where(ref: ref) if ref

      relation.each_with_object({}) do |pipeline, hash|
        hash[pipeline.sha] = pipeline
      end
    end

    def self.latest_successful_ids_per_project
      success.group(:project_id).select('max(id) as id')
    end

    def self.last_finished_for_ref_id(ci_ref_id)
      where(ci_ref_id: ci_ref_id).ci_sources.finished.order(id: :desc).select(:id).take
    end

    def self.truncate_sha(sha)
      sha[0...8]
    end

    def self.total_duration
      where.not(duration: nil).sum(:duration)
    end

    def self.internal_sources
      sources.reject { |source| source == "external" }.values
    end

    def self.bridgeable_statuses
      ::Ci::Pipeline::AVAILABLE_STATUSES - %w[created waiting_for_resource preparing pending]
    end

    def self.auto_devops_pipelines_completed_total
      @auto_devops_pipelines_completed_total ||= Gitlab::Metrics.counter(:auto_devops_pipelines_completed_total, 'Number of completed auto devops pipelines')
    end

    def stages_count
      statuses.select(:stage).distinct.count
    end

    def total_size
      statuses.count(:id)
    end

    def stages_names
      statuses.order(:stage_idx).distinct
        .pluck(:stage, :stage_idx).map(&:first)
    end

    def legacy_stage(name)
      stage = Ci::LegacyStage.new(self, name: name)
      stage unless stage.statuses_count.zero?
    end

    def ref_exists?
      project.repository.ref_exists?(git_ref)
    rescue Gitlab::Git::Repository::NoRepository
      false
    end

    def ordered_stages
      if ::Gitlab::Ci::Features.atomic_processing?(project)
        # The `Ci::Stage` contains all up-to date data
        # as atomic processing updates all data in-bulk
        stages
      elsif complete?
        # The `Ci::Stage` contains up-to date data only for `completed` pipelines
        # this is due to asynchronous processing of pipeline, and stages possibly
        # not updated inline with processing of pipeline
        stages
      else
        # In other cases, we need to calculate stages dynamically
        legacy_stages
      end
    end

    def legacy_stages_using_sql
      # TODO, this needs refactoring, see gitlab-foss#26481.
      stages_query = statuses
        .group('stage').select(:stage).order('max(stage_idx)')

      status_sql = statuses.latest.where('stage=sg.stage').legacy_status_sql

      warnings_sql = statuses.latest.select('COUNT(*)')
        .where('stage=sg.stage').failed_but_allowed.to_sql

      stages_with_statuses = CommitStatus.from(stages_query, :sg)
        .pluck('sg.stage', Arel.sql(status_sql), Arel.sql("(#{warnings_sql})"))

      stages_with_statuses.map do |stage|
        Ci::LegacyStage.new(self, Hash[%i[name status warnings].zip(stage)])
      end
    end

    def legacy_stages_using_composite_status
      stages = latest_statuses_ordered_by_stage.group_by(&:stage)

      stages.map do |stage_name, jobs|
        composite_status = Gitlab::Ci::Status::Composite
          .new(jobs)

        Ci::LegacyStage.new(self,
          name: stage_name,
          status: composite_status.status,
          warnings: composite_status.warnings?)
      end
    end

    def triggered_pipelines_with_preloads
      triggered_pipelines.preload(:source_job)
    end

    def legacy_stages
      if ::Gitlab::Ci::Features.composite_status?(project)
        legacy_stages_using_composite_status
      else
        legacy_stages_using_sql
      end
    end

    def valid_commit_sha
      if self.sha == Gitlab::Git::BLANK_SHA
        self.errors.add(:sha, " cant be 00000000 (branch removal)")
      end
    end

    def git_author_name
      strong_memoize(:git_author_name) do
        commit.try(:author_name)
      end
    end

    def git_author_email
      strong_memoize(:git_author_email) do
        commit.try(:author_email)
      end
    end

    def git_commit_message
      strong_memoize(:git_commit_message) do
        commit.try(:message)
      end
    end

    def git_commit_title
      strong_memoize(:git_commit_title) do
        commit.try(:title)
      end
    end

    def git_commit_full_title
      strong_memoize(:git_commit_full_title) do
        commit.try(:full_title)
      end
    end

    def git_commit_description
      strong_memoize(:git_commit_description) do
        commit.try(:description)
      end
    end

    def before_sha
      super || Gitlab::Git::BLANK_SHA
    end

    def short_sha
      Ci::Pipeline.truncate_sha(sha)
    end

    # NOTE: This is loaded lazily and will never be nil, even if the commit
    # cannot be found.
    #
    # Use constructs like: `pipeline.commit.present?`
    def commit
      @commit ||= Commit.lazy(project, sha)
    end

    def stuck?
      pending_builds.any?(&:stuck?)
    end

    def retryable?
      retryable_builds.any?
    end

    def cancelable?
      cancelable_statuses.any?
    end

    def auto_canceled?
      canceled? && auto_canceled_by_id?
    end

    def cancel_running(retries: nil)
      retry_optimistic_lock(cancelable_statuses, retries) do |cancelable|
        cancelable.find_each do |job|
          yield(job) if block_given?
          job.cancel
        end
      end
    end

    def auto_cancel_running(pipeline, retries: nil)
      update(auto_canceled_by: pipeline)

      cancel_running(retries: retries) do |job|
        job.auto_canceled_by = pipeline
      end
    end

    # rubocop: disable CodeReuse/ServiceClass
    def retry_failed(current_user)
      Ci::RetryPipelineService.new(project, current_user)
        .execute(self)
    end
    # rubocop: enable CodeReuse/ServiceClass

    def mark_as_processable_after_stage(stage_idx)
      builds.skipped.after_stage(stage_idx).find_each do |build|
        Gitlab::OptimisticLocking.retry_lock(build, &:process)
      end
    end

    def lazy_ref_commit
      return unless ::Gitlab::Ci::Features.pipeline_latest?

      BatchLoader.for(ref).batch do |refs, loader|
        next unless project.repository_exists?

        project.repository.list_commits_by_ref_name(refs).then do |commits|
          commits.each { |key, commit| loader.call(key, commits[key]) }
        end
      end
    end

    def latest?
      return false unless git_ref && commit.present?

      unless ::Gitlab::Ci::Features.pipeline_latest?
        return project.commit(git_ref) == commit
      end

      return false if lazy_ref_commit.nil?

      lazy_ref_commit.id == commit.id
    end

    def retried
      @retried ||= (statuses.order(id: :desc) - statuses.latest)
    end

    def coverage
      coverage_array = statuses.latest.map(&:coverage).compact
      if coverage_array.size >= 1
        '%.2f' % (coverage_array.reduce(:+) / coverage_array.size)
      end
    end

    def has_kubernetes_active?
      project.deployment_platform&.active?
    end

    def freeze_period?
      Ci::FreezePeriodStatus.new(project: project).execute
    end

    def has_warnings?
      number_of_warnings.positive?
    end

    def number_of_warnings
      BatchLoader.for(id).batch(default_value: 0) do |pipeline_ids, loader|
        ::Ci::Build.where(commit_id: pipeline_ids)
          .latest
          .failed_but_allowed
          .group(:commit_id)
          .count
          .each { |id, amount| loader.call(id, amount) }
      end
    end

    def needs_processing?
      statuses
        .where(processed: [false, nil])
        .latest
        .exists?
    end

    # TODO: this logic is duplicate with Pipeline::Chain::Config::Content
    # we should persist this is `ci_pipelines.config_path`
    def config_path
      return unless repository_source? || unknown_source?

      project.ci_config_path.presence || '.gitlab-ci.yml'
    end

    def has_yaml_errors?
      yaml_errors.present?
    end

    def add_error_message(content)
      add_message(:error, content)
    end

    def add_warning_message(content)
      add_message(:warning, content)
    end

    # We can't use `messages.error` scope here because messages should also be
    # read when the pipeline is not persisted. Using the scope will return no
    # results as it would query persisted data.
    def error_messages
      messages.select(&:error?)
    end

    def warning_messages
      messages.select(&:warning?)
    end

    # Manually set the notes for a Ci::Pipeline
    # There is no ActiveRecord relation between Ci::Pipeline and notes
    # as they are related to a commit sha. This method helps importing
    # them using the +Gitlab::ImportExport::Project::RelationFactory+ class.
    def notes=(notes)
      notes.each do |note|
        note[:id] = nil
        note[:commit_id] = sha
        note[:noteable_id] = self['id']
        note.save!
      end
    end

    def notes
      project.notes.for_commit_id(sha)
    end

    def set_status(new_status)
      retry_optimistic_lock(self) do
        case new_status
        when 'created' then nil
        when 'waiting_for_resource' then request_resource
        when 'preparing' then prepare
        when 'pending' then enqueue
        when 'running' then run
        when 'success' then succeed
        when 'failed' then drop
        when 'canceled' then cancel
        when 'skipped' then skip
        when 'manual' then block
        when 'scheduled' then delay
        else
          raise Ci::HasStatus::UnknownStatusError,
                "Unknown status `#{new_status}`"
        end
      end
    end

    def update_legacy_status
      set_status(latest_builds_status.to_s)
    end

    def protected_ref?
      strong_memoize(:protected_ref) { project.protected_for?(git_ref) }
    end

    def legacy_trigger
      strong_memoize(:legacy_trigger) { trigger_requests.first }
    end

    def persisted_variables
      Gitlab::Ci::Variables::Collection.new.tap do |variables|
        break variables unless persisted?

        variables.append(key: 'CI_PIPELINE_ID', value: id.to_s)
        variables.append(key: 'CI_PIPELINE_URL', value: Gitlab::Routing.url_helpers.project_pipeline_url(project, self))
      end
    end

    def predefined_variables
      Gitlab::Ci::Variables::Collection.new.tap do |variables|
        variables.append(key: 'CI_PIPELINE_IID', value: iid.to_s)
        variables.append(key: 'CI_PIPELINE_SOURCE', value: source.to_s)

        variables.append(key: 'CI_CONFIG_PATH', value: config_path)

        variables.concat(predefined_commit_variables)

        if merge_request?
          variables.append(key: 'CI_MERGE_REQUEST_EVENT_TYPE', value: merge_request_event_type.to_s)
          variables.append(key: 'CI_MERGE_REQUEST_SOURCE_BRANCH_SHA', value: source_sha.to_s)
          variables.append(key: 'CI_MERGE_REQUEST_TARGET_BRANCH_SHA', value: target_sha.to_s)
          variables.concat(merge_request.predefined_variables)
        end

        variables.append(key: 'CI_KUBERNETES_ACTIVE', value: 'true') if has_kubernetes_active?
        variables.append(key: 'CI_DEPLOY_FREEZE', value: 'true') if freeze_period?

        if external_pull_request_event? && external_pull_request
          variables.concat(external_pull_request.predefined_variables)
        end
      end
    end

    def predefined_commit_variables
      Gitlab::Ci::Variables::Collection.new.tap do |variables|
        variables.append(key: 'CI_COMMIT_SHA', value: sha)
        variables.append(key: 'CI_COMMIT_SHORT_SHA', value: short_sha)
        variables.append(key: 'CI_COMMIT_BEFORE_SHA', value: before_sha)
        variables.append(key: 'CI_COMMIT_REF_NAME', value: source_ref)
        variables.append(key: 'CI_COMMIT_REF_SLUG', value: source_ref_slug)
        variables.append(key: 'CI_COMMIT_BRANCH', value: ref) if branch?
        variables.append(key: 'CI_COMMIT_TAG', value: ref) if tag?
        variables.append(key: 'CI_COMMIT_MESSAGE', value: git_commit_message.to_s)
        variables.append(key: 'CI_COMMIT_TITLE', value: git_commit_full_title.to_s)
        variables.append(key: 'CI_COMMIT_DESCRIPTION', value: git_commit_description.to_s)
        variables.append(key: 'CI_COMMIT_REF_PROTECTED', value: (!!protected_ref?).to_s)

        # legacy variables
        variables.append(key: 'CI_BUILD_REF', value: sha)
        variables.append(key: 'CI_BUILD_BEFORE_SHA', value: before_sha)
        variables.append(key: 'CI_BUILD_REF_NAME', value: source_ref)
        variables.append(key: 'CI_BUILD_REF_SLUG', value: source_ref_slug)
        variables.append(key: 'CI_BUILD_TAG', value: ref) if tag?
      end
    end

    def queued_duration
      return unless started_at

      seconds = (started_at - created_at).to_i
      seconds unless seconds.zero?
    end

    def update_duration
      return unless started_at

      self.duration = Gitlab::Ci::Pipeline::Duration.from_pipeline(self)
    end

    def execute_hooks
      data = pipeline_data
      project.execute_hooks(data, :pipeline_hooks)
      project.execute_services(data, :pipeline_hooks)
    end

    # All the merge requests for which the current pipeline runs/ran against
    def all_merge_requests
      @all_merge_requests ||=
        if merge_request?
          MergeRequest.where(id: merge_request_id)
        else
          MergeRequest.where(source_project_id: project_id, source_branch: ref)
            .by_commit_sha(sha)
        end
    end

    def all_merge_requests_by_recency
      all_merge_requests.order(id: :desc)
    end

    # If pipeline is a child of another pipeline, include the parent
    # and the siblings, otherwise return only itself and children.
    def same_family_pipeline_ids
      parent = parent_pipeline || self
      [parent.id] + parent.child_pipelines.pluck(:id)
    end

    def bridge_triggered?
      source_bridge.present?
    end

    def bridge_waiting?
      source_bridge&.dependent?
    end

    def child?
      parent_pipeline.present?
    end

    def parent?
      child_pipelines.exists?
    end

    def created_successfully?
      persisted? && failure_reason.blank?
    end

    def detailed_status(current_user)
      Gitlab::Ci::Status::Pipeline::Factory
        .new(self, current_user)
        .fabricate!
    end

    def find_job_with_archive_artifacts(name)
      builds.latest.with_downloadable_artifacts.find_by_name(name)
    end

    def latest_builds_with_artifacts
      # We purposely cast the builds to an Array here. Because we always use the
      # rows if there are more than 0 this prevents us from having to run two
      # queries: one to get the count and one to get the rows.
      @latest_builds_with_artifacts ||= builds.latest.with_artifacts_not_expired.to_a
    end

    def latest_report_builds(reports_scope = ::Ci::JobArtifact.with_reports)
      builds.latest.with_reports(reports_scope)
    end

    def has_reports?(reports_scope)
      complete? && latest_report_builds(reports_scope).exists?
    end

    def test_report_summary
      Gitlab::Ci::Reports::TestReportSummary.new(latest_builds_report_results)
    end

    def test_reports
      Gitlab::Ci::Reports::TestReports.new.tap do |test_reports|
        latest_report_builds(Ci::JobArtifact.test_reports).preload(:project).find_each do |build|
          build.collect_test_reports!(test_reports)
        end
      end
    end

    def test_reports_count
      Rails.cache.fetch(['project', project.id, 'pipeline', id, 'test_reports_count'], force: false) do
        test_reports.total_count
      end
    end

    def accessibility_reports
      Gitlab::Ci::Reports::AccessibilityReports.new.tap do |accessibility_reports|
        builds.latest.with_reports(Ci::JobArtifact.accessibility_reports).each do |build|
          build.collect_accessibility_reports!(accessibility_reports)
        end
      end
    end

    def coverage_reports
      Gitlab::Ci::Reports::CoverageReports.new.tap do |coverage_reports|
        latest_report_builds(Ci::JobArtifact.coverage_reports).each do |build|
          build.collect_coverage_reports!(coverage_reports)
        end
      end
    end

    def terraform_reports
      ::Gitlab::Ci::Reports::TerraformReports.new.tap do |terraform_reports|
        latest_report_builds(::Ci::JobArtifact.terraform_reports).each do |build|
          build.collect_terraform_reports!(terraform_reports)
        end
      end
    end

    def has_archive_artifacts?
      complete? && builds.latest.with_existing_job_artifacts(Ci::JobArtifact.archive.or(Ci::JobArtifact.metadata)).exists?
    end

    def has_exposed_artifacts?
      complete? && builds.latest.with_exposed_artifacts.exists?
    end

    def branch_updated?
      strong_memoize(:branch_updated) do
        push_details.branch_updated?
      end
    end

    # Returns the modified paths.
    #
    # The returned value is
    # * Array: List of modified paths that should be evaluated
    # * nil: Modified path can not be evaluated
    def modified_paths
      strong_memoize(:modified_paths) do
        if merge_request?
          merge_request.modified_paths
        elsif branch_updated?
          push_details.modified_paths
        end
      end
    end

    def all_worktree_paths
      strong_memoize(:all_worktree_paths) do
        project.repository.ls_files(sha)
      end
    end

    def top_level_worktree_paths
      strong_memoize(:top_level_worktree_paths) do
        project.repository.tree(sha).blobs.map(&:path)
      end
    end

    def default_branch?
      ref == project.default_branch
    end

    def merge_request?
      merge_request_id.present?
    end

    def detached_merge_request_pipeline?
      merge_request? && target_sha.nil?
    end

    def legacy_detached_merge_request_pipeline?
      detached_merge_request_pipeline? && !merge_request_ref?
    end

    def merge_request_pipeline?
      merge_request? && target_sha.present?
    end

    def merge_request_ref?
      MergeRequest.merge_request_ref?(ref)
    end

    def matches_sha_or_source_sha?(sha)
      self.sha == sha || self.source_sha == sha
    end

    def triggered_by?(current_user)
      user == current_user
    end

    def source_ref
      if merge_request?
        merge_request.source_branch
      else
        ref
      end
    end

    def source_ref_slug
      Gitlab::Utils.slugify(source_ref.to_s)
    end

    def find_stage_by_name!(name)
      stages.find_by!(name: name)
    end

    def full_error_messages
      errors ? errors.full_messages.to_sentence : ""
    end

    def merge_request_event_type
      return unless merge_request?

      strong_memoize(:merge_request_event_type) do
        if merge_request_pipeline?
          :merged_result
        elsif detached_merge_request_pipeline?
          :detached
        end
      end
    end

    def persistent_ref
      @persistent_ref ||= PersistentRef.new(pipeline: self)
    end

    def find_successful_build_ids_by_names(names)
      statuses.latest.success.where(name: names).pluck(:id)
    end

    def cacheable?
      Ci::PipelineEnums.ci_config_sources.key?(config_source.to_sym)
    end

    def source_ref_path
      if branch? || merge_request?
        Gitlab::Git::BRANCH_REF_PREFIX + source_ref.to_s
      elsif tag?
        Gitlab::Git::TAG_REF_PREFIX + source_ref.to_s
      end
    end

    # Set scheduling type of processables if they were created before scheduling_type
    # data was deployed (https://gitlab.com/gitlab-org/gitlab/-/merge_requests/22246).
    def ensure_scheduling_type!
      processables.populate_scheduling_type!
    end

    def ensure_ci_ref!
      return unless Gitlab::Ci::Features.pipeline_fixed_notifications?

      self.ci_ref = Ci::Ref.ensure_for(self)
    end

    private

    def add_message(severity, content)
      return unless Gitlab::Ci::Features.store_pipeline_messages?(project)

      messages.build(severity: severity, content: content)
    end

    def pipeline_data
      Gitlab::DataBuilder::Pipeline.build(self)
    end

    def push_details
      strong_memoize(:push_details) do
        Gitlab::Git::Push.new(project, before_sha, sha, git_ref)
      end
    end

    def git_ref
      strong_memoize(:git_ref) do
        if merge_request?
          ##
          # In the future, we're going to change this ref to
          # merge request's merged reference, such as "refs/merge-requests/:iid/merge".
          # In order to do that, we have to update GitLab-Runner's source pulling
          # logic.
          # See https://gitlab.com/gitlab-org/gitlab-runner/merge_requests/1092
          Gitlab::Git::BRANCH_REF_PREFIX + ref.to_s
        else
          super
        end
      end
    end

    def latest_builds_status
      return 'failed' unless yaml_errors.blank?

      statuses.latest.slow_composite_status(project: project) || 'skipped'
    end

    def keep_around_commits
      return unless project

      project.repository.keep_around(self.sha, self.before_sha)
    end
  end
end

Ci::Pipeline.prepend_if_ee('EE::Ci::Pipeline')
