# frozen_string_literal: true
require_relative '../test_helper'

SingleCov.covered!

describe JobQueue do
  # JobExecution is very complicated ... so we stub it out
  fake_execution = Class.new do
    attr_reader :id
    def initialize(id)
      @id = id
    end

    def on_complete(&block)
      @on_complete = block
    end

    def finish
      @on_complete.call
    end
  end

  def with_active_job
    job_execution.expects(:start!)

    with_job_execution do
      subject.add(job_execution)
      yield
    end
  end

  def with_a_queued_job
    job_execution.stubs(:start!)

    with_job_execution do
      subject.add(job_execution, queue: :x)
      subject.add(queued_job_execution, queue: :x)
      yield
    end
  end

  let(:subject) { JobQueue.new }
  let(:job_execution) { fake_execution.new(1) }
  let(:queued_job_execution) { fake_execution.new(2) }

  before do
    JobExecution.stubs(:new).returns(job_execution).returns(queued_job_execution)
  end

  describe "#add" do
    it 'immediately starts a job when active is empty' do
      with_active_job do
        assert subject.active?(1)
        refute subject.queued?(1)
        subject.find_by_id(1).must_equal(job_execution)
      end
    end

    it 'starts parallel jobs when they are in different queues' do
      [job_execution, queued_job_execution].each do |job|
        job.expects(:start!)

        with_job_execution { subject.add(job) }

        assert subject.active?(job.id)
      end
    end

    it 'does not start a job if job execution is disabled' do
      JobExecution.enabled = false
      job_execution.expects(:start!).never

      subject.add(job_execution)

      refute subject.active?(1)
      refute subject.queued?(1)
      refute subject.find_by_id(1)
    end

    it 'does not queue a job if job execution is disabled' do
      with_active_job do
        JobExecution.enabled = false
        subject.add(queued_job_execution, queue: :x)

        refute subject.active?(2)
        refute subject.queued?(2)
        refute subject.find_by_id(2)
      end
    end

    describe 'with queued job' do
      around { |t| with_a_queued_job(&t) }

      it 'has a queued job' do
        refute subject.active?(2)
        assert subject.queued?(2)
        subject.find_by_id(2).must_equal(queued_job_execution)
      end

      it 'starts then next job when active job completes' do
        queued_job_execution.expects(:start!)

        with_job_execution { job_execution.finish }

        refute subject.find_by_id(1)
        assert subject.active?(2)
        refute subject.queued?(2)
      end

      it 'does not start the next job when job execution is disabled' do
        JobExecution.enabled = false
        queued_job_execution.expects(:start!).never

        job_execution.finish

        refute subject.find_by_id(1)
        refute subject.active?(2)
        assert subject.queued?(2)
      end

      it 'does not start the next job when queue is empty' do
        queued_job_execution.expects(:start!)

        with_job_execution do
          job_execution.finish
          queued_job_execution.finish
        end

        refute subject.find_by_id(1)
        refute subject.find_by_id(2)

        # make sure we cleaned up nicely
        subject.instance_variable_get(:@active).must_equal({})
        subject.instance_variable_get(:@queue).must_equal({})
      end
    end
  end

  describe "#clear" do
    it "removes all queues" do
      with_a_queued_job do
        queued_job_execution.expects(:close)
        subject.clear
        refute subject.queued?(queued_job_execution)
      end
    end

    it "keeps active since they will complete on their own" do
      with_active_job do
        subject.clear
        assert subject.active?(1)
      end
    end
  end
end
