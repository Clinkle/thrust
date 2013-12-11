require File.expand_path('../xcrun', __FILE__)

class ThrustConfig
  attr_reader :project_root, :config, :build_dir
  THRUST_VERSION = 0.1

  def self.make(relative_project_root, config_file)
    new(relative_project_root, YAML.load_file(config_file), XCRun.new)
  end

  def initialize(relative_project_root, config, xcrun)
    @project_root = File.expand_path(relative_project_root)
    relative_build_dir = config['build_dir'] ? config['build_dir'] : 'build'
    @build_dir = File.join(project_root, relative_build_dir)
    @config = config
    @xcrun = xcrun
    verify_configuration(@config)
    fill_in_configuration_defaults(@config)
  end

  def get_app_name_from(build_dir)
    full_app_path = Dir.glob(build_dir + '/*.app').first
    raise "No build product found!" unless full_app_path
    app_file_name = full_app_path.split('/').last
    return app_file_name.gsub('.app','')
  end

  def build_dir_for(configuration)
    "#{build_dir}/#{configuration}-iphoneos"
  end

  # Xcode 4.3 stores its /Developer inside /Applications/Xcode.app, Xcode 4.2 stored it in /Developer
  def xcode_developer_dir
    `xcode-select -print-path`.strip
  end

  def system_or_exit(cmd, stdout = nil)
    STDERR.puts "Executing #{cmd}"
    cmd += " >#{stdout}" if stdout
    system(cmd) or raise '******** Build failed ********'
  end

  def run(cmd)
    STDERR.puts "Executing #{cmd}"
    `#{cmd}`
  end

  def kill_simulator
    system %q[killall -m -KILL "gdb"]
    system %q[killall -m -KILL "otest"]
    system %q[killall -m -KILL "iPhone Simulator"]
  end

  def clean_simulator
    system %q[rm -rf ~/Library/Application\ Support/iPhone\ Simulator/]
  end

  def xcode_build(build_configuration, sdk, target)
    run_xcode('clean build', build_configuration, sdk, target)
  end

  def xcode_clean(build_configuration)
    run_xcode('clean', build_configuration)
  end

  def xcode_build_configurations
    output = `xcodebuild -project #{config['project_name']}.xcodeproj -list`
    match = /Build Configurations:(.+?)\n\n/m.match(output)
    if match
      match[1].strip.split("\n").map { |line| line.strip }
    else
      []
    end
  end

  def xcode_package(build_configuration)
    build_dir = build_dir_for(build_configuration)
    app_name = get_app_name_from(build_dir)
    xcrun.call(build_dir, app_name, config['identity'])
  end

  def run_cedar(build_configuration, target, sdk, device)
    binary = config['sim_binary']
    sim_dir = File.join(build_dir, "#{build_configuration}-iphonesimulator", "#{target}.app")

    reporter_classes = "CDRDefaultReporter"
    reporter_classes += ",CDRJUnitXMLReporter" if config['spec_reports_dir']
    env_vars = {
      'CFFIXED_USER_HOME' => "#{Dir.tmpdir}",
      'CEDAR_HEADLESS_SPECS' => 1,
      'CEDAR_REPORTER_CLASS' => reporter_classes
    }
    env_vars['CEDAR_JUNIT_XML_FILE'] = spec_results_file(target) if config['spec_reports_dir']

    if binary =~ /waxsim$/
      command = [ binary, "-s #{sdk} -f #{device}" ]
      env_vars.each do |k, v|
        command << "-e #{k}=#{v}"
      end
      command << "#{sim_dir}"
    elsif binary =~ /ios-sim$/
      command = [ binary, "launch #{sim_dir}", "--sdk #{sdk} --family #{device} --retina --tall" ]
      env_vars.each do |k, v|
        command << "--setenv #{k}=#{v}"
      end
    else
      puts "Unknown binary for running specs: '#{binary}'"
      exit(1)
    end

    grep_cmd_for_failure(command.join(" "))
  end

  def spec_results_file(target)
    "#{project_root}/#{config['spec_reports_dir']}/#{target}.xml"
  end

  def update_version(release)
    run_git_with_message('Changes version to $(agvtool what-marketing-version -terse)') do
      version = run "agvtool what-marketing-version -terse | head -n1 |cut -f2 -d\="
      STDERR.puts "version !#{version}!"
      well_formed_version_regex = %r{^\d+(\.\d+)?(\.\d+)?$}
      if (match = well_formed_version_regex.match(version))
        STDERR.puts "found match #{match.inspect}"
        major, minor, patch = (version.split(".").map(&:to_i) + [0, 0, 0]).first(3)
        case(release)
        when :major then new_build_version(major + 1, 0, 0)
        when :minor then new_build_version(major, minor + 1, 0)
        when :patch then new_build_version(major, minor, patch + 1)
        when :clear then new_build_version(major, minor, patch)
        end
      else
        raise "Unknown version #{version} it should match major.minor.patch"
      end
    end
  end

  def new_marketing_version(*markers)
    version = markers.join(".")
    system_or_exit "agvtool new-marketing-version \"#{version}\""
  end

  def new_build_version(*markers)
    version = markers.join(".")
    system_or_exit "agvtool new-version \"#{version}\""
  end

  def run_git_with_message(message, &block)
    if ENV['IGNORE_GIT']
      STDERR.puts 'WARNING NOT CHECKING FOR CLEAN WORKING DIRECTORY'
      block.call
    else
      check_for_clean_working_tree
      current_branch = `git rev-parse --abbrev-ref HEAD`.chomp
      STDERR.puts "Checking that the #{current_branch} branch is up to date..."
      system_or_exit "git fetch && git diff --quiet HEAD origin/#{current_branch}"
      block.call
      system_or_exit "git commit -am \"#{message}\" && git push origin head"
    end
  end

  def check_for_clean_working_tree
    if ENV['IGNORE_GIT']
      STDERR.puts 'WARNING NOT CHECKING FOR CLEAN WORKING DIRECTORY'
    else
      STDERR.puts 'Checking for clean working tree...'
      system_or_exit 'git diff-index --quiet HEAD'
    end
  end

  private

  attr_reader :xcrun

  def run_xcode(build_command, build_configuration, sdk = nil, target = nil)
    if (config['use_workspace'] && target)
      project_selector = "-workspace \"#{config['project_name']}.xcworkspace\""
      target_selector = "-scheme #{target}"
    else
      project_selector = "-project \"#{config['project_name']}.xcodeproj\""
      target_selector = target ? "-target #{target}" : "-alltargets"
    end
    system_or_exit(
      [
        "set -o pipefail &&",
        "xcodebuild",
        project_selector,
        target_selector,
        "-configuration #{build_configuration}",
        sdk ? "-sdk #{sdk}" : "",
        "#{build_command}",
        "2>&1",
        "| grep -v 'backing file'"
      ].join(" "),
        output_file("#{build_configuration}-#{build_command.gsub(' ','_')}")
    )
  end

  def output_file(target)
    output_dir = if ENV['IS_CI_BOX']
                   ENV['CC_BUILD_ARTIFACTS']
                 else
                   FileUtils.mkpath(build_dir) unless File.exists?(build_dir)
                   build_dir
                 end

    output_file = File.join(output_dir, "#{target}.output")
    STDERR.puts "Output: #{output_file}"
    output_file
  end

  def grep_cmd_for_failure(cmd)
    STDERR.puts "Executing #{cmd} and checking for FAILURE"
    result = %x[#{cmd} 2>&1]
    STDERR.puts "Results:"
    STDERR.puts result

    if !result.include?("Finished") || result.include?("FAILURE") || result.include?("EXCEPTION")
      exit(1)
    else
      exit(0)
    end
  end

  def verify_configuration(config)
    config['thrust_version'] ||= 0
    if config['thrust_version'] < THRUST_VERSION
      fail "Invalid configuration. Have you updated thrust recently? Your thrust.yml specifies version #{config['thrust_version']}, but thrust is at version #{THRUST_VERSION} see README for details."
    end
  end

  def fill_in_configuration_defaults(config)
    config['spec_targets'].each do |task_name, info|
      info['device'] ||= 'iphonesimulator'
    end
  end
end
