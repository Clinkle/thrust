require 'yaml'
require File.expand_path('../../thrust_config', __FILE__)
require File.expand_path('../../ipa_re_signer', __FILE__)
require 'tempfile'
require 'date'

class VersionNumber
  include Comparable
  attr_accessor :number

  def initialize(number)
    @number = number
  end

  def self.fromDate(date)
    major = (date.year - 2011)
    minor = date.month
    monday_based_wday = (date.wday + 7 - 1) % 7
    previous_monday = date.mday - monday_based_wday
    patch = (previous_monday / 7.0).ceil
    subpatch = (((date.wday + 7) - 1) % 7)
    extra = 0
    self.new([major, minor, patch, subpatch, extra].join('.'))
  end

  def <=>(another_version)
    my_subversions = self.number.split('.')
    their_subversions = another_version.number.split('.')
    i_max = [my_subversions.count, their_subversions.count].max
    (0..i_max).each do |i|
      my_sub = my_subversions[i] || 0
      my_sub = my_sub.to_i
      their_sub = their_subversions[i] || 0
      their_sub = their_sub.to_i
      return my_sub <=> their_sub unless my_sub == their_sub
    end
    return 0
  end

  def to_s
    "Version Number #{@number}"
  end

  def make_minimum_greater_than(other)
    original_digits = self.number.split('.')
    (1..original_digits.length).each do |num_digits|
      self.number = (original_digits[0...num_digits]).join('.')
      break if other < self
    end
    self
  end

  def increment_last
    *head, last = self.number.split('.')
    head << (last.to_i + 1).to_s
    self.number = head.join('.')
  end
end

@thrust = ThrustConfig.make(Dir.getwd, File.join(Dir.getwd, 'thrust.yml'))

desc "show the current build"
task :current_version do
  @thrust.system_or_exit("agvtool what-version -terse")
end

namespace :bump do
  desc 'Bumps the marketing version number'
  task :marketing do
    @thrust.run_git_with_message 'Bumped marketing version to $(agvtool what-marketing-version -terse)' do
      current_version_string = `agvtool what-marketing-version -terse`.chomp
      current_version = VersionNumber.new(current_version_string)
      todays_version = VersionNumber.fromDate(Date.today)
      todays_version.make_minimum_greater_than(current_version)
      if todays_version == current_version
        todays_version.increment_last
      end
      @thrust.new_marketing_version(todays_version.number)
    end
  end

  desc 'Bumps the build'
  task :build do
    @thrust.run_git_with_message 'Bumped build version to $(agvtool what-version -terse)' do
      current_version_string = `agvtool what-version -terse`.chomp
      current_version = VersionNumber.new(current_version_string)
      todays_version = VersionNumber.fromDate(Date.today)
      if todays_version == current_version
        todays_version.increment_last
      end
      @thrust.new_build_version(todays_version.number)
    end
  end
end

namespace :testflight do
  @thrust.config['distributions'].each do |task_name, info|
    desc "Deploy build to testflight #{info['team']} team (use NOTIFY=false to prevent team notification)"
    task task_name, :provision_search_query do |task, args|
      @team_token = info['token']
      @distribution_list = info['default_list']
      @target = info['target'].nil? ? @thrust.config['app_name'] : info['target']
      @configuration = info['configuration']
      @bumps_build_number = info['increments_build_number'].nil? ? true : info['increments_build_number']
      @configured = true
      Rake::Task["testflight:deploy"].invoke(args[:provision_search_query])
    end
  end

  task :deploy, :provision_search_query do |task, args|
    raise "You need to run a distribution configuration." unless @configured
    team_token = @team_token
    distribution_list = @distribution_list
    build_configuration = @configuration
    build_dir = @thrust.build_dir_for(build_configuration)
    target = @target

    if @bumps_build_number
      Rake::Task["bump:build"].invoke
    else
      @thrust.check_for_clean_working_tree
    end

    STDERR.puts "Killing simulator..."
    @thrust.kill_simulator
    STDERR.puts "Building..."
    @thrust.xcode_build(build_configuration, 'iphoneos', target)

    app_name = @thrust.get_app_name_from(build_dir)

    STDERR.puts "Packaging..."
    ipa_file = @thrust.xcode_package(build_configuration)

    ipa_file = IpaReSigner.make(ipa_file, @thrust.config['identity'], args[:provision_search_query]).call

    STDERR.puts "Zipping dSYM..."
    dsym_path = "#{build_dir}/#{app_name}.app.dSYM"
    zipped_dsym_path = "#{dsym_path}.zip"
    @thrust.system_or_exit "zip -r -T -y '#{zipped_dsym_path}' '#{dsym_path}'"
    STDERR.puts "Done!"

    print "Deploy Notes: "
    message = STDIN.gets
    message += "\n" + `git log HEAD^..HEAD`
    message_file = Tempfile.new("deploy_notes")
    message_file << message
    @thrust.system_or_exit [
     "curl http://testflightapp.com/api/builds.json",
     "-F file=@#{ipa_file}",
     "-F dsym=@#{zipped_dsym_path}",
     "-F api_token='#{@thrust.config['api_token']}'",
     "-F team_token='#{team_token}'",
     "-F notes=@#{message_file.path}",
     "-F notify=#{(ENV['NOTIFY'] || 'true').downcase.capitalize}",
     ("-F distribution_lists='#{distribution_list}'" if distribution_list)
    ].compact.join(' ')
    end
end
