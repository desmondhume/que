# frozen_string_literal: true

module Que
  class Worker
    # Defines the time a worker will wait before checking Postgres for its next job
    WAKE_INTERVAL = 5
    JOB_INSTANCE_FIELDS = %i[queue priority run_at job_id].freeze

    def initialize(queue, wake_interval: WAKE_INTERVAL)
      @queue  = queue || ''
      @wake_interval = wake_interval
    end

    def work_loop
      @stop = false

      loop do
        case work
        when :job_not_found, :error then sleep(@wake_interval)
        when :job_worked then nil # immediately find a new job to work
        end

        break if @stop
      end
    end

    def work
      Que.adapter.checkout do
        with_locked_job do |job|
          return :job_not_found if job.nil?

          # Check that the job hasn't just been worked by another worker (it's possible to
          # lock a job that's just been destroyed because pg locks don't obey MVCC). If it
          # has been worked, act as if we've worked it.
          return :job_worked unless job_exists?(job)

          begin
            class_for(job[:job_class]).new(job).run_and_destroy(*job[:args])
          rescue => error
            handle_job_failure(error, job)
          end
          :job_worked
        end
      end
    rescue PG::Error => _error
      # In the event that our Postgres connection is bad, we don't want that error to halt
      # the work loop. Instead, we should let the work loop sleep and retry.
      :error
    end

    def stop!
      @stop = true
    end

    private

    # Set the error and retry with back-off
    def handle_job_failure(error, job)
      count = job[:error_count].to_i + 1

      Que.execute(
        :set_error, [
          count,
          count ** 4 + 3, # exponentially back off when retrying failures
          "#{error.message}\n#{error.backtrace.join("\n")}",
          *job.values_at(*JOB_INSTANCE_FIELDS)
        ]
      )
    end

    def with_locked_job
      job = Que.execute(:lock_job, [@queue]).first
      yield job
    ensure
      Que.execute("SELECT pg_advisory_unlock($1)", [job[:job_id]]) if job
    end

    def job_exists?(job)
      Que.execute(:check_job, job.values_at(*JOB_INSTANCE_FIELDS)).any?
    end

    def class_for(string)
      Que.constantize(string)
    end
  end
end
