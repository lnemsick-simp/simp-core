# simp-core additions to dep targets
# This is a playground for tasks that may eventually be moved to simp-rake-helpers
#
require 'pager'
require 'tmpdir'
require 'json'

module Simp ; end

module Simp::SimpCoreDepsHelper

  def changelog_diff(component_dir, prev_version)
    diff = nil
    Dir.chdir(component_dir) do
      if File.exist?('CHANGELOG')
        if prev_version
          cmd = "git diff #{prev_version} CHANGELOG"
        else
          cmd = 'cat CHANGELOG'
        end
        diff = `#{cmd}`
      elsif Dir.exist?('build')
        spec_files = Dir.glob('build/*.spec')
        unless spec_files.empty?
          spec_file = spec_files.first
          if prev_version
            cmd = "git diff #{prev_version} #{spec_file}"
          else
            cmd = "cat #{spec_file}"
          end
          specfile_diff = `#{cmd}`
          # only want changelog changes in spec file
          diff = specfile_diff.split('%changelog').last
        end
      end
    end
    if diff.nil?
      diff = "WARNING: Could not find CHANGELOG or RPM spec file in #{component_dir}"
    end
    diff
  end

  def generate_full_acceptance_matrix(test_info, puppet_versions, include_fips = true)
    component = test_info[:component]
    return [ [component, 'NONE', 'N/A', 'N/A', 'N/A'] ] if test_info[:suites].empty?
    tests = []
    test_info[:suites].each do |suite, config|
      config[:nodesets].each do |nodeset|
        puppet_versions.each do |puppet_version|
          tests << [ component, suite, nodeset, puppet_version, 'disabled' ]
          if include_fips
            tests << [ component, suite, nodeset, puppet_version, 'enabled' ]
          end
        end
      end
    end
    tests
  end

  def get_acceptance_test_info(component_dir)
    test_info = {
      :component => File.basename(component_dir),
      :suites    => {}
    }

    Dir.chdir(component_dir) do
      suites = Dir.glob('spec/acceptance/suites/*')
      suites.delete_if { |x| ! File.directory?(x) }

      global_nodeset_dir = 'spec/acceptance/nodesets'
      suites.each do |suite_dir|
        nodeset_dir = File.join(suite_dir, 'nodesets')
        if Dir.exist?(nodeset_dir)
          nodesets = Dir.glob("#{nodeset_dir}/*yml")
        else
          nodesets = Dir.glob("#{global_nodeset_dir}/*yml")
        end
        nodesets.delete_if { |nodeset| File.symlink?(nodeset) }

        suite = File.basename(suite_dir)
        test_info[:suites][suite] = {
          :nodesets => nodesets.map {|nodeset| File.basename(nodeset, '.yml') }
        }

        if suite != 'default'
          test_meta_file = File.join(suite_dir, 'metadata.yml')
          if File.exist?(test_meta_file)
            test_meta = YAML.load(File.read(test_meta_file))
            if test_meta['default_run']
              test_info[:suites][suite][:added_to_default] = true
            end
          end
        end
      end
    end
    test_info
  end

  def get_acceptance_test_matrix(component_dir)
    test_info = get_acceptance_test_info(component_dir)
    generate_full_acceptance_matrix(test_info, ['5.5.10', '6'], true)
  end

  def get_gitlab_acceptance_test_matrix(component_dir)
    gitlab_yaml_file = File.join(component_dir, '.gitlab-ci.yml')
    component = File.basename(component_dir)
    unless File.exist?(gitlab_yaml_file)
      return [ ['N/A'], [ [component, 'NONE', 'N/A', 'N/A', 'N/A'] ] ]
    end

    gitlab_yaml = YAML.load(File.read(gitlab_yaml_file))
    tests = []
    puppet_versions = []
    gitlab_yaml.each do |key,value|
      next unless (value.is_a?(Hash) && value.has_key?('script'))
      next unless (value.has_key?('stage') && (value['stage'] == 'acceptance'))

      if value.has_key?('variables') && value['variables'].has_key?('PUPPET_VERSION')
        puppet_version = value['variables']['PUPPET_VERSION']
      else
        puppet_version = 'N/A'
      end

      suite = nil
      nodeset = nil
      fips = nil
      value['script'].each do |line|
        next unless line.include? 'beaker:suites'
        if line.include?('[')
          match = line.match(/beaker:suites\[(.*)(,.*)?\]/)
          suite = match[1]
          nodeset = match[2]
        else
          suites = Dir.glob("#{component_dir}/spec/acceptance/suites/*")
          suites.delete_if { |x| ! File.directory?(x) }
          if suites.size > 1
            suite = :default_with_additions
          else
            suite = 'default'
          end
          nodeset = 'default'
        end

        if line.include?('BEAKER_fips=yes')
          fips = 'enabled'
        else
          fips = 'disabled'
        end
      end
      next unless suite

      suite.strip! if suite.is_a?(String)
      nodeset = nodeset.nil? ? 'default' : nodeset.strip
      puppet_versions << puppet_version
      tests << [ component, suite, nodeset, puppet_version, fips ]
    end
    tests = [ [component, 'NONE', 'N/A', 'N/A', 'N/A'] ] if tests.empty?
    [ puppet_versions.uniq!, tests]
  end

  def simp_component?(component_dir)
    result = false
    metadata_json_file = File.join(component_dir, 'metadata.json')
    if File.exist?(metadata_json_file)
      metadata = JSON.load(File.read(metadata_json_file))
      if metadata['name'].split('-').first == 'simp'
        result = true
      end
    else
      build_dir = File.join(component_dir, 'build')
      if Dir.exist?(build_dir)
        spec_files = Dir.glob("#{build_dir}/*.spec")
        if spec_files.size == 1
          result = true
        end
      end
    end

    result
  end
end


include Pager
include Simp::SimpCoreDepsHelper


namespace :deps do
  desc <<-EOM
  Remove all checked-out dependency repos

  Uses specified Puppetfile to identify the checked-out repos.

  Arguments:
    * :suffix       => The Puppetfile suffix to use (Default => 'tracking')
    * :remove_cache => Whether to remove the R10K cache after removing the
                       checked-out repos (Default => false)
  EOM
  task :clean, [:suffix,:remove_cache] do |t,args|
    include Pager

    args.with_defaults(:suffix => 'tracking')
    args.with_defaults(:remove_cache => false)
    base_dir = File.dirname(__FILE__)

    r10k_helper = R10KHelper.new("Puppetfile.#{args[:suffix]}")

    r10k_issues = Parallel.map(
      Array(r10k_helper.modules),
        :in_processes => get_cpu_limit,
        :progress => 'Dependency Removal'
    ) do |mod|
      Dir.chdir(base_dir) do
        FileUtils.rm_rf(mod[:path])
      end
    end

    if args[:remove_cache]
      cache_dir = File.join(base_dir, '.r10k_cache')
      FileUtils.rm_rf(cache_dir)
    end
  end


  desc <<-EOM
  EXPERIMENTAL
  Generate a list of git logs for the changes since a previous
  simp-core tag.  Includes
  - simp-core changes
  - Individual module changes.  The changes are from the version
    listed in the tag's Puppetfile to the version specified in the
    current Puppetfile

  ASSUMES you have executed deps:checkout[curr_suffix]

  Arguments:
    * :prev_tag    => simp-core previous version tag
    * :prev_suffix => The Puppetfile suffix to use from the previous simp-core tag;
                      DEFAULT: 'tracking'
    * :curr_suffix => The Puppetfile suffix to use from this simp-core checkout
                      DEFAULT: 'pinned'
    * :brief       => Only show oneline summaries; DEFAULT: false
    * :debug       => Log status gathering actions; DEFAULT: false
  EOM
  task :changes_since, [:prev_tag,:prev_suffix,:curr_suffix,:brief,:debug] do |t,args|
    args.with_defaults(:prev_suffix => 'tracking')
    args.with_defaults(:curr_suffix => 'pinned')
    args.with_defaults(:brief => false)
    args.with_defaults(:debug => false)
    log_args = args[:brief] ? '--oneline' : ''

    old_component_versions = {}
    Dir.mktmpdir( File.basename( __FILE__ ) ) do
      cmd = "git show #{args[:prev_tag]}:Puppetfile.#{args[:prev_suffix]}"
      puts "In #{File.basename(Dir.pwd)} executing: #{cmd}" if args[:debug]
      prev_puppetfile = %x(#{cmd})
      File.open('Puppetfile.pre', 'w') { |file| file.puts(prev_puppetfile) }
      r10k_helper_prev = R10KHelper.new('Puppetfile.pre')
      r10k_helper_prev.each_module do |mod|
        old_component_versions[mod[:name]] = mod[:desired_ref]
      end
    end

    git_logs = Hash.new
    cmd = "git log #{args[:prev_tag]}..HEAD --reverse #{log_args}"
    puts "In #{File.basename(Dir.pwd)} executing: #{cmd}" if args[:debug]
    log_output = %x(#{cmd})
    git_logs['__SIMP CORE__'] = log_output unless log_output.strip.empty?

    #TODO invoke deps:checkout with :curr_suffix
    r10k_helper_curr = R10KHelper.new("Puppetfile.#{args[:curr_suffix]}")
    r10k_helper_curr.each_module do |mod|
      if File.directory?(mod[:path])
        next unless simp_component?(mod[:path])
        prev_version = old_component_versions[mod[:name]]
        changelog_diff_output = changelog_diff(mod[:path], prev_version)

        Dir.chdir(mod[:path]) do
          if prev_version
            log_cmd = "git log #{prev_version}..HEAD --reverse #{log_args}"
          else
            log_cmd = "git log --reverse #{log_args}"
          end

          puts "In #{File.basename(Dir.pwd)} executing: #{log_cmd}" if args[:debug]
          log_output = %x(#{log_cmd})
        end

        # TODO figure out if desired_ref is the correct key when a branch is specified
        unless mod[:desired_ref] == prev_version
          output = [
            "Current version: #{mod[:desired_ref]}   Previous version: #{prev_version.nil? ? 'N/A' : prev_version}",
            'CHANGELOG diff:',
             changelog_diff_output,
            '',
            'Git Log:',
            log_output
          ].join("\n")
          git_logs[mod[:name]] = output
        end
      else
        $stderr.puts "WARNING: #{mod[:path]} not found"
      end
    end

    if git_logs.empty?
      puts( "No changes found for any components since SIMP #{args[:prev_tag]}")
    else
      page

      puts "Comparison with SIMP #{args[:prev_tag]}"
      git_logs.keys.sort.each do |component_name|
        puts <<-EOM
#{'='*80}
#{component_name}:

#{git_logs[component_name].gsub(/^/,'  ')}

        EOM
      end
    end
  end

  desc <<-EOM
  Logs the .gitlab-ci.yml coverage for the acceptance test suites, taking
  into consideration nodesets available for the suite and ASSUMING the tests
  should also be run in FIPS-mode.

  Each line contains the following columns separated by a ',':
  - component name (directory name)
  - suite
  - nodeset
  - Puppet version (pulled from the .gitlab-ci.yml)
  - FIPS status (enabled/disabled)
  - GitLab job status:
    - present:       the job is present in .gitlab-ci.yml
    - absent: :      the job is absent from .gitlab-ci.yml
    - misconfigured: the job from .gitlab-ci.yml doesn't match the project

  ASSUMES
  - You have executed deps:checkout[appropriate_suffix]
  - Puppet modules are in src/puppet/modules
  - Assets are in src/assets
  EOM
  task :gitlab_job_coverage, [:csv, :debug] do |t,args|
    args.with_defaults(:csv => true)
    args.with_defaults(:debug => false)

    test_sets = []
    module_dirs = Dir.glob('src/puppet/modules/*')
    asset_dirs = Dir.glob('src/assets/*').delete_if { |x| File.basename(x) == 'simp' }
    component_dirs = [ '.' ] + module_dirs + asset_dirs
    component_dirs.map! { |dir| File.expand_path(dir) }
    component_dirs.sort_by! { |x| File.basename(x) }
    component_dirs.each do |component_dir|
      next unless simp_component?(component_dir)
#      test_sets << get_acceptance_test_matrix(component_dir)
      puppet_versions, tests = get_gitlab_acceptance_test_matrix(component_dir)
      test_sets << tests
    end
    headings = [
      'Component',
      'Suite',
      'Nodeset',
      'Puppet Version',
      'FIPS'
    ]
    puts headings.join(',')
    test_sets.each do |component_tests|
      component_tests.each do |test|
        puts test.join(',')
      end
    end
  end

end
